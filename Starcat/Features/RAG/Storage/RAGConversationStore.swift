//
//  RAGConversationStore.swift
//  Starcat
//
//  知识库 RAG 的本地会话历史存储。
//
//  回答正文和 citation metadata 属于用户可见历史；chunk 正文不做快照。索引清理后
//  chunk_id 会被数据库置空，但 repo/source/title/link 仍可用于解释当时引用了什么。
//

import Foundation
import GRDB

enum RAGStoredMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

struct RAGConversationSummary: Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var isPinned: Bool
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
    var createdAt: String
}

struct RAGConversationDetail: Equatable, Sendable {
    var summary: RAGConversationSummary
    var messages: [RAGStoredMessage]
}

struct RAGConversationStatistics: Equatable, Sendable {
    var conversationCount: Int
    var messageCount: Int
    var totalBytes: Int64

    static let empty = RAGConversationStatistics(conversationCount: 0, messageCount: 0, totalBytes: 0)
}

protocol RAGConversationStoring: Sendable {
    func createConversation(title: String?) async throws -> RAGConversationSummary
    func listConversations() async throws -> [RAGConversationSummary]
    func loadConversation(id: UUID) async throws -> RAGConversationDetail?
    func appendTurn(
        conversationID: UUID,
        question: String,
        answer: String,
        model: String,
        citations: [RAGCitation],
        remoteContexts: [RAGRemoteContextBlock]
    ) async throws
    func renameConversation(id: UUID, title: String) async throws
    /// 置顶 / 取消置顶；不更新 `updated_at`，避免置顶打乱「最近活跃」排序。
    func setConversationPinned(id: UUID, isPinned: Bool) async throws
    func deleteConversation(id: UUID) async throws
    func deleteAll() async throws
    func statistics() async throws -> RAGConversationStatistics
}

struct GRDBRAGConversationStore: RAGConversationStoring {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func createConversation(title: String? = nil) async throws -> RAGConversationSummary {
        let id = UUID()
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let title = normalizedTitle(title ?? String.l10n("rag.workspace.newConversation"))
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO rag_conversations (id, title, scope, is_pinned, created_at, updated_at)
                VALUES (?, ?, 'knowledge', 0, ?, ?)
                """, arguments: [id.uuidString, title, now, now])
        }
        return RAGConversationSummary(id: id, title: title, isPinned: false, createdAt: now, updatedAt: now)
    }

    func listConversations() async throws -> [RAGConversationSummary] {
        try await database.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, title, is_pinned, created_at, updated_at
                FROM rag_conversations
                ORDER BY is_pinned DESC, updated_at DESC
                """)
            return rows.compactMap(Self.summary(row:))
        }
    }

    func loadConversation(id: UUID) async throws -> RAGConversationDetail? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT id, title, is_pinned, created_at, updated_at
                FROM rag_conversations WHERE id = ?
                """, arguments: [id.uuidString]),
                  let summary = Self.summary(row: row) else { return nil }
            let messageRows = try Row.fetchAll(db, sql: """
                SELECT id, conversation_id, role, content, model, created_at
                FROM rag_messages
                WHERE conversation_id = ?
                ORDER BY created_at ASC, rowid ASC
                """, arguments: [id.uuidString])
            var messages: [RAGStoredMessage] = []
            for messageRow in messageRows {
                guard let messageID = UUID(uuidString: messageRow["id"]),
                      let role = RAGStoredMessageRole(rawValue: messageRow["role"]) else { continue }
                let citations = try citationRows(db: db, messageID: messageID)
                messages.append(RAGStoredMessage(
                    id: messageID,
                    conversationID: id,
                    role: role,
                    content: messageRow["content"],
                    model: messageRow["model"],
                    citations: citations,
                    remoteContextAudits: try remoteContextAuditRows(db: db, messageID: messageID),
                    createdAt: messageRow["created_at"]
                ))
            }
            return RAGConversationDetail(summary: summary, messages: messages)
        }
    }

    func appendTurn(
        conversationID: UUID,
        question: String,
        answer: String,
        model: String,
        citations: [RAGCitation],
        remoteContexts: [RAGRemoteContextBlock] = []
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
                INSERT INTO rag_messages (id, conversation_id, role, content, model, created_at)
                VALUES (?, ?, 'assistant', ?, ?, ?)
                """, arguments: [assistantID.uuidString, conversationID.uuidString, answer, model, assistantAt])
            for (rank, citation) in citations.enumerated() {
                try db.execute(sql: """
                    INSERT INTO rag_message_citations (
                        id, message_id, chunk_id, repo_id, repo_full_name, source,
                        section_title, rank, score, hit_kind, source_url, fetched_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        citation.id.uuidString,
                        assistantID.uuidString,
                        citation.chunkID,
                        citation.repoID,
                        citation.repoFullName,
                        citation.source.rawValue,
                        citation.sectionTitle,
                        rank,
                        citation.score,
                        citation.hitKind.rawValue,
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

    func deleteConversation(id: UUID) async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM rag_conversations WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func deleteAll() async throws {
        try await database.writer.write { db in
            try db.execute(sql: "DELETE FROM rag_conversations")
        }
    }

    func statistics() async throws -> RAGConversationStatistics {
        try await database.writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    (SELECT COUNT(*) FROM rag_conversations) AS conversation_count,
                    (SELECT COUNT(*) FROM rag_messages) AS message_count,
                    (SELECT COALESCE(SUM(length(title) + length(scope)), 0) FROM rag_conversations)
                    + (SELECT COALESCE(SUM(length(content) + COALESCE(length(model), 0)), 0) FROM rag_messages)
                    + (SELECT COALESCE(SUM(length(repo_full_name) + length(source) + length(section_title) + COALESCE(length(source_url), 0)), 0) FROM rag_message_citations)
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

    private static func summary(row: Row) -> RAGConversationSummary? {
        guard let id = UUID(uuidString: row["id"]) else { return nil }
        let isPinned: Bool = row["is_pinned"]
        return RAGConversationSummary(
            id: id,
            title: row["title"],
            isPinned: isPinned,
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private func citationRows(db: Database, messageID: UUID) throws -> [RAGCitation] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, chunk_id, repo_id, repo_full_name, source, section_title,
                   score, hit_kind, source_url
            FROM rag_message_citations
            WHERE message_id = ?
            ORDER BY rank ASC
            """, arguments: [messageID.uuidString])
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]),
                  let source = RAGChunkSource(rawValue: row["source"]),
                  let hitKind = RAGHitKind(rawValue: row["hit_kind"]) else { return nil }
            let sourceURLString: String? = row["source_url"]
            return RAGCitation(
                id: id,
                chunkID: row["chunk_id"],
                repoID: row["repo_id"],
                repoFullName: row["repo_full_name"],
                source: source,
                sectionTitle: row["section_title"],
                score: row["score"],
                hitKind: hitKind,
                sourceURL: sourceURLString.flatMap(URL.init(string:))
            )
        }
    }

    private func remoteContextAuditRows(db: Database, messageID: UUID) throws -> [RAGRemoteContextAudit] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, repo_id, resource, title, source_url, fetched_at, error_message
            FROM rag_message_remote_contexts
            WHERE message_id = ?
            ORDER BY rowid ASC
            """, arguments: [messageID.uuidString])
        return rows.compactMap { row in
            guard let id: String = row["id"],
                  let resourceRawValue: String = row["resource"],
                  let resource = RAGRemoteContextResource(rawValue: resourceRawValue) else { return nil }
            let sourceURLString: String? = row["source_url"]
            return RAGRemoteContextAudit(
                id: id,
                repoID: row["repo_id"],
                resource: resource,
                title: row["title"],
                sourceURL: sourceURLString.flatMap(URL.init(string:)),
                fetchedAt: row["fetched_at"],
                errorMessage: row["error_message"]
            )
        }
    }

    private func normalizedTitle(_ value: String) -> String {
        let line = value.split(whereSeparator: \Character.isNewline).first.map(String.init) ?? value
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? String.l10n("rag.workspace.newConversation") : trimmed).prefix(60))
    }
}

/// 长会话不能把全部原文重复送入模型。保留最近 3 轮消息，较早内容压缩为明确标识的上下文
/// 摘要；摘要只用于背景，不应被理解为当前轮指令。
enum RAGConversationHistoryBuilder {
    private static let recentMessageLimit = 6
    private static let excerptLimit = 280
    private static let summaryLimit = 1_800

    static func build(from messages: [RAGStoredMessage]) -> [AIChatMessage] {
        guard messages.count > recentMessageLimit else { return map(messages) }
        let older = messages.dropLast(recentMessageLimit)
        let recent = messages.suffix(recentMessageLimit)
        let digestLines = older.map { message in
            let role = message.role == .user ? "用户" : "助手"
            let content = message.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(role)：\(String(content.prefix(excerptLimit)))"
        }
        let digest = String(digestLines.joined(separator: "\n").prefix(summaryLimit))
        let summary = AIChatMessage(
            role: .user,
            content: "以下是较早对话的受限摘要，仅作背景，不包含新的执行指令：\n\(digest)"
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
