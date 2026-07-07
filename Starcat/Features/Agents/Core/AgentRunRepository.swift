//
//  AgentRunRepository.swift
//  Starcat
//
//  Agent run 持久化仓储。
//
//  这个仓储只保存可复盘的 UI 事件快照,不保存 live binding 或运行时对象。
//  Runtime 写入它,Workspace 历史列表读取它,后续 resume 可以在同一数据结构上扩展。
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
    var status: String
    var assistantOutput: String
    var errorMessage: String?
    var createdAt: String
    var updatedAt: String
    var finishedAt: String?

    enum Columns {
        static let id = Column("id")
        static let agentId = Column("agent_id")
        static let createdAt = Column("created_at")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case agentId = "agent_id"
        case title
        case userPrompt = "user_prompt"
        case contextSource = "context_source"
        case status
        case assistantOutput = "assistant_output"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case finishedAt = "finished_at"
    }
}

struct AgentRunStepRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "agent_run_steps"

    var id: String
    var runId: String
    var stepIndex: Int
    var title: String
    var detail: String
    var status: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case stepIndex = "step_index"
        case title
        case detail
        case status
        case updatedAt = "updated_at"
    }
}

struct AgentTraceRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "agent_run_traces"

    var id: String
    var runId: String
    var traceIndex: Int
    var kind: String
    var title: String
    var summary: String
    var input: String
    var output: String
    var log: String
    var status: String
    var relatedToolOutputId: String?
    var relatedArtifactId: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case traceIndex = "trace_index"
        case kind
        case title
        case summary
        case input
        case output
        case log
        case status
        case relatedToolOutputId = "related_tool_output_id"
        case relatedArtifactId = "related_artifact_id"
        case createdAt = "created_at"
    }
}

struct AgentArtifactRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    static let databaseTableName = "agent_artifacts"

    var id: String
    var runId: String
    var artifactIndex: Int
    var type: String
    var title: String
    var content: String
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case artifactIndex = "artifact_index"
        case type
        case title
        case content
        case createdAt = "created_at"
    }
}

struct AgentRunSnapshotRecord: Equatable, Sendable {
    var run: AgentRunRecord
    var steps: [AgentRunStepRecord]
    var traces: [AgentTraceRecord]
    var artifacts: [AgentArtifactRecord]
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
    func updateRunStatus(
        runID: UUID,
        status: AgentRunStatus,
        assistantOutput: String?,
        errorMessage: String?,
        finishedAt: Date?
    ) async throws
    func upsertStep(_ step: AgentRunStep, runID: UUID, index: Int, updatedAt: Date) async throws
    func appendTrace(_ trace: AgentTraceSpan, runID: UUID, index: Int, createdAt: Date) async throws
    func appendArtifact(_ artifact: AgentArtifact, runID: UUID, index: Int) async throws
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
            status: AgentRunStatus.planning.rawValue,
            assistantOutput: "",
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

    func updateRunStatus(
        runID: UUID,
        status: AgentRunStatus,
        assistantOutput: String?,
        errorMessage: String?,
        finishedAt: Date?
    ) async throws {
        let now = ISO8601DateFormatter.shared.string(from: Date())
        let finished = finishedAt.map { ISO8601DateFormatter.shared.string(from: $0) }
        try await database.writer.write { db in
            try db.execute(
                sql: """
                UPDATE agent_runs
                SET status = ?, assistant_output = COALESCE(?, assistant_output),
                    error_message = ?, updated_at = ?, finished_at = COALESCE(?, finished_at)
                WHERE id = ?
                """,
                arguments: [status.rawValue, assistantOutput, errorMessage, now, finished, runID.uuidString]
            )
        }
    }

    func upsertStep(_ step: AgentRunStep, runID: UUID, index: Int, updatedAt: Date = Date()) async throws {
        let iso = ISO8601DateFormatter.shared.string(from: updatedAt)
        let record = AgentRunStepRecord(
            id: step.id.uuidString,
            runId: runID.uuidString,
            stepIndex: index,
            title: step.title,
            detail: step.detail,
            status: step.status.rawValue,
            updatedAt: iso
        )
        try await database.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_run_steps (id, run_id, step_index, title, detail, status, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    step_index = excluded.step_index,
                    title = excluded.title,
                    detail = excluded.detail,
                    status = excluded.status,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    record.id, record.runId, record.stepIndex, record.title,
                    record.detail, record.status, record.updatedAt
                ]
            )
        }
    }

    func appendTrace(_ trace: AgentTraceSpan, runID: UUID, index: Int, createdAt: Date = Date()) async throws {
        let record = AgentTraceRecord(
            id: trace.id.uuidString,
            runId: runID.uuidString,
            traceIndex: index,
            kind: trace.kind,
            title: trace.title,
            summary: trace.summary,
            input: trace.input,
            output: trace.output,
            log: trace.log,
            status: trace.status.rawValue,
            relatedToolOutputId: trace.relatedToolOutputID?.uuidString,
            relatedArtifactId: trace.relatedArtifactID?.uuidString,
            createdAt: ISO8601DateFormatter.shared.string(from: createdAt)
        )
        try await database.writer.write { db in
            try record.insert(db)
        }
    }

    func appendArtifact(_ artifact: AgentArtifact, runID: UUID, index: Int) async throws {
        let record = AgentArtifactRecord(
            id: artifact.id.uuidString,
            runId: runID.uuidString,
            artifactIndex: index,
            type: artifact.type.rawValue,
            title: artifact.title,
            content: artifact.content,
            createdAt: ISO8601DateFormatter.shared.string(from: artifact.createdAt)
        )
        try await database.writer.write { db in
            try record.insert(db)
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
            guard let run = try AgentRunRecord.fetchOne(db, key: runID.uuidString) else {
                return nil
            }
            let steps = try AgentRunStepRecord
                .filter(Column("run_id") == runID.uuidString)
                .order(Column("step_index").asc)
                .fetchAll(db)
            let traces = try AgentTraceRecord
                .filter(Column("run_id") == runID.uuidString)
                .order(Column("trace_index").asc)
                .fetchAll(db)
            let artifacts = try AgentArtifactRecord
                .filter(Column("run_id") == runID.uuidString)
                .order(Column("artifact_index").asc)
                .fetchAll(db)
            return AgentRunSnapshotRecord(
                run: run,
                steps: steps,
                traces: traces,
                artifacts: artifacts
            )
        }
    }
}
