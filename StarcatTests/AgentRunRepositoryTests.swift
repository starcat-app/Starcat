//
//  AgentRunRepositoryTests.swift
//  StarcatTests
//
//  验证 Agent 事实表、事务状态更新和按 sequence 的完整恢复。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentRunRepository")
struct AgentRunRepositoryTests {
    @Test("创建 run 并按时间读取最近历史")
    func createsRunAndFetchesRecentHistory() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let first = try await repository.createRun(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "first",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: fixedDate(0)
        )
        let second = try await repository.createRun(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "second",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: fixedDate(60)
        )

        let recent = try await repository.recentRuns(limit: 10)

        #expect(first.userPrompt == "first")
        #expect(recent.map(\.id) == [second.id, first.id])
    }

    @Test("保存消息、审批和 artifact 后按 sequence 恢复完整事实")
    func restoresMessageApprovalAndArtifactFacts() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let context = AgentRunContext(
            sourceDescription: "Unit",
            generatedAt: fixedDate(0),
            repos: [repoSnapshot()]
        )
        _ = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成周刊",
            context: context,
            createdAt: fixedDate(0)
        )
        let user = AgentMessage(
            runID: runID,
            role: .user,
            turn: 0,
            sequence: 0,
            parts: [.text("生成周刊")],
            createdAt: fixedDate(1)
        )
        let call = AgentToolCall(
            id: "call-1",
            name: "artifact_build_weekly_report",
            input: .object(["title": .string("Weekly")]),
            rawInput: "{\"title\":\"Weekly\"}",
            sequence: 1
        )
        let assistant = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 0,
            sequence: 1,
            parts: [.reasoning("生成产出物"), .toolCall(call)],
            usage: .init(inputTokens: 10, outputTokens: 2),
            createdAt: fixedDate(2)
        )
        let toolResult = AgentToolResultMessage(
            toolCallID: call.id,
            toolName: call.name,
            output: .object(["markdown": .string("# Weekly")]),
            isError: false,
            status: .completed,
            elapsedMilliseconds: 8,
            sequence: 2
        )
        let toolMessage = AgentMessage(
            runID: runID,
            role: .tool,
            turn: 0,
            sequence: 2,
            parts: [.toolResult(toolResult)],
            createdAt: fixedDate(3)
        )
        try await repository.appendMessage(user, runStatus: .running)
        try await repository.appendMessage(assistant, runStatus: .running)
        try await repository.appendMessage(toolMessage, runStatus: .running)

        let approval = AgentApprovalRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            runID: runID,
            toolCallID: "call-write",
            toolName: "tag_apply",
            input: .object(["tag": .string("swift")]),
            permission: .requiresConfirmation,
            sequence: 3,
            createdAt: fixedDate(4)
        )
        try await repository.saveApproval(approval, runStatus: .waitingForConfirmation)
        let artifact = AgentArtifact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            type: .markdown,
            title: "Weekly",
            content: "# Weekly",
            toolCallID: call.id,
            messageID: toolMessage.id,
            sequence: toolMessage.sequence,
            createdAt: fixedDate(5)
        )
        try await repository.appendArtifact(artifact, runID: runID)

        let snapshot = try #require(try await repository.snapshot(runID: runID))

        #expect(snapshot.run.status == AgentRunStatus.waitingForConfirmation.rawValue)
        #expect(snapshot.context == context)
        #expect(snapshot.messages.map(\.sequence) == [0, 1, 2])
        #expect(snapshot.messages[1].usage?.totalTokens == 12)
        #expect(snapshot.approvals == [approval])
        #expect(snapshot.artifacts.first?.toolCallID == call.id)
        #expect(snapshot.artifacts.first?.messageID == toolMessage.id)
        #expect(snapshot.artifacts.first?.sequence == toolMessage.sequence)
    }

    @Test("消息插入失败时 run 状态不会发生部分更新")
    func messageAndStatusUpdateAreTransactional() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID()
        _ = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "transaction",
            context: .empty,
            createdAt: fixedDate(0)
        )
        let first = AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("first")])
        let duplicateSequence = AgentMessage(runID: runID, role: .assistant, turn: 0, sequence: 0, parts: [.text("duplicate")])
        try await repository.appendMessage(first, runStatus: .running)

        await #expect(throws: (any Error).self) {
            try await repository.appendMessage(duplicateSequence, runStatus: .completed)
        }
        let snapshot = try #require(try await repository.snapshot(runID: runID))

        #expect(snapshot.messages.count == 1)
        #expect(snapshot.run.status == AgentRunStatus.running.rawValue)
    }

    private func fixedDate(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_788_000_000 + offset)
    }

    private func repoSnapshot() -> AgentRepoSnapshot {
        AgentRepoSnapshot(
            id: 42,
            owner: "groue",
            name: "GRDB.swift",
            fullName: "groue/GRDB.swift",
            description: "SQLite toolkit",
            language: "Swift",
            starsCount: 8_000,
            topics: ["sqlite"],
            isStarred: true,
            starredAt: nil,
            htmlUrl: "https://github.com/groue/GRDB.swift"
        )
    }
}
