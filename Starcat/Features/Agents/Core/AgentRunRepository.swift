//
//  AgentRunRepository.swift
//  Starcat
//
//  Agent run 的事实型持久化仓储。
//
//  `agent_messages` 是 user/assistant/tool/tool-result 的唯一执行事实源；Step、Trace 和
//  ToolOutput 只允许由消息投影，不能各自落表，否则重启后会出现顺序和状态不一致。
//  message/approval 写入与 run 状态更新使用同一 GRDB transaction。
//

import Foundation
import GRDB

// MARK: - Records

struct AgentRunRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "agent_runs"

    var id: String
    var agentId: String
    var title: String
    var userPrompt: String
    var contextSource: String
    var contextJSON: String
    var status: String
    var model: String?
    var usageJSON: String?
    var errorMessage: String?
    var createdAt: String
    var updatedAt: String
    var finishedAt: String?

    enum Columns {
        static let createdAt = Column("created_at")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case agentId = "agent_id"
        case title
        case userPrompt = "user_prompt"
        case contextSource = "context_source"
        case contextJSON = "context_json"
        case status
        case model
        case usageJSON = "usage_json"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case finishedAt = "finished_at"
    }
}

struct AgentMessageRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "agent_messages"

    var id: String
    var runId: String
    var role: String
    var turn: Int
    var sequence: Int
    var partsJSON: String
    var usageJSON: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case role
        case turn
        case sequence
        case partsJSON = "parts_json"
        case usageJSON = "usage_json"
        case createdAt = "created_at"
    }

    init(message: AgentMessage) throws {
        id = message.id.uuidString
        runId = message.runID.uuidString
        role = message.role.rawValue
        turn = message.turn
        sequence = message.sequence
        partsJSON = try AgentPersistenceJSON.encode(message.parts)
        usageJSON = try message.usage.map(AgentPersistenceJSON.encode)
        createdAt = ISO8601DateFormatter.shared.string(from: message.createdAt)
    }

    func message() throws -> AgentMessage {
        guard let id = UUID(uuidString: id),
              let runID = UUID(uuidString: runId),
              let role = AgentMessageRole(rawValue: role)
        else { throw AgentRunRepositoryError.invalidRecord("message \(self.id)") }
        return AgentMessage(
            id: id,
            runID: runID,
            role: role,
            turn: turn,
            sequence: sequence,
            parts: try AgentPersistenceJSON.decode([AgentMessagePart].self, from: partsJSON),
            usage: try usageJSON.map { try AgentPersistenceJSON.decode(AgentUsage.self, from: $0) },
            createdAt: ISO8601DateFormatter.shared.date(from: createdAt) ?? Date.distantPast
        )
    }
}

struct AgentApprovalRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "agent_approvals"

    var id: String
    var runId: String
    var toolCallId: String
    var toolName: String
    var inputJSON: String
    var permission: String
    var sequence: Int
    var status: String
    var createdAt: String
    var decidedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case toolCallId = "tool_call_id"
        case toolName = "tool_name"
        case inputJSON = "input_json"
        case permission
        case sequence
        case status
        case createdAt = "created_at"
        case decidedAt = "decided_at"
    }

    init(approval: AgentApprovalRequest) throws {
        id = approval.id.uuidString
        runId = approval.runID.uuidString
        toolCallId = approval.toolCallID
        toolName = approval.toolName
        inputJSON = try AgentPersistenceJSON.encode(approval.input)
        permission = approval.permission.rawValue
        sequence = approval.sequence
        status = approval.status.rawValue
        createdAt = ISO8601DateFormatter.shared.string(from: approval.createdAt)
        decidedAt = approval.decidedAt.map { ISO8601DateFormatter.shared.string(from: $0) }
    }

    func approval() throws -> AgentApprovalRequest {
        guard let id = UUID(uuidString: id),
              let runID = UUID(uuidString: runId),
              let permission = AgentToolPermission(rawValue: permission),
              let status = AgentApprovalStatus(rawValue: status)
        else { throw AgentRunRepositoryError.invalidRecord("approval \(self.id)") }
        return AgentApprovalRequest(
            id: id,
            runID: runID,
            toolCallID: toolCallId,
            toolName: toolName,
            input: try AgentPersistenceJSON.decode(AgentJSONValue.self, from: inputJSON),
            permission: permission,
            sequence: sequence,
            status: status,
            createdAt: ISO8601DateFormatter.shared.date(from: createdAt) ?? Date.distantPast,
            decidedAt: decidedAt.flatMap(ISO8601DateFormatter.shared.date)
        )
    }
}

struct AgentArtifactRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "agent_artifacts"

    var id: String
    var runId: String
    var toolCallId: String?
    var messageId: String?
    var sequence: Int
    var type: String
    var title: String
    var content: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case toolCallId = "tool_call_id"
        case messageId = "message_id"
        case sequence
        case type
        case title
        case content
        case createdAt = "created_at"
    }

    init(artifact: AgentArtifact, runID: UUID) {
        id = artifact.id.uuidString
        runId = runID.uuidString
        toolCallId = artifact.toolCallID
        messageId = artifact.messageID?.uuidString
        sequence = artifact.sequence
        type = artifact.type.rawValue
        title = artifact.title
        content = artifact.content
        createdAt = ISO8601DateFormatter.shared.string(from: artifact.createdAt)
    }

    func artifact() throws -> AgentArtifact {
        guard let id = UUID(uuidString: id), let type = AgentArtifactType(rawValue: type) else {
            throw AgentRunRepositoryError.invalidRecord("artifact \(self.id)")
        }
        return AgentArtifact(
            id: id,
            type: type,
            title: title,
            content: content,
            toolCallID: toolCallId,
            messageID: messageId.flatMap(UUID.init(uuidString:)),
            sequence: sequence,
            createdAt: ISO8601DateFormatter.shared.date(from: createdAt) ?? Date.distantPast
        )
    }
}

struct AgentRunSnapshotRecord: Equatable, Sendable {
    var run: AgentRunRecord
    var context: AgentRunContext
    var messages: [AgentMessage]
    var approvals: [AgentApprovalRequest]
    var artifacts: [AgentArtifact]
}

enum AgentRunRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case invalidRecord(String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord(let value):
            return String(format: String.l10n("agent.persistence.error.invalidRecordFormat"), value)
        }
    }
}

// MARK: - Repository

protocol AgentRunRepositoryProtocol: Sendable {
    func createRun(
        id: UUID,
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext,
        createdAt: Date
    ) async throws -> AgentRunRecord
    func appendMessage(_ message: AgentMessage, runStatus: AgentRunStatus?) async throws
    func saveApproval(_ approval: AgentApprovalRequest, runStatus: AgentRunStatus) async throws
    func updateRunStatus(
        runID: UUID,
        status: AgentRunStatus,
        model: String?,
        usage: AgentUsage?,
        errorMessage: String?,
        finishedAt: Date?
    ) async throws
    func restartFailedRun(runID: UUID, usage: AgentUsage) async throws
    func recoverInterruptedRuns(errorMessage: String, recoveredAt: Date) async throws -> Int
    func appendArtifact(_ artifact: AgentArtifact, runID: UUID) async throws
    func recentRuns(limit: Int) async throws -> [AgentRunRecord]
    func snapshot(runID: UUID) async throws -> AgentRunSnapshotRecord?
}

struct GRDBAgentRunRepository: AgentRunRepositoryProtocol {
    private let database: any DatabaseManaging

    init(database: any DatabaseManaging) {
        self.database = database
    }

    func createRun(
        id: UUID,
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext,
        createdAt: Date = Date()
    ) async throws -> AgentRunRecord {
        let iso = ISO8601DateFormatter.shared.string(from: createdAt)
        let record = AgentRunRecord(
            id: id.uuidString,
            agentId: definition.id,
            title: definition.title,
            userPrompt: prompt,
            contextSource: context.sourceDescription,
            // 附件正文只属于当前 Runtime；历史记录保留名称、字节数和 SHA-256，避免把
            // 用户临时材料长期复制进数据库。
            contextJSON: try AgentPersistenceJSON.encode(context.persistenceSnapshot),
            status: AgentRunStatus.planning.rawValue,
            model: nil,
            usageJSON: nil,
            errorMessage: nil,
            createdAt: iso,
            updatedAt: iso,
            finishedAt: nil
        )
        try await database.writer.write { db in
            try record.insert(db)
        }
        return record
    }

    func appendMessage(_ message: AgentMessage, runStatus: AgentRunStatus?) async throws {
        let record = try AgentMessageRecord(message: message)
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try record.insert(db)
            try db.execute(
                sql: """
                UPDATE agent_runs
                SET status = COALESCE(?, status), updated_at = ?
                WHERE id = ?
                """,
                arguments: [runStatus?.rawValue, now, message.runID.uuidString]
            )
        }
    }

    func saveApproval(_ approval: AgentApprovalRequest, runStatus: AgentRunStatus) async throws {
        let record = try AgentApprovalRecord(approval: approval)
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try record.save(db)
            try db.execute(
                sql: "UPDATE agent_runs SET status = ?, updated_at = ? WHERE id = ?",
                arguments: [runStatus.rawValue, now, approval.runID.uuidString]
            )
        }
    }

    func updateRunStatus(
        runID: UUID,
        status: AgentRunStatus,
        model: String?,
        usage: AgentUsage?,
        errorMessage: String?,
        finishedAt: Date?
    ) async throws {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let finished = finishedAt.map { ISO8601DateFormatter.shared.string(from: $0) }
        let usageJSON = try usage.map(AgentPersistenceJSON.encode)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE agent_runs
                SET status = ?, model = COALESCE(?, model), usage_json = COALESCE(?, usage_json),
                    error_message = ?, updated_at = ?, finished_at = COALESCE(?, finished_at)
                WHERE id = ?
                """,
                arguments: [status.rawValue, model, usageJSON, errorMessage, now, finished, runID.uuidString]
            )
        }
    }

    /// 失败重试是唯一需要主动清空终态字段的状态迁移，因此使用独立 SQL，避免把
    /// `updateRunStatus` 中 `nil` 表示“不覆盖”的既有语义改成“清空”。
    func restartFailedRun(runID: UUID, usage: AgentUsage) async throws {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let usageJSON = try AgentPersistenceJSON.encode(usage)
        try await database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE agent_runs
                SET status = ?, usage_json = ?, error_message = NULL,
                    updated_at = ?, finished_at = NULL
                WHERE id = ? AND status = ?
                """,
                arguments: [
                    AgentRunStatus.running.rawValue,
                    usageJSON,
                    now,
                    runID.uuidString,
                    AgentRunStatus.failed.rawValue,
                ]
            )
            guard db.changesCount == 1 else {
                throw AgentRunRetryValidationError.notFailed
            }
        }
    }

    /// App 进程结束后不会再有 Runtime 驱动 `planning` / `running` Run，因此首次加载
    /// 历史时必须把这些遗留状态收口成可重试失败态。`waitingForConfirmation` 刻意排除：
    /// 它拥有独立的恢复协议，不能被启动清理误伤。
    func recoverInterruptedRuns(errorMessage: String, recoveredAt: Date = Date()) async throws -> Int {
        let recovered = ISO8601DateFormatter.shared.string(from: recoveredAt)
        return try await database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE agent_runs
                SET status = ?, error_message = ?, updated_at = ?, finished_at = ?
                WHERE status IN (?, ?)
                """,
                arguments: [
                    AgentRunStatus.failed.rawValue,
                    errorMessage,
                    recovered,
                    recovered,
                    AgentRunStatus.planning.rawValue,
                    AgentRunStatus.running.rawValue,
                ]
            )
            return db.changesCount
        }
    }

    func appendArtifact(_ artifact: AgentArtifact, runID: UUID) async throws {
        let record = AgentArtifactRecord(artifact: artifact, runID: runID)
        let now = ISO8601DateFormatter.shared.string(from: Date())
        try await database.writer.write { db in
            try record.insert(db)
            try db.execute(
                sql: "UPDATE agent_runs SET updated_at = ? WHERE id = ?",
                arguments: [now, runID.uuidString]
            )
        }
    }

    func recentRuns(limit: Int) async throws -> [AgentRunRecord] {
        try await database.writer.read { db in
            try AgentRunRecord
                .order(AgentRunRecord.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func snapshot(runID: UUID) async throws -> AgentRunSnapshotRecord? {
        try await database.writer.read { db in
            guard let run = try AgentRunRecord.fetchOne(db, key: runID.uuidString) else { return nil }
            let messageRecords = try AgentMessageRecord
                .filter(Column("run_id") == runID.uuidString)
                .order(Column("sequence").asc)
                .fetchAll(db)
            let approvalRecords = try AgentApprovalRecord
                .filter(Column("run_id") == runID.uuidString)
                .order(Column("sequence").asc)
                .fetchAll(db)
            let artifactRecords = try AgentArtifactRecord
                .filter(Column("run_id") == runID.uuidString)
                .order(Column("sequence").asc)
                .fetchAll(db)
            let messages = try messageRecords.map { try $0.message() }
            try AgentMessageContract.validate(messages)
            return AgentRunSnapshotRecord(
                run: run,
                context: try AgentPersistenceJSON.decode(AgentRunContext.self, from: run.contextJSON),
                messages: messages,
                approvals: try approvalRecords.map { try $0.approval() },
                artifacts: try artifactRecords.map { try $0.artifact() }
            )
        }
    }
}

private enum AgentPersistenceJSON {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw AgentRunRepositoryError.invalidRecord("non-UTF8 JSON")
        }
        return string
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw AgentRunRepositoryError.invalidRecord("non-UTF8 JSON")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
