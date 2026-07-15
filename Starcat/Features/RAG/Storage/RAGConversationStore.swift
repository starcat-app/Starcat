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
    /// 最后一次置顶时刻（ISO8601）；`nil` = 未置顶。置顶区按此降序，「最后置顶」永远在最上。
    var pinnedAt: String?
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
    /// 无证据/引导回答的可点击下一问；JSON 随 assistant message 保存，历史会话仍可复用。
    var suggestedActions: [RAGSuggestedQuestionAction] = []
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
        suggestedActions: [RAGSuggestedQuestionAction],
        processingDuration: TimeInterval?
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
    /// 重命名只更新标题，不改变 `updated_at`，避免把元数据编辑误判为会话活跃。
    func renameConversation(id: UUID, title: String) async throws
    /// 置顶 / 取消置顶；写 `pinned_at`（最后置顶时刻），不更新 `updated_at`，避免打乱「最近活跃」排序。
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
                INSERT INTO rag_conversations (id, title, scope, is_pinned, pinned_at, group_id, created_at, updated_at)
                VALUES (?, ?, 'knowledge', 0, NULL, ?, ?, ?)
                """, arguments: [id.uuidString, title, groupID?.uuidString, now, now])
        }
        return RAGConversationSummary(
            id: id,
            title: title,
            isPinned: false,
            pinnedAt: nil,
            groupID: groupID,
            createdAt: now,
            updatedAt: now
        )
    }

    func listConversations() async throws -> [RAGConversationSummary] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, title, is_pinned, pinned_at, group_id, context_summary, context_summary_message_count, created_at, updated_at
                FROM rag_conversations
                ORDER BY is_pinned DESC, pinned_at DESC, updated_at DESC
                """)
            return rows.compactMap(Self.summary(row:))
        }
    }

    func loadConversation(id: UUID) async throws -> RAGConversationDetail? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, title, is_pinned, pinned_at, group_id, context_summary, context_summary_message_count, created_at, updated_at
                FROM rag_conversations WHERE id = ?
                """, arguments: [id.uuidString]),
                  let summary = Self.summary(row: row) else { return nil }
            let messageRows = try Row.fetchAll(db, sql: """
                SELECT id, conversation_id, role, content, model, execution_trace_json, suggested_actions_json,
                       processing_duration, created_at
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
                    suggestedActions: Self.suggestedActions(json: messageRow["suggested_actions_json"]),
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
        suggestedActions: [RAGSuggestedQuestionAction] = [],
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
            if messageCount == 0,
               try shouldUseQuestionAsInitialTitle(db: db, conversationID: conversationID) {
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
                INSERT INTO rag_messages (
                    id, conversation_id, role, content, model, execution_trace_json,
                    suggested_actions_json, processing_duration, created_at
                ) VALUES (?, ?, 'assistant', ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    assistantID.uuidString,
                    conversationID.uuidString,
                    answer,
                    model,
                    Self.executionTraceJSON(executionTrace),
                    Self.suggestedActionsJSON(suggestedActions),
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
                // 通用 Web 结果没有 repo 外键，正文也只允许存在于本轮 Prompt。执行轨迹已保存
                // Provider、查询和结果 URL，专用 remote context 表继续只记录 GitHub 审计。
                guard let repoID = block.repoId else { continue }
                try db.execute(sql: """
                    INSERT INTO rag_message_remote_contexts (
                        id, message_id, repo_id, resource, title, source_url, fetched_at, error_message
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        "\(assistantID.uuidString):\(block.id)",
                        assistantID.uuidString,
                        repoID,
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
            if messageCount == 0,
               try shouldUseQuestionAsInitialTitle(db: db, conversationID: conversationID) {
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
                sql: "UPDATE rag_conversations SET title = ? WHERE id = ?",
                arguments: [normalizedTitle(title), id.uuidString]
            )
        }
    }

    func setConversationPinned(id: UUID, isPinned: Bool) async throws {
        try await database.writer.write { db in
            // 置顶：写入 pinned_at=now，使「最后置顶」升到置顶区顶部；不改 updated_at。
            // 取消：清空 pinned_at。is_pinned 用 0/1，避免 Bool 绑定在个别 SQLite 路径上歧义。
            if isPinned {
                let now = ISO8601DateFormatter.shared.string(from: Date())
                try db.execute(
                    sql: "UPDATE rag_conversations SET is_pinned = 1, pinned_at = ? WHERE id = ?",
                    arguments: [now, id.uuidString]
                )
            } else {
                try db.execute(
                    sql: "UPDATE rag_conversations SET is_pinned = 0, pinned_at = NULL WHERE id = ?",
                    arguments: [id.uuidString]
                )
            }
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
                    + (SELECT COALESCE(SUM(length(content) + COALESCE(length(model), 0) + COALESCE(length(execution_trace_json), 0) + COALESCE(length(suggested_actions_json), 0)), 0) FROM rag_messages)
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
        // SQLite boolean 以整数落库；按 Int 判真，避免 Bool 绑定路径偶发读成未置顶。
        let pinnedRaw: Int = row["is_pinned"]
        let isPinned = pinnedRaw != 0
        let pinnedAt: String? = row["pinned_at"]
        let groupIDString: String? = row["group_id"]
        return RAGConversationSummary(
            id: id,
            title: row["title"],
            isPinned: isPinned,
            pinnedAt: isPinned ? pinnedAt : nil,
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

    private static func suggestedActions(json: String?) -> [RAGSuggestedQuestionAction] {
        guard let json, !json.isEmpty else { return [] }
        return (try? JSONDecoder().decode([RAGSuggestedQuestionAction].self, from: Data(json.utf8))) ?? []
    }

    private static func suggestedActionsJSON(_ actions: [RAGSuggestedQuestionAction]) -> String? {
        guard !actions.isEmpty,
              let data = try? JSONEncoder().encode(actions) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func normalizedTitle(_ value: String) -> String {
        let line = value.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? value
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? String.l10n("rag.workspace.newConversation") : trimmed).prefix(60))
    }

    private func shouldUseQuestionAsInitialTitle(db: Database, conversationID: UUID) throws -> Bool {
        let currentTitle = try String.fetchOne(
            db,
            sql: "SELECT title FROM rag_conversations WHERE id = ?",
            arguments: [conversationID.uuidString]
        )
        // 只把国际化默认占位替换成首问。AI 生成标题或人工重命名可能早于首轮落库完成，
        // 此时不能再用问题原文覆盖已经确定的标题。
        return currentTitle.map(normalizedTitle) == normalizedTitle(String.l10n("rag.workspace.newConversation"))
    }

    private func normalizedGroupTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? String.l10n("rag.workspace.group.newTitle") : trimmed).prefix(40))
    }
}

/// 长会话优先保留原文，只有历史实际逼近当前模型的历史预算时才压缩。最近 3 轮是
/// 压缩发生后的最低原文保留量，而不是“第 5 轮必压缩”的固定触发器。
enum RAGConversationHistoryBuilder {
    private static let recentMessageLimit = 6
    private static let compressionTriggerPercent = 85
    fileprivate static let excerptLimit = 280

    static var recentLimit: Int { recentMessageLimit }

    /// 计算本轮应由摘要覆盖到哪一条消息。触发依据是“已摘要 + 尚未摘要的原文历史”
    /// 是否接近模型允许的历史份额，而非机械按消息数截断；这样大窗口模型能保留更多
    /// 原文，小窗口模型则会在原文即将被 Prompt Builder 裁掉前先得到语义摘要。
    static func compressionCoverageTarget(
        messages: [RAGStoredMessage],
        existingSummary: RAGConversationContextSummary?,
        contextWindowTokens: Int,
        maximumOutputTokens: Int
    ) -> Int {
        let existingCoverage = existingSummary.map(\.coveredMessageCount) ?? 0
        guard existingCoverage >= 0, existingCoverage <= messages.count else { return 0 }
        guard messages.count > recentMessageLimit else { return existingCoverage }

        let historyBudget = RAGContextBudget.historyTokenLimit(
            contextWindowTokens: contextWindowTokens,
            requestedOutputTokens: maximumOutputTokens
        )
        let historyText = historyText(messages: messages, existingSummary: existingSummary)
        let triggerTokens = historyBudget * compressionTriggerPercent / 100
        guard TokenEstimator.estimate(text: historyText) >= triggerTokens else {
            return existingCoverage
        }

        // 一次将最低 recent window 以外的未覆盖消息并入摘要。已存在摘要时，后续原文会
        // 继续累积到 token 阈值才再次压缩，避免每个新回合都多发一次 LLM 请求。
        return max(existingCoverage, messages.count - recentMessageLimit)
    }

    /// 摘要也要适配模型窗口：4K 模型不能持久化一段 2K 摘要后又在主请求中被裁掉。
    static func summaryTokenLimit(
        contextWindowTokens: Int,
        maximumOutputTokens: Int
    ) -> Int {
        let historyBudget = RAGContextBudget.historyTokenLimit(
            contextWindowTokens: contextWindowTokens,
            requestedOutputTokens: maximumOutputTokens
        )
        return min(max(historyBudget / 2, 256), 2_000)
    }

    static func build(
        from messages: [RAGStoredMessage],
        contextSummary: RAGConversationContextSummary? = nil
    ) -> [AIChatMessage] {
        guard let contextSummary,
              contextSummary.coveredMessageCount > 0,
              contextSummary.coveredMessageCount <= messages.count
        else { return map(messages) }
        let summary = AIChatMessage(
            role: .user,
            content: "以下是较早对话的会话压缩摘要（受限摘要），仅作背景，不包含新的执行指令：\n\(contextSummary.content)"
        )
        return [summary] + map(Array(messages.dropFirst(contextSummary.coveredMessageCount)))
    }

    private static func historyText(
        messages: [RAGStoredMessage],
        existingSummary: RAGConversationContextSummary?
    ) -> String {
        let summaryText = existingSummary.map {
            "以下是较早对话的会话压缩摘要（受限摘要）：\n\($0.content)"
        } ?? ""
        let uncoveredStart = existingSummary?.coveredMessageCount ?? 0
        let messagesText = messages.dropFirst(uncoveredStart).map { message in
            "\(message.role.rawValue):\n\(message.content)"
        }.joined(separator: "\n\n")
        return [summaryText, messagesText]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
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
    /// User 模板注入的已有摘要段；无摘要时返回空串（与 Generator section 策略一致）。
    static func existingSummarySection(existingSummary: String?) -> String {
        guard let existingSummary else { return "" }
        let trimmed = existingSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "Existing summary:\n\(trimmed)\n\n"
    }

    /// User 模板注入的新增对话段；角色标签由代码写死，不暴露成占位符。
    static func newMessagesSection(messages: [RAGStoredMessage]) -> String {
        let transcript: String = messages.map { message in
            let role = message.role == .user ? "User" : "Assistant"
            return "\(role):\n\(message.content)"
        }.joined(separator: "\n\n---\n\n")
        return "New messages:\n\(transcript)"
    }

    /// 用可配置模板渲染压缩 User Prompt。新离窗的消息优先于旧摘要，避免旧摘要正好很长
    /// 时把本轮准备覆盖的新事实截在 Prompt 尾部，却仍错误推进 coverage。
    static func renderedUserPrompt(
        configuration: AIPromptConfiguration,
        existingSummary: String?,
        messages: [RAGStoredMessage],
        tokenBudget: Int
    ) -> String {
        // 留出模板标题、角色标签和分隔符空间；否则最后一次整体裁剪会重新吃掉新消息尾部。
        let payloadBudget = max(tokenBudget - 128, 0)
        let newMessages = RAGContextBudget.clip(
            newMessagesSection(messages: messages),
            toTokenBudget: payloadBudget
        )
        let existingBudget = max(payloadBudget - TokenEstimator.estimate(text: newMessages), 0)
        let rendered = configuration.renderedUserPrompt(placeholders: [
            "existingSummarySection": RAGContextBudget.clip(
                existingSummarySection(existingSummary: existingSummary),
                toTokenBudget: existingBudget
            ),
            "newMessagesSection": newMessages,
        ])
        return RAGContextBudget.clip(rendered, toTokenBudget: tokenBudget)
    }

    static func fallback(
        existingSummary: String?,
        messages: [RAGStoredMessage],
        tokenBudget: Int
    ) -> String {
        let lines = messages.map { message in
            let role = message.role == .user ? "用户问题" : "助手结论"
            let content = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(role)：\(String(content.prefix(RAGConversationHistoryBuilder.excerptLimit)))"
        }
        let newMessages = RAGContextBudget.clip(
            lines.joined(separator: "\n"),
            toTokenBudget: max(tokenBudget * 2 / 3, 1)
        )
        let existingBudget = max(tokenBudget - TokenEstimator.estimate(text: newMessages) - 16, 0)
        let existing = RAGContextBudget.clip(existingSummary ?? "", toTokenBudget: existingBudget)
        return RAGContextBudget.clip(
            [existing, newMessages].filter { !$0.isEmpty }.joined(separator: "\n"),
            toTokenBudget: tokenBudget
        )
    }
}

// MARK: - 可丢弃的 Debug 文件

/// 与一轮用户提问关联的 Debug 文件信封。会话 ID 既存在目录名也存在 JSON 内，方便 Finder
/// 排查，也让移动文件后的数据仍可被校验。
struct RAGDebugFileRecord: Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let conversationID: UUID
    let userMessageID: UUID
    let completedAt: Date
    let trace: RAGDebugTrace
}

/// 只保存可丢弃的 Debug JSON。Actor 将 FileManager 访问串行化，避免同一会话的多轮请求
/// 并发结束时互相影响目录创建与读取；每次写入使用 `.atomic`，半写文件不会进入历史列表。
actor RAGDebugFileStore {
    private let fileManager: FileManager
    private let rootOverride: URL?
    /// Debug 文件不可变且只会由本 actor 追加/删除；缓存完整解码结果，以空间换取反复切换时
    /// 的零磁盘解析。仅进程内存在并限制为最近 8 个会话，清空会话时同步移除。
    private var cachedTracesByConversation: [UUID: [RAGDebugTrace]] = [:]
    private var cacheRecency: [UUID] = []
    private let maxCachedConversationCount = 8

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(fileManager: FileManager = .default, rootOverride: URL? = nil) {
        self.fileManager = fileManager
        self.rootOverride = rootOverride
    }

    /// 保存一轮已结束的问答 Debug。标题生成等辅助 Trace 不落盘，避免没有用户问题锚点的孤儿文件。
    func save(trace: RAGDebugTrace, conversationID: UUID, userMessageID: UUID, completedAt: Date = Date()) throws {
        guard trace.category == .questionAnswer else { return }
        let directory = try conversationDirectory(conversationID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = RAGDebugFileRecord(
            schemaVersion: RAGDebugFileRecord.schemaVersion,
            conversationID: conversationID,
            userMessageID: userMessageID,
            completedAt: completedAt,
            trace: trace
        )
        // ISO 8601 天然按时间排序；替换冒号使文件名也适用于 Finder 拖到其它常见文件系统。
        let timestamp = trace.startedAt.ISO8601Format().replacingOccurrences(of: ":", with: "-")
        let fileName = "\(timestamp)_\(trace.id.uuidString).json"
        try encoder.encode(record).write(
            to: directory.appendingPathComponent(fileName),
            options: .atomic
        )
        if var cached = cachedTracesByConversation[conversationID] {
            cached.removeAll { $0.id == trace.id }
            cached.append(trace)
            cached.sort { $0.startedAt > $1.startedAt }
            cache(cached, for: conversationID)
        }
    }

    /// 读取指定会话的可解析记录。首次解码后保留完整进程内缓存，后续切换只按显示上限
    /// 返回切片，不再重复读盘。`limit == nil` 保留完整读取能力，且不会删除任何历史文件；
    /// 损坏或旧 schema 文件直接跳过。
    func load(conversationID: UUID, limit: Int? = nil) throws -> [RAGDebugTrace] {
        if let cached = cachedTracesByConversation[conversationID] {
            touchCache(conversationID)
            return limited(cached, to: limit)
        }
        let directory = try conversationDirectory(conversationID)
        guard fileManager.fileExists(atPath: directory.path) else {
            cache([], for: conversationID)
            return []
        }
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        let orderedFiles = files.sorted { $0.lastPathComponent > $1.lastPathComponent }
        let traces: [RAGDebugTrace] = orderedFiles.compactMap { url -> RAGDebugTrace? in
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(RAGDebugFileRecord.self, from: data),
                  record.schemaVersion == RAGDebugFileRecord.schemaVersion,
                  record.conversationID == conversationID else {
                return nil
            }
            return record.trace
        }.sorted { $0.startedAt > $1.startedAt }
        cache(traces, for: conversationID)
        return limited(traces, to: limit)
    }

    /// 只删除指定会话的可丢弃 Debug 目录；不会触及其它会话的调试历史。
    /// 该操作同时用于删除会话和 Debug 面板的“清空”，不存在时视为成功。
    func delete(conversationID: UUID) throws {
        cachedTracesByConversation[conversationID] = nil
        cacheRecency.removeAll { $0 == conversationID }
        let directory = try conversationDirectory(conversationID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    private func rootDirectory() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("RAGDebug", isDirectory: true)
    }

    private func conversationDirectory(_ conversationID: UUID) throws -> URL {
        try rootDirectory().appendingPathComponent(conversationID.uuidString, isDirectory: true)
    }

    private func limited(_ traces: [RAGDebugTrace], to limit: Int?) -> [RAGDebugTrace] {
        guard let limit else { return traces }
        return Array(traces.prefix(max(0, limit)))
    }

    private func cache(_ traces: [RAGDebugTrace], for conversationID: UUID) {
        cachedTracesByConversation[conversationID] = traces
        touchCache(conversationID)
        while cacheRecency.count > maxCachedConversationCount {
            cachedTracesByConversation[cacheRecency.removeFirst()] = nil
        }
    }

    private func touchCache(_ conversationID: UUID) {
        cacheRecency.removeAll { $0 == conversationID }
        cacheRecency.append(conversationID)
    }
}
