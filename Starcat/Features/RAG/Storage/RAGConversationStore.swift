//
//  RAGConversationStore.swift
//  Starcat
//
//  知识库 RAG 会话 / 一级分组的本地持久化。
//
//  关键约束：分组只有一层——目录下只能挂会话，不能再嵌套目录；删除分组时会话回
//  到未分组（`group_id` SET NULL），不级联删会话。
//

import Foundation
import GRDB

enum RAGStoredMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

struct RAGConversationGroup: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var sortOrder: Int
    var createdAt: String
    var updatedAt: String
}

struct RAGConversationSummary: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var isPinned: Bool
    /// `nil` = 未分组（挂在「最近问答」根级）。
    var groupID: UUID?
    var createdAt: String
    var updatedAt: String
}

struct RAGStoredMessage: Identifiable, Equatable, Sendable {
    var id: UUID
    var conversationID: UUID
    var role: RAGStoredMessageRole
    var content: String
    var model: String?
    var citations: [RAGCitation]
    var remoteContextAudits: [RAGRemoteContextAudit]
    /// 用户可回看的脱敏执行轨迹；不同于仅存内存的 Debug trace。
    var executionTrace: [RAGExecutionStep] = []
    /// 从用户提交问题到最终 LLM 流结束的真实耗时；保留历史回答的性能反馈。
    var processingDuration: TimeInterval?
    var createdAt: String
}

/// 已持久化的会话压缩摘要。`coveredMessageCount` 表示前多少条原始消息已包含在摘要中；
/// 新一轮压缩只追加这之后、且已离开 recent window 的消息，避免反复总结全部历史。
struct RAGConversationContextSummary: Equatable, Sendable {
    var content: String
    var coveredMessageCount: Int
}

struct RAGConversationDetail: Equatable, Sendable {
    var summary: RAGConversationSummary
    var messages: [RAGStoredMessage]
    var contextSummary: RAGConversationContextSummary?
}

struct RAGConversationStatistics: Equatable, Sendable {
    var conversationCount: Int
    var messageCount: Int
    var totalBytes: Int64

    static let empty = RAGConversationStatistics(conversationCount: 0, messageCount: 0, totalBytes: 0)
}

protocol RAGConversationStoring: Sendable {
    func createConversation(title: String?, groupID: UUID?) async throws -> RAGConversationSummary
    func listConversations() async throws -> [RAGConversationSummary]
    func loadConversation(id: UUID) async throws -> RAGConversationDetail?
    func saveContextSummary(
        conversationID: UUID,
        content: String,
        coveredMessageCount: Int
    ) async throws
    func appendTurn(
        conversationID: UUID,
        question: String,
        answer: String,
        model: String,
        citations: [RAGCitation],
        remoteContexts: [RAGRemoteContextBlock],
        executionTrace: [RAGExecutionStep],
        processingDuration: TimeInterval? = nil
    ) async throws
    /// 仅落库用户消息（停止时尚未产生任何助手文本）。
    func appendUserMessage(
        conversationID: UUID,
        messageID: UUID,
        question: String,
        createdAt: String
    ) async throws
    /// 删除单条消息（编辑后重发前清掉「仅用户、无回答」的孤儿消息）。
    func deleteMessage(id: UUID) async throws
    func renameConversation(id: UUID, title: String) async throws
    /// 置顶 / 取消置顶；不更新 `updated_at`，避免置顶打乱「最近活跃」排序。
    func setConversationPinned(id: UUID, isPinned: Bool) async throws
    /// 移动到分组；`groupID == nil` 表示移出到未分组。不更新 `updated_at`。
    func setConversationGroup(id: UUID, groupID: UUID?) async throws
    func deleteConversation(id: UUID) async throws
    func deleteAll() async throws
    func statistics() async throws -> RAGConversationStatistics

    func createGroup(title: String?) async throws -> RAGConversationGroup
    func listGroups() async throws -> [RAGConversationGroup]
    func renameGroup(id: UUID, title: String) async throws
    func deleteGroup(id: UUID) async throws
}

struct GRDBRAGConversationStore: RAGConversationStoring {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func createConversation(title: String? = nil, groupID: UUID? = nil) async throws -> RAGConversationSummary {
        let id = UUID()
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let title = normalizedTitle(title ?? String.l10n("rag.workspace.newConversation"))
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO rag_conversations (id, title, scope, is_pinned, group_id, created_at, updated_at)
                VALUES (?, ?, 'knowledge', 0, ?, ?, ?)
                """, arguments: [id.uuidString, title, groupID?.uuidString, now, now])
        }
        return RAGConversationSummary(
            id: id,
            title: title,
            isPinned: false,
            groupID: groupID,
            createdAt: now,
            updatedAt: now
        )
    }

    func listConversations() async throws -> [RAGConversationSummary] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, title, is_pinned, group_id, context_summary, context_summary_message_count, created_at, updated_at
                FROM rag_conversations
                ORDER BY is_pinned DESC, updated_at DESC
                """)
            return rows.compactMap(Self.summary(row:))
        }
    }

    func loadConversation(id: UUID) async throws -> RAGConversationDetail? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, title, is_pinned, group_id, context_summary, context_summary_message_count, created_at, updated_at
                FROM rag_conversations WHERE id = ?
                """, arguments: [id.uuidString]),
                  let summary = Self.summary(row: row) else { return nil }
            let messageRows = try Row.fetchAll(db, sql: """
                SELECT id, conversation_id, role, content, model, execution_trace_json, processing_duration, created_at
                FROM rag_messages
                WHERE conversation_id = ?
                ORDER BY created_at ASC, rowid ASC
                """, arguments: [id.uuidString])
            let messageIDs = messageRows.compactMap { row -> UUID? in
                let rawID: String = row["id"]
                return UUID(uuidString: rawID)
            }
            // 会话历史必须一次性带回关联 metadata。逐 message 查询 citation / remote audit 在
            // 200 条历史时会变成 401 次 SQL 读取，切换会话会明显拖慢并干扰尾部滚动时机。
            let citationsByMessageID = try citationRows(db: db, messageIDs: messageIDs)
            let remoteAuditsByMessageID = try remoteContextAuditRows(db: db, messageIDs: messageIDs)
            var messages: [RAGStoredMessage] = []
            for messageRow in messageRows {
                guard let messageID = UUID(uuidString: messageRow["id"]),
                      let role = RAGStoredMessageRole(rawValue: messageRow["role"]) else { continue }
                messages.append(RAGStoredMessage(
                    id: messageID,
                    conversationID: id,
                    role: role,
                    content: messageRow["content"],
                    model: messageRow["model"],
                    citations: citationsByMessageID[messageID] ?? [],
                    remoteContextAudits: remoteAuditsByMessageID[messageID] ?? [],
                    executionTrace: Self.executionTrace(json: messageRow["execution_trace_json"]),
                    processingDuration: messageRow["processing_duration"],
                    createdAt: messageRow["created_at"]
                ))
            }
            let contextSummary: RAGConversationContextSummary?
            if let content: String = row["context_summary"], !content.isEmpty {
                contextSummary = RAGConversationContextSummary(
                    content: content,
                    coveredMessageCount: row["context_summary_message_count"] ?? 0
                )
            } else {
                contextSummary = nil
            }
            return RAGConversationDetail(
                summary: summary,
                messages: messages,
                contextSummary: contextSummary
            )
        }
    }

    func saveContextSummary(
        conversationID: UUID,
        content: String,
        coveredMessageCount: Int
    ) async throws {
        try await database.writer.write { db in
            // 摘要是会话的派生压缩，不改最近活跃排序；限制持久化大小以免异常 Provider 响应
            // 把用户本地历史无界撑大。
            try db.execute(
                sql: """
                UPDATE rag_conversations
                SET context_summary = ?, context_summary_message_count = ?
                WHERE id = ?
                """,
                arguments: [
                    RAGContextBudget.clip(content, toTokenBudget: 2_000),
                    max(coveredMessageCount, 0),
                    conversationID.uuidString
                ]
            )
        }
    }

    func appendTurn(
        conversationID: UUID,
        question: String,
        answer: String,
        model: String,
        citations: [RAGCitation],
        remoteContexts: [RAGRemoteContextBlock] = [],
        executionTrace: [RAGExecutionStep] = [],
        processingDuration: TimeInterval? = nil
    ) async throws {
        let userID = UUID()
        let assistantID = UUID()
        let now = Date()
        let userAt = ISO8601DateFormatter.shared.string(from: now)
        let assistantAt = ISO8601DateFormatter.shared.string(from: now.addingTimeInterval(0.001))
        try await database.writer.write { db in
            let messageCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM rag_messages WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]
            ) ?? 0
            if messageCount == 0 {
                try db.execute(
                    sql: "UPDATE rag_conversations SET title = ? WHERE id = ?",
                    arguments: [normalizedTitle(question), conversationID.uuidString]
                )
            }
            try db.execute(sql: """
                INSERT INTO rag_messages (id, conversation_id, role, content, model, created_at)
                VALUES (?, ?, 'user', ?, NULL, ?)
                """, arguments: [userID.uuidString, conversationID.uuidString, question, userAt])
            try db.execute(sql: """
                INSERT INTO rag_messages (id, conversation_id, role, content, model, execution_trace_json, processing_duration, created_at)
                VALUES (?, ?, 'assistant', ?, ?, ?, ?, ?)
                """, arguments: [
                    assistantID.uuidString,
                    conversationID.uuidString,
                    answer,
                    model,
                    Self.executionTraceJSON(executionTrace),
                    processingDuration,
                    assistantAt
                ])
            for (rank, citation) in citations.enumerated() {
                let scoreBreakdownJSON = try citation.scoreBreakdown.map {
                    String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
                }
                try db.execute(sql: """
                    INSERT INTO rag_message_citations (
                        id, message_id, chunk_id, repo_id, repo_full_name, marker, source,
                        section_title, rank, score, hit_kind, vector_similarity, score_breakdown_json, source_url, fetched_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        citation.id.uuidString,
                        assistantID.uuidString,
                        citation.chunkID,
                        citation.repoID,
                        citation.repoFullName,
                        citation.marker,
                        citation.source.rawValue,
                        citation.sectionTitle,
                        rank,
                        citation.score,
                        citation.hitKind.rawValue,
                        citation.vectorSimilarity,
                        scoreBreakdownJSON,
                        citation.sourceURL?.absoluteString,
                        assistantAt
                ])
            }
            for block in remoteContexts {
                try db.execute(sql: """
                    INSERT INTO rag_message_remote_contexts (
                        id, message_id, repo_id, resource, title, source_url, fetched_at, error_message
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        "\(assistantID.uuidString):\(block.id)",
                        assistantID.uuidString,
                        block.repoId,
                        block.resource.rawValue,
                        block.title,
                        block.sourceURL?.absoluteString,
                        ISO8601DateFormatter.shared.string(from: block.fetchedAt),
                        block.errorMessage
                    ])
            }
            try db.execute(
                sql: "UPDATE rag_conversations SET updated_at = ? WHERE id = ?",
                arguments: [assistantAt, conversationID.uuidString]
            )
        }
    }

    func appendUserMessage(
        conversationID: UUID,
        messageID: UUID,
        question: String,
        createdAt: String
    ) async throws {
        try await database.writer.write { db in
            let messageCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM rag_messages WHERE conversation_id = ?",
                arguments: [conversationID.uuidString]
            ) ?? 0
            if messageCount == 0 {
                try db.execute(
                    sql: "UPDATE rag_conversations SET title = ? WHERE id = ?",
                    arguments: [normalizedTitle(question), conversationID.uuidString]
                )
            }
            try db.execute(sql: """
                INSERT OR IGNORE INTO rag_messages (id, conversation_id, role, content, model, created_at)
                VALUES (?, ?, 'user', ?, NULL, ?)
                """, arguments: [messageID.uuidString, conversationID.uuidString, question, createdAt])
            try db.execute(
                sql: "UPDATE rag_conversations SET updated_at = ? WHERE id = ?",
                arguments: [createdAt, conversationID.uuidString]
            )
        }
    }

    func deleteMessage(id: UUID) async throws {
        try await database.writer.write { db in
            let conversationID: String? = try String.fetchOne(
                db,
                sql: "SELECT conversation_id FROM rag_messages WHERE id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM rag_message_citations WHERE message_id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM rag_message_remote_contexts WHERE message_id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(
                sql: "DELETE FROM rag_messages WHERE id = ?",
                arguments: [id.uuidString]
            )
            // 删除的可能是已被摘要覆盖的旧消息；清空覆盖边界后，下次请求会重建摘要，
            // 防止模型继续收到已经被用户编辑掉的事实。
            if let conversationID {
                try db.execute(
                    sql: "UPDATE rag_conversations SET context_summary = NULL, context_summary_message_count = 0 WHERE id = ?",
                    arguments: [conversationID]
                )
            }
        }
    }

    func renameConversation(id: UUID, title: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE rag_conversations SET title = ?, updated_at = ? WHERE id = ?",
                arguments: [normalizedTitle(title), ISO8601DateFormatter.shared.string(from: Date()), id.uuidString]
            )
        }
    }

    func setConversationPinned(id: UUID, isPinned: Bool) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE rag_conversations SET is_pinned = ? WHERE id = ?",
                arguments: [isPinned, id.uuidString]
            )
        }
    }

    func setConversationGroup(id: UUID, groupID: UUID?) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE rag_conversations SET group_id = ? WHERE id = ?",
                arguments: [groupID?.uuidString, id.uuidString]
            )
        }
    }

    func deleteConversation(id: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM rag_conversations WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func deleteAll() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM rag_conversations")
            try db.execute(sql: "DELETE FROM rag_conversation_groups")
        }
    }

    func statistics() async throws -> RAGConversationStatistics {
        try await database.writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    (SELECT COUNT(*) FROM rag_conversations) AS conversation_count,
                    (SELECT COUNT(*) FROM rag_messages) AS message_count,
                    (SELECT COALESCE(SUM(length(title) + length(scope)), 0) FROM rag_conversations)
                    + (SELECT COALESCE(SUM(length(content) + COALESCE(length(model), 0) + COALESCE(length(execution_trace_json), 0)), 0) FROM rag_messages)
                    + (SELECT COALESCE(SUM(length(repo_full_name) + length(marker) + length(source) + length(section_title) + COALESCE(length(source_url), 0)), 0) FROM rag_message_citations)
                    + (SELECT COALESCE(SUM(length(resource) + length(title) + COALESCE(length(source_url), 0) + COALESCE(length(error_message), 0)), 0) FROM rag_message_remote_contexts)
                    AS total_bytes
                """)
            return RAGConversationStatistics(
                conversationCount: row?["conversation_count"] ?? 0,
                messageCount: row?["message_count"] ?? 0,
                totalBytes: row?["total_bytes"] ?? 0
            )
        }
    }

    func createGroup(title: String? = nil) async throws -> RAGConversationGroup {
        let id = UUID()
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let title = normalizedGroupTitle(title ?? String.l10n("rag.workspace.group.newTitle"))
        let sortOrder = try await database.writer.write { db -> Int in
            let next = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM rag_conversation_groups") ?? 0)
            try db.execute(sql: """
                INSERT INTO rag_conversation_groups (id, title, sort_order, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [id.uuidString, title, next, now, now])
            return next
        }
        return RAGConversationGroup(id: id, title: title, sortOrder: sortOrder, createdAt: now, updatedAt: now)
    }

    func listGroups() async throws -> [RAGConversationGroup] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, title, sort_order, created_at, updated_at
                FROM rag_conversation_groups
                ORDER BY sort_order ASC, created_at ASC
                """)
            return rows.compactMap(Self.group(row:))
        }
    }

    func renameGroup(id: UUID, title: String) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE rag_conversation_groups SET title = ?, updated_at = ? WHERE id = ?",
                arguments: [normalizedGroupTitle(title), ISO8601DateFormatter.shared.string(from: Date()), id.uuidString]
            )
        }
    }

    func deleteGroup(id: UUID) async throws {
        // 显式清空 group_id：SQLite ALTER 加的 REFERENCES 不一定强制 ON DELETE。
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE rag_conversations SET group_id = NULL WHERE group_id = ?",
                arguments: [id.uuidString]
            )
            try db.execute(sql: "DELETE FROM rag_conversation_groups WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private static func summary(row: Row) -> RAGConversationSummary? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let isPinned: Bool = row["is_pinned"]
        let groupIDString: String? = row["group_id"]
        return RAGConversationSummary(
            id: id,
            title: row["title"],
            isPinned: isPinned,
            groupID: groupIDString.flatMap(UUID.init(uuidString:)),
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func group(row: Row) -> RAGConversationGroup? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        return RAGConversationGroup(
            id: id,
            title: row["title"],
            sortOrder: row["sort_order"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    /// 将整段会话的 citation 以一次 SQL 读取并按 message ID 分桶，避免历史恢复 N+1。
    private func citationRows(db: Database, messageIDs: [UUID]) throws -> [UUID: [RAGCitation]] {
        guard !messageIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, message_id, chunk_id, repo_id, repo_full_name, marker, source, section_title,
                   rank, score, hit_kind, vector_similarity, score_breakdown_json, source_url
            FROM rag_message_citations
            WHERE message_id IN (\(placeholders))
            ORDER BY message_id ASC, rank ASC
            """, arguments: StatementArguments(messageIDs.map(\.uuidString)))
        var grouped: [UUID: [RAGCitation]] = [:]
        for row in rows {
            guard let messageID = UUID(uuidString: row["message_id"]),
                  let id = UUID(uuidString: row["id"]),
                  let source = RAGChunkSource(rawValue: row["source"]),
                  let hitKind = RAGHitKind(rawValue: row["hit_kind"]) else { continue }
            let sourceURLString: String? = row["source_url"]
            let scoreBreakdownJSON: String? = row["score_breakdown_json"]
            let storedMarker: String = row["marker"]
            // ensure 补列后旧行为空串：用 rank+1 仅恢复本机开发会话显示。
            let rank: Int = row["rank"]
            let marker = storedMarker.isEmpty ? "S\(rank + 1)" : storedMarker
            let citation = RAGCitation(
                id: id,
                marker: marker,
                chunkID: row["chunk_id"],
                repoID: row["repo_id"],
                repoFullName: row["repo_full_name"],
                source: source,
                sectionTitle: row["section_title"],
                score: row["score"],
                hitKind: hitKind,
                vectorSimilarity: row["vector_similarity"],
                scoreBreakdown: scoreBreakdownJSON.flatMap {
                    try? JSONDecoder().decode(RAGScoreBreakdown.self, from: Data($0.utf8))
                },
                sourceURL: sourceURLString.flatMap(URL.init(string:))
            )
            grouped[messageID, default: []].append(citation)
        }
        return grouped
    }

    /// 将会话全部 remote audit 元数据一次性读取并按 message ID 分桶。
    private func remoteContextAuditRows(db: Database, messageIDs: [UUID]) throws -> [UUID: [RAGRemoteContextAudit]] {
        guard !messageIDs.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, message_id, repo_id, resource, title, source_url, fetched_at, error_message
            FROM rag_message_remote_contexts
            WHERE message_id IN (\(placeholders))
            ORDER BY message_id ASC, rowid ASC
            """, arguments: StatementArguments(messageIDs.map(\.uuidString)))
        var grouped: [UUID: [RAGRemoteContextAudit]] = [:]
        for row in rows {
            guard let messageID = UUID(uuidString: row["message_id"]),
                  let id: String = row["id"],
                  let resourceRawValue: String = row["resource"],
                  let resource = RAGRemoteContextResource(rawValue: resourceRawValue) else { continue }
            let sourceURLString: String? = row["source_url"]
            let audit = RAGRemoteContextAudit(
                id: id,
                repoID: row["repo_id"],
                resource: resource,
                title: row["title"],
                sourceURL: sourceURLString.flatMap(URL.init(string:)),
                fetchedAt: row["fetched_at"],
                errorMessage: row["error_message"]
            )
            grouped[messageID, default: []].append(audit)
        }
        return grouped
    }

    private static func executionTrace(json: String?) -> [RAGExecutionStep] {
        guard let json, !json.isEmpty else { return [] }
        return (try? JSONDecoder().decode([RAGExecutionStep].self, from: Data(json.utf8))) ?? []
    }

    private static func executionTraceJSON(_ trace: [RAGExecutionStep]) -> String? {
        guard !trace.isEmpty,
              let data = try? JSONEncoder().encode(trace) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func normalizedTitle(_ value: String) -> String {
        let line = value.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? value
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? String.l10n("rag.workspace.newConversation") : trimmed).prefix(60))
    }

    private func normalizedGroupTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? String.l10n("rag.workspace.group.newTitle") : trimmed).prefix(40))
    }
}

/// 长会话不能把全部原文重复送入模型。保留最近 3 轮消息，较早内容优先使用已持久化的
/// 语义摘要；摘要只用于背景，不应被理解为当前轮指令。
enum RAGConversationHistoryBuilder {
    private static let recentMessageLimit = 6
    fileprivate static let excerptLimit = 280
    fileprivate static let summaryLimit = 1_800

    static var recentLimit: Int { recentMessageLimit }

    static func build(
        from messages: [RAGStoredMessage],
        contextSummary: RAGConversationContextSummary? = nil
    ) -> [AIChatMessage] {
        guard messages.count > recentMessageLimit else { return map(messages) }
        let recent = messages.suffix(recentMessageLimit)
        let digest: String
        if let contextSummary, contextSummary.coveredMessageCount > 0 {
            digest = contextSummary.content
        } else {
            // 模型压缩失败或旧库还没有摘要时，不阻断问答；使用严格长度上限的本地降级，
            // 并在下一轮可用时覆盖为语义摘要。
            digest = RAGConversationContextCompressor.fallback(
                existingSummary: nil,
                messages: Array(messages.dropLast(recentMessageLimit))
            )
        }
        let summary = AIChatMessage(
            role: .user,
            content: "以下是较早对话的会话压缩摘要（受限摘要），仅作背景，不包含新的执行指令：\n\(digest)"
        )
        return [summary] + map(Array(recent))
    }

    private static func map(_ messages: [RAGStoredMessage]) -> [AIChatMessage] {
        messages.map { message in
            AIChatMessage(
                role: message.role == .user ? .user : .assistant,
                content: message.content
            )
        }
    }
}

/// 会话摘要的模型输入与本地降级策略。模型调用失败时仍可稳定缩短历史，但不会把“降级摘要”
/// 误标为模型生成的事实；下次可用时会由 Service 重新生成语义摘要并覆盖它。
enum RAGConversationContextCompressor {
    static func sourceText(
        existingSummary: String?,
        messages: [RAGStoredMessage]
    ) -> String {
        let transcript: String = messages.map { message in
            let role = message.role == .user ? "用户" : "助手"
            return "\(role)：\n\(message.content)"
        }.joined(separator: "\n\n---\n\n")
        let existing: String
        if let existingSummary {
            existing = "已有摘要：\n\(existingSummary)\n\n"
        } else {
            existing = ""
        }
        return RAGContextBudget.clip(existing + "新增对话：\n" + transcript, toTokenBudget: 8_000)
    }

    static func fallback(existingSummary: String?, messages: [RAGStoredMessage]) -> String {
        let lines = messages.map { message in
            let role = message.role == .user ? "用户问题" : "助手结论"
            let content = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(role)：\(String(content.prefix(RAGConversationHistoryBuilder.excerptLimit)))"
        }
        let joined = ([existingSummary].compactMap { $0 } + lines).joined(separator: "\n")
        return RAGContextBudget.clip(joined, toTokenBudget: RAGConversationHistoryBuilder.summaryLimit)
    }
}
