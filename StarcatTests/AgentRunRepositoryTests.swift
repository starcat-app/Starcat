//
//  AgentRunRepositoryTests.swift
//  StarcatTests
//
//  Agent run 持久化仓储测试。
//
//  这些测试锁住数据库迁移和 Repository 最小契约,保证 Runtime/UI 接入前
//  已经有稳定的本地历史读写能力。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentRunRepository")
struct AgentRunRepositoryTests {

    @Test("创建 run 并读取最近历史")
    func createRunAndFetchRecentRuns() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAgentRunRepository(database: database)
        let firstDate = fixedDate(0)
        let secondDate = fixedDate(60)

        let first = try await repository.createRun(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "first",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: firstDate
        )
        let second = try await repository.createRun(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "second",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: secondDate
        )

        let recent = try await repository.recentRuns(limit: 10)

        #expect(first.userPrompt == "first")
        #expect(second.userPrompt == "second")
        #expect(recent.map(\.id) == [second.id, first.id])
    }

    @Test("保存 step trace artifact 并读取完整快照")
    func storesSnapshotParts() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAgentRunRepository(database: database)
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        _ = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成周刊",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: fixedDate(0)
        )
        let step = AgentRunStep(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            title: "解析任务目标",
            detail: "Markdown Weekly Report",
            status: .completed
        )
        let trace = AgentTraceSpan(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            kind: "Tool",
            title: "agent.parseGoal",
            summary: "ok",
            input: "prompt",
            output: "goal",
            log: "log"
        )
        let artifact = AgentArtifact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            type: .markdown,
            title: "本周 GitHub 热门项目周刊",
            content: "# Weekly",
            createdAt: fixedDate(120)
        )

        try await repository.upsertStep(step, runID: runID, index: 0, updatedAt: fixedDate(10))
        try await repository.appendTrace(trace, runID: runID, index: 0, createdAt: fixedDate(20))
        try await repository.appendArtifact(artifact, runID: runID, index: 0)
        try await repository.updateRunStatus(
            runID: runID,
            status: .completed,
            assistantOutput: "# Weekly",
            errorMessage: nil,
            finishedAt: fixedDate(180)
        )

        let snapshot = try await repository.snapshot(runID: runID)

        #expect(snapshot?.run.status == AgentRunStatus.completed.rawValue)
        #expect(snapshot?.run.assistantOutput == "# Weekly")
        #expect(snapshot?.steps.first?.title == "解析任务目标")
        #expect(snapshot?.traces.first?.title == "agent.parseGoal")
        #expect(snapshot?.artifacts.first?.content == "# Weekly")
    }

    @Test("step 使用相同 id 时会更新状态")
    func upsertStepUpdatesExistingRecord() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAgentRunRepository(database: database)
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let stepID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        _ = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成周刊",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: fixedDate(0)
        )

        try await repository.upsertStep(
            AgentRunStep(id: stepID, title: "准备数据源", detail: "running", status: .running),
            runID: runID,
            index: 0,
            updatedAt: fixedDate(1)
        )
        try await repository.upsertStep(
            AgentRunStep(id: stepID, title: "准备数据源", detail: "done", status: .completed),
            runID: runID,
            index: 0,
            updatedAt: fixedDate(2)
        )

        let snapshot = try await repository.snapshot(runID: runID)

        #expect(snapshot?.steps.count == 1)
        #expect(snapshot?.steps.first?.detail == "done")
        #expect(snapshot?.steps.first?.status == AgentStepStatus.completed.rawValue)
    }

    private func fixedDate(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_788_000_000 + offset)
    }
}
