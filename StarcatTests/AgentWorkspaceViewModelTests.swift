//
//  AgentWorkspaceViewModelTests.swift
//  StarcatTests
//
//  Agent Workspace ViewModel 的事件消费测试。
//
//  这些测试不验证 SwiftUI 布局,只锁住 ViewModel 对 AgentRunEvent 的状态投影。
//  这样后续 runtime 从本地只读工具切换到模型 tool-calling 时,工作台仍能依赖
//  同一组 message / approval / artifact 事实状态。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("AgentWorkspaceViewModel")
struct AgentWorkspaceViewModelTests {

    @Test("run 会把 runtime 事件投影成工作台状态")
    func runProjectsRuntimeEventsIntoWorkspaceState() async throws {
        let runID = UUID()
        let artifact = AgentArtifact(type: .markdown, title: "周刊", content: "# 周刊")
        let logArtifact = AgentArtifact(type: .log, title: "日志", content: "# Log")
        let user = AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("生成周刊")])
        let assistant = AgentMessage(runID: runID, role: .assistant, turn: 0, sequence: 1, parts: [.text("开始整理")])
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: BuiltInAgents.githubWeeklyReport.title),
            .messageAppended(user),
            .messageAppended(assistant),
            .artifactCreated(artifact),
            .artifactCreated(logArtifact),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        viewModel.prompt = "生成本周 GitHub 热门项目周刊"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.runTitle == BuiltInAgents.githubWeeklyReport.title)
        #expect(viewModel.messages.map(\.role) == [.user, .assistant])
        #expect(viewModel.artifacts.count == 2)
        #expect(viewModel.selectedArtifact?.content == "# 周刊")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("selectedArtifactID 会联动 Inspector 当前产出物")
    func artifactSelectionUsesRealArtifactState() async throws {
        let first = AgentArtifact(type: .markdown, title: "周刊", content: "# Weekly")
        let second = AgentArtifact(type: .log, title: "日志", content: "run log")
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: "Run"),
            .artifactCreated(first),
            .artifactCreated(second),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        viewModel.prompt = "生成周刊"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }
        viewModel.selectedArtifactID = second.id

        #expect(viewModel.selectedArtifact?.id == second.id)
        #expect(viewModel.selectedArtifact?.content == "run log")
    }

    @Test("通用 Inspector 按 Agent 类型生成正确导出文件名")
    func artifactExportFilenameUsesSelectedAgent() {
        let viewModel = AgentWorkspaceViewModel(agents: [
            BuiltInAgents.githubWeeklyReport,
            BuiltInAgents.repoInsight
        ])
        let markdown = AgentArtifact(type: .markdown, title: "Report", content: "# Report")
        let log = AgentArtifact(type: .log, title: "Log", content: "run log")

        #expect(viewModel.suggestedFilename(for: markdown) == "starcat-weekly-report.md")
        viewModel.selectedAgentID = BuiltInAgents.repoInsight.id
        #expect(viewModel.suggestedFilename(for: markdown) == "starcat-repo-insight.md")
        #expect(viewModel.suggestedFilename(for: log) == "starcat-agent-run.txt")
        viewModel.selectedAgentID = "future-agent"
        #expect(viewModel.suggestedFilename(for: markdown) == "starcat-agent-artifact.md")
    }

    @Test("cancel 会立即进入取消状态")
    func cancelMarksWorkspaceAsCancelled() {
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: NeverFinishingAgentRuntime()
        )
        viewModel.prompt = "生成本周 GitHub 热门项目周刊"

        viewModel.run()
        viewModel.cancel()

        #expect(viewModel.status == .cancelled)
        #expect(viewModel.isRunning == false)
    }

    @Test("approvalUpdated 会保存待审批事实")
    func approvalUpdatedStoresPendingApproval() async throws {
        let approval = AgentApprovalRequest(
            runID: UUID(),
            toolCallID: "call-tag",
            toolName: "tag_propose",
            input: .object(["tag": .string("database")]),
            permission: .requiresConfirmation,
            sequence: 1
        )
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: BuiltInAgents.githubWeeklyReport.title),
            .approvalUpdated(approval),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        viewModel.prompt = "规划标签"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.approvals == [approval])
    }

    @Test("reasoning 与正文增量会分别投影到流式缓冲")
    func projectsReasoningAndTextDeltasSeparately() async throws {
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: BuiltInAgents.githubWeeklyReport.title),
            .assistantReasoningDelta("先检查本地上下文"),
            .assistantDelta("正在生成周刊"),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        viewModel.prompt = "生成周刊"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.assistantReasoningOutput == "先检查本地上下文")
        #expect(viewModel.assistantOutput == "正在生成周刊")
    }

    @Test("assistant 消息落库后会清空临时流式缓冲")
    func persistedAssistantMessageClearsStreamingBuffers() async throws {
        let message = AgentMessage(
            runID: UUID(),
            role: .assistant,
            turn: 0,
            sequence: 1,
            parts: [.reasoning("已完成分析"), .text("最终正文")]
        )
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: "Run"),
            .assistantReasoningDelta("分析中"),
            .assistantDelta("生成中"),
            .messageAppended(message),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        viewModel.prompt = "生成周刊"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.assistantReasoningOutput.isEmpty)
        #expect(viewModel.assistantOutput.isEmpty)
        #expect(viewModel.messages == [message])
    }

    @Test("批准操作会向 Runtime 发送精确关联命令")
    func approveSendsCorrelatedRuntimeCommand() async throws {
        let approval = AgentApprovalRequest(
            runID: UUID(),
            toolCallID: "call-write",
            toolName: "write_tag",
            input: .object(["tag": .string("swift")]),
            permission: .requiresConfirmation,
            sequence: 1
        )
        let recorder = AgentCommandRecorder()
        let runtime = CommandRecordingAgentRuntime(
            events: [.runStarted(title: "Run"), .approvalUpdated(approval)],
            recorder: recorder
        )
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        viewModel.prompt = "写入标签"

        viewModel.run()
        try await waitUntil { viewModel.status == .waitingForConfirmation }
        viewModel.approve(approval)
        try await waitUntil { await recorder.commandCount() == 1 }
        let commands = await recorder.commands()
        let command = try #require(commands.first)

        guard case .decideApproval(let runID, let approvalID, let toolCallID, let decision) = command else {
            Issue.record("Expected decideApproval command")
            return
        }
        #expect(runID == approval.runID)
        #expect(approvalID == approval.id)
        #expect(toolCallID == approval.toolCallID)
        #expect(decision == .approved)
    }

    @Test("run 会先冻结 context 再交给 runtime")
    func runPassesContextProviderSnapshotIntoRuntime() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot: 1 repo",
            repos: [
                AgentRepoSnapshot(
                    id: 1,
                    owner: "groue",
                    name: "GRDB.swift",
                    fullName: "groue/GRDB.swift",
                    description: "SQLite toolkit",
                    language: "Swift",
                    starsCount: 7800,
                    topics: ["sqlite"],
                    isPrivate: false,
                    isStarred: true,
                    starredAt: "2026-07-07T00:00:00Z",
                    htmlUrl: "https://github.com/groue/GRDB.swift"
                )
            ]
        )
        let runtime = ContextEchoAgentRuntime()
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime,
            contextProvider: StaticAgentRunContextProvider(context: context)
        )
        viewModel.prompt = "生成本周 GitHub 热门项目周刊"
        viewModel.attachments = [AgentPromptAttachment(name: "brief.md", content: "重点关注本地 AI 工具")]

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.selectedArtifact?.content.contains("Unit Snapshot: 1 repo") == true)
        #expect(viewModel.selectedArtifact?.content.contains("groue/GRDB.swift") == true)
        #expect(viewModel.selectedArtifact?.content.contains("brief.md: 重点关注本地 AI 工具") == true)
        #expect(viewModel.attachments.isEmpty)
    }

    @Test("空 prompt 不会自动使用默认 Agent 指令运行")
    func emptyPromptDoesNotRunWithDefaultPrompt() {
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: NeverFinishingAgentRuntime()
        )

        viewModel.run()

        #expect(viewModel.status == .idle)
        #expect(viewModel.prompt.isEmpty)
        #expect(viewModel.isRunning == false)
    }

    @Test("reloadHistory 会加载真实 run 历史")
    func reloadHistoryLoadsPersistedRuns() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAgentRunRepository(database: database)
        _ = try await repository.createRun(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001001")!,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "历史 run",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: NeverFinishingAgentRuntime()
        )
        viewModel.configureRunRepository(repository)

        await viewModel.reloadHistory()

        #expect(viewModel.historyRuns.count == 1)
        #expect(viewModel.historyRuns.first?.userPrompt == "历史 run")
    }

    @Test("openHistoryRun 会只读恢复 run 快照")
    func openHistoryRunRestoresSnapshot() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAgentRunRepository(database: database)
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000001010")!
        let run = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "打开历史",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let call = AgentToolCall(
            id: "history-call",
            name: "history_tool",
            input: .object(["input": .string("input")]),
            sequence: 1
        )
        let assistant = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 0,
            sequence: 1,
            parts: [.toolCall(call)]
        )
        let result = AgentToolResultMessage(
            toolCallID: call.id,
            toolName: call.name,
            output: .object(["value": .string("output")]),
            isError: false,
            status: .completed,
            sequence: 2
        )
        let toolMessage = AgentMessage(
            runID: runID,
            role: .tool,
            turn: 0,
            sequence: 2,
            parts: [.toolResult(result)]
        )
        let final = AgentMessage(
            runID: runID,
            role: .assistant,
            turn: 1,
            sequence: 3,
            parts: [.text("# 历史")]
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("打开历史")]),
            runStatus: .running
        )
        try await repository.appendMessage(assistant, runStatus: .running)
        try await repository.appendMessage(toolMessage, runStatus: .running)
        try await repository.appendMessage(final, runStatus: .running)
        let artifact = AgentArtifact(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000001013")!,
            type: .markdown,
            title: "历史产物",
            content: "# 历史",
            toolCallID: call.id,
            messageID: toolMessage.id,
            sequence: toolMessage.sequence,
            createdAt: Date(timeIntervalSince1970: 1_788_000_120)
        )
        try await repository.appendArtifact(artifact, runID: runID)
        try await repository.updateRunStatus(
            runID: runID,
            status: .completed,
            model: "test-model",
            usage: .zero,
            errorMessage: nil,
            finishedAt: Date()
        )
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: NeverFinishingAgentRuntime()
        )
        viewModel.configureRunRepository(repository)

        await viewModel.openHistoryRun(run)

        #expect(viewModel.selectedHistoryRunID == run.id)
        #expect(viewModel.prompt == "打开历史")
        #expect(viewModel.status == .completed)
        #expect(viewModel.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(viewModel.selectedArtifact?.content == "# 历史")
        #expect(viewModel.assistantOutput.isEmpty)
    }

    @Test("重启后打开 pending approval 只恢复等待态且不会自动决策")
    func openPendingApprovalRestoresWaitingStateWithoutAutoDecision() async throws {
        let repository = GRDBAgentRunRepository(database: try InMemoryDatabaseManager())
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000001020")!
        let run = try await repository.createRun(
            id: runID,
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "等待审批",
            context: AgentRunContext(sourceDescription: "Unit"),
            createdAt: Date(timeIntervalSince1970: 1_788_000_000)
        )
        let call = AgentToolCall(
            id: "pending-call",
            name: "write_tag",
            input: .object(["tag": .string("swift")]),
            sequence: 1
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .user, turn: 0, sequence: 0, parts: [.text("等待审批")]),
            runStatus: .running
        )
        try await repository.appendMessage(
            AgentMessage(runID: runID, role: .assistant, turn: 0, sequence: 1, parts: [.toolCall(call)]),
            runStatus: .running
        )
        let approval = AgentApprovalRequest(
            runID: runID,
            toolCallID: call.id,
            toolName: call.name,
            input: call.input,
            permission: .requiresConfirmation,
            sequence: call.sequence
        )
        try await repository.saveApproval(approval, runStatus: .waitingForConfirmation)
        let recorder = RestartApprovalRecorder()
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: RestartApprovalRuntime(approval: approval, recorder: recorder)
        )
        viewModel.configureRunRepository(repository)

        await viewModel.openHistoryRun(run)
        try await waitUntil {
            let resumeCount = await recorder.resumeCount()
            return viewModel.status == .waitingForConfirmation && resumeCount == 1
        }

        #expect(viewModel.approvals == [approval])
        #expect(await recorder.commands().isEmpty)
        #expect(viewModel.messages.map(\.sequence) == [0, 1])
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !(await predicate()) {
            if start.duration(to: ContinuousClock.now) > .nanoseconds(Int64(timeoutNanoseconds)) {
                Issue.record("Timed out waiting for AgentWorkspaceViewModel state")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private struct EventReplayAgentRuntime: AgentRuntime {
    let events: [AgentRunEvent]

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private struct NeverFinishingAgentRuntime: AgentRuntime {
    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            continuation.yield(.runStarted(title: definition.title))
        }
    }
}

private struct CommandRecordingAgentRuntime: AgentRuntime {
    let events: [AgentRunEvent]
    let recorder: AgentCommandRecorder

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func send(_ command: AgentRunCommand) async {
        await recorder.record(command)
    }
}

private struct RestartApprovalRuntime: AgentRuntime {
    let approval: AgentApprovalRequest
    let recorder: RestartApprovalRecorder

    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { $0.finish() }
    }

    func resumePendingRun(
        snapshot: AgentRunSnapshotRecord,
        definition: AgentDefinition
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            Task {
                await recorder.recordResume()
                continuation.yield(.approvalUpdated(approval))
                continuation.finish()
            }
        }
    }

    func send(_ command: AgentRunCommand) async {
        await recorder.record(command)
    }
}

private actor RestartApprovalRecorder {
    private var resumes = 0
    private var recordedCommands: [AgentRunCommand] = []

    func recordResume() { resumes += 1 }
    func record(_ command: AgentRunCommand) { recordedCommands.append(command) }
    func resumeCount() -> Int { resumes }
    func commands() -> [AgentRunCommand] { recordedCommands }
}

private actor AgentCommandRecorder {
    private var recordedCommands: [AgentRunCommand] = []

    func record(_ command: AgentRunCommand) {
        recordedCommands.append(command)
    }

    func commandCount() -> Int { recordedCommands.count }
    func commands() -> [AgentRunCommand] { recordedCommands }
}

private struct StaticAgentRunContextProvider: AgentRunContextProviding {
    let context: AgentRunContext

    func makeContext(
        definition: AgentDefinition,
        prompt: String
    ) async -> AgentRunContext {
        context
    }
}

private struct ContextEchoAgentRuntime: AgentRuntime {
    func run(
        definition: AgentDefinition,
        prompt: String,
        context: AgentRunContext
    ) -> AsyncStream<AgentRunEvent> {
        AsyncStream { continuation in
            let repoNames = context.repos.map(\.fullName).joined(separator: ", ")
            let attachmentText = context.attachments.map { "\($0.name): \($0.content)" }.joined(separator: "\n")
            continuation.yield(.runStarted(title: definition.title))
            continuation.yield(.artifactCreated(AgentArtifact(
                type: .markdown,
                title: "Context Echo",
                content: "\(context.sourceDescription)\n\(repoNames)\n\(attachmentText)"
            )))
            continuation.yield(.runCompleted)
            continuation.finish()
        }
    }
}
