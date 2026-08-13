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

    @Test("knowledge retrieval audit 随 parts_json 完整恢复")
    func restoresKnowledgeRetrievalAuditFromMessageFacts() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID()
        _ = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.repoInsight,
            prompt: "检查数据库写入",
            context: AgentRunContext(sourceDescription: "Unit", repos: [repoSnapshot()]),
            createdAt: fixedDate(0)
        )
        let call = AgentToolCall(
            id: "call-knowledge",
            name: "knowledge_search",
            input: .object(["query": .string("database writes")]),
            sequence: 1
        )
        let audit = AgentKnowledgeRetrievalAudit(
            scopeMode: .only,
            frozenRepoIDs: [42],
            explicitRepoIDs: [42],
            evidenceBlockCount: 1,
            citations: [AgentKnowledgeCitationAudit(
                marker: "S1",
                chunkID: 99,
                repoID: 42,
                repoFullName: "groue/GRDB.swift",
                source: "readme",
                sectionTitle: "Usage",
                score: 0.8,
                hitKind: "hybrid",
                vectorSimilarity: 0.7,
                sourceURL: "https://github.com/groue/GRDB.swift"
            )],
            retrievalTrace: RAGRetrievalTrace(candidates: [
                RAGRetrievalCandidateTrace(repoID: 42, fullName: "groue/GRDB.swift")
            ]),
            diagnostics: nil,
            limitations: []
        )
        let messages = [
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("检查数据库写入")]),
            AgentMessage(runID: runID, role: .assistant, turn: 0, sequence: 1, parts: [.toolCall(call)]),
            AgentMessage(
                runID: runID,
                role: .tool,
                turn: 0,
                sequence: 2,
                parts: [.toolResult(AgentToolResultMessage(
                    toolCallID: call.id,
                    toolName: call.name,
                    output: .object(["summary": .string("1 evidence")]),
                    isError: false,
                    status: .completed,
                    toolAudit: .knowledge(audit),
                    sequence: 2
                ))]
            )
        ]
        for message in messages {
            try await repository.appendMessage(message, runStatus: .running)
        }

        let snapshot = try #require(try await repository.snapshot(runID: runID))
        guard case .toolResult(let restoredResult) = snapshot.messages[2].parts.first else {
            Issue.record("Expected restored tool result")
            return
        }

        #expect(restoredResult.toolAudit?.knowledgeRetrieval?.frozenRepoIDs == [42])
        #expect(restoredResult.toolAudit?.knowledgeRetrieval?.retrievalTrace?.candidates.first?.repoID == 42)
        #expect(restoredResult.toolAudit?.knowledgeRetrieval?.citations.first?.marker == "S1")
    }

    @Test("附件正文只在运行期存在，历史快照仅保留元数据")
    func attachmentBodyIsRemovedFromPersistenceSnapshot() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID()
        let content = "private draft body"
        _ = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成周刊",
            context: AgentRunContext(
                sourceDescription: "Unit",
                attachments: [AgentPromptAttachment(
                    name: "brief.md",
                    content: content,
                    contentType: "net.daringfireball.markdown"
                )]
            ),
            createdAt: fixedDate(0)
        )

        let snapshot = try #require(try await repository.snapshot(runID: runID))
        let attachment = try #require(snapshot.context.attachments.first)

        #expect(attachment.name == "brief.md")
        #expect(attachment.content.isEmpty)
        #expect(attachment.contentType == "net.daringfireball.markdown")
        #expect(attachment.byteCount == content.utf8.count)
        #expect(attachment.contentHash?.count == 64)
        #expect(snapshot.context.hasUnavailableAttachmentBodies)
    }

    @Test("旧版 context JSON 缺少 Composer 字段时仍可解码")
    func legacyContextJSONRemainsDecodable() throws {
        let json = #"{"sourceDescription":"Legacy","generatedAt":"2026-07-07T00:00:00Z","repos":[],"attachments":[]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let context = try decoder.decode(AgentRunContext.self, from: Data(json.utf8))

        #expect(context.sourceDescription == "Legacy")
        #expect(context.explicitRepos == nil)
        #expect(context.explicitRepoMode == nil)
        #expect(context.selectedModelID == nil)
        #expect(context.githubLinks == nil)
        #expect(context.webSearchEnabled == nil)
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

    @Test("失败和取消终态可从持久化 run 精确恢复", arguments: [AgentRunStatus.failed, .cancelled])
    func restoresFailedAndCancelledTerminalStates(status: AgentRunStatus) async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID()
        _ = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "terminal",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: fixedDate(0)
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("terminal")]),
            runStatus: .running
        )
        let errorMessage = status == .failed ? "provider unavailable" : nil
        try await repository.updateRunStatus(
            runID: runID,
            status: status,
            model: "test-model",
            usage: AgentUsage(inputTokens: 4, outputTokens: 1),
            errorMessage: errorMessage,
            finishedAt: fixedDate(10)
        )

        let snapshot = try #require(try await repository.snapshot(runID: runID))

        #expect(snapshot.run.status == status.rawValue)
        #expect(snapshot.run.errorMessage == errorMessage)
        #expect(snapshot.run.finishedAt != nil)
        #expect(snapshot.messages.map(\.sequence) == [0])
    }

    @Test("失败 run 重试时清除旧错误和终态时间并保留模型用量")
    func retryTransitionClearsPreviousTerminalFacts() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID()
        _ = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "retry",
            context: .empty,
            createdAt: fixedDate(0)
        )
        let usage = AgentUsage(inputTokens: 8, outputTokens: 2)
        try await repository.updateRunStatus(
            runID: runID,
            status: .failed,
            model: "test-model",
            usage: usage,
            errorMessage: "provider unavailable",
            finishedAt: fixedDate(10)
        )

        try await repository.restartFailedRun(runID: runID, usage: usage)
        let snapshot = try #require(try await repository.snapshot(runID: runID))

        #expect(snapshot.run.status == AgentRunStatus.running.rawValue)
        #expect(snapshot.run.model == "test-model")
        #expect(snapshot.run.errorMessage == nil)
        #expect(snapshot.run.finishedAt == nil)
        let usageData = try #require(snapshot.run.usageJSON?.data(using: .utf8))
        let persistedUsage = try JSONDecoder().decode(AgentUsage.self, from: usageData)
        #expect(persistedUsage == usage)

        await #expect(throws: AgentRunRetryValidationError.notFailed) {
            try await repository.restartFailedRun(runID: runID, usage: usage)
        }
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
            isPrivate: false,
            isStarred: true,
            starredAt: nil,
            htmlUrl: "https://github.com/groue/GRDB.swift"
        )
    }
}
