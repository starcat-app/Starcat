//
//  AIOrganizationDraftRepository.swift
//  Starcat
//
//  AI 整理草稿的账户级持久化边界。
//
//  模块职责：
//  - 保存一轮手动整理的轻量 Header 与逐仓 Item，避免 App 强退后丢失未确认结果；
//  - 始终通过 DatabaseManaging 的动态 writer 访问当前账号数据库；
//  - 用 draft id 防止账号切换后的迟到异步任务污染新账号草稿。
//
//  关键约束：
//  - 不保存 API Key、完整 Prompt、原始 Request / Response 或 copyDiagnostic；
//  - 同一账号、同一种整理类型只允许一个活动草稿；
//  - 新会话建立 Header 与全部 Item 必须处于同一事务，AI 调用只能在事务成功后开始。
//

import Foundation
import GRDB

enum AIOrganizationDraftKind: String, Codable, Sendable {
    case batchTags = "batch_tags"
    case githubStarLists = "github_star_lists"
}

struct AIOrganizationDraftItem: Equatable, Sendable {
    let repoID: Int64
    let payloadJSON: String
}

struct AIOrganizationDraft: Equatable, Sendable {
    let id: UUID
    let kind: AIOrganizationDraftKind
    let headerJSON: String
    let items: [AIOrganizationDraftItem]
}

protocol AIOrganizationDraftRepositoryProtocol: Sendable {
    func replaceDraft(_ draft: AIOrganizationDraft) async throws
    func loadDraft(kind: AIOrganizationDraftKind) async throws -> AIOrganizationDraft?
    func updateHeader(draftID: UUID, kind: AIOrganizationDraftKind, headerJSON: String) async throws
    func upsertItem(
        draftID: UUID,
        kind: AIOrganizationDraftKind,
        repoID: Int64,
        payloadJSON: String
    ) async throws
    func deleteItems(draftID: UUID, kind: AIOrganizationDraftKind, repoIDs: Set<Int64>) async throws
    func deleteDraft(draftID: UUID, kind: AIOrganizationDraftKind) async throws
}

struct GRDBAIOrganizationDraftRepository: AIOrganizationDraftRepositoryProtocol {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func replaceDraft(_ draft: AIOrganizationDraft) async throws {
        let now = Date().timeIntervalSince1970
        try await database.writer.write { db in
            // 用户明确开始新一轮时，内存状态已确认不存在未解决任务。这里原子替换同类草稿，
            // 同时清掉可能因上次“已解决清理”失败而残留的空壳记录。
            try db.execute(
                sql: "DELETE FROM ai_organization_drafts WHERE kind = ?",
                arguments: [draft.kind.rawValue]
            )
            try db.execute(
                sql: """
                    INSERT INTO ai_organization_drafts
                        (id, kind, header_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [draft.id.uuidString, draft.kind.rawValue, draft.headerJSON, now, now]
            )
            for item in draft.items {
                try db.execute(
                    sql: """
                        INSERT INTO ai_organization_draft_items
                            (draft_id, repo_id, payload_json, updated_at)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [draft.id.uuidString, item.repoID, item.payloadJSON, now]
                )
            }
        }
    }

    func loadDraft(kind: AIOrganizationDraftKind) async throws -> AIOrganizationDraft? {
        try await database.writer.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, header_json
                    FROM ai_organization_drafts
                    WHERE kind = ?
                    LIMIT 1
                    """,
                arguments: [kind.rawValue]
            ),
            let id = UUID(uuidString: row["id"])
            else { return nil }

            let itemRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT repo_id, payload_json
                    FROM ai_organization_draft_items
                    WHERE draft_id = ?
                    ORDER BY repo_id
                    """,
                arguments: [id.uuidString]
            )
            return AIOrganizationDraft(
                id: id,
                kind: kind,
                headerJSON: row["header_json"],
                items: itemRows.map { row in
                    AIOrganizationDraftItem(repoID: row["repo_id"], payloadJSON: row["payload_json"])
                }
            )
        }
    }

    func updateHeader(
        draftID: UUID,
        kind: AIOrganizationDraftKind,
        headerJSON: String
    ) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: """
                    UPDATE ai_organization_drafts
                    SET header_json = ?, updated_at = ?
                    WHERE id = ? AND kind = ?
                    """,
                arguments: [headerJSON, Date().timeIntervalSince1970, draftID.uuidString, kind.rawValue]
            )
        }
    }

    func upsertItem(
        draftID: UUID,
        kind: AIOrganizationDraftKind,
        repoID: Int64,
        payloadJSON: String
    ) async throws {
        let now = Date().timeIntervalSince1970
        try await database.writer.write { db in
            // EXISTS 是账号切换屏障：旧账号 Task 即使迟到，新账号库里没有相同 draft id，
            // 写入会自然 no-op，而不是凭 repo id 创建一条跨账号孤儿记录。
            try db.execute(
                sql: """
                    INSERT INTO ai_organization_draft_items
                        (draft_id, repo_id, payload_json, updated_at)
                    SELECT ?, ?, ?, ?
                    WHERE EXISTS (
                        SELECT 1 FROM ai_organization_drafts WHERE id = ? AND kind = ?
                    )
                    ON CONFLICT(draft_id, repo_id) DO UPDATE SET
                        payload_json = excluded.payload_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    draftID.uuidString,
                    repoID,
                    payloadJSON,
                    now,
                    draftID.uuidString,
                    kind.rawValue,
                ]
            )
            try db.execute(
                sql: """
                    UPDATE ai_organization_drafts
                    SET updated_at = ?
                    WHERE id = ? AND kind = ?
                    """,
                arguments: [now, draftID.uuidString, kind.rawValue]
            )
        }
    }

    func deleteDraft(draftID: UUID, kind: AIOrganizationDraftKind) async throws {
        try await database.writer.write { db in
            try db.execute(
                sql: "DELETE FROM ai_organization_drafts WHERE id = ? AND kind = ?",
                arguments: [draftID.uuidString, kind.rawValue]
            )
        }
    }

    func deleteItems(
        draftID: UUID,
        kind: AIOrganizationDraftKind,
        repoIDs: Set<Int64>
    ) async throws {
        guard !repoIDs.isEmpty else { return }
        try await database.writer.write { db in
            let placeholders = Array(repeating: "?", count: repoIDs.count).joined(separator: ",")
            var arguments: StatementArguments = [draftID.uuidString]
            arguments += StatementArguments(repoIDs.sorted())
            try db.execute(
                sql: """
                    DELETE FROM ai_organization_draft_items
                    WHERE draft_id = ? AND repo_id IN (\(placeholders))
                    """,
                arguments: arguments
            )
            try db.execute(
                sql: """
                    UPDATE ai_organization_drafts
                    SET updated_at = ?
                    WHERE id = ? AND kind = ?
                    """,
                arguments: [
                    Date().timeIntervalSince1970,
                    draftID.uuidString,
                    kind.rawValue,
                ]
            )
        }
    }
}

enum AIOrganizationDraftJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return result
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        guard let data = value.data(using: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
