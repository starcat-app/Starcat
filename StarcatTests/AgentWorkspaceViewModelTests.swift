//
//  AgentWorkspaceViewModelTests.swift
//  StarcatTests
//
//  Agent Workspace ViewModel 的事件消费测试。
//
//  这些测试不验证 SwiftUI 布局,只锁住 ViewModel 对 AgentRunEvent 的状态投影。
//  这样后续 runtime 从本地只读工具切换到模型 tool-calling 时,工作台仍能依赖
//  同一组 plan / step / tool output / artifact 状态。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("AgentWorkspaceViewModel")
struct AgentWorkspaceViewModelTests {

    @Test("run 会把 runtime 事件投影成工作台状态")
    func runProjectsRuntimeEventsIntoWorkspaceState() async throws {
        let step = AgentRunStep(title: "生成周刊", detail: "生成 Markdown", status: .completed)
        let artifact = AgentArtifact(type: .markdown, title: "周刊", content: "# 周刊")
        let logArtifact = AgentArtifact(type: .log, title: "日志", content: "# Log")
        let traceSpan = AgentTraceSpan(
            kind: "Tool",
            title: "report.generate",
            summary: "ok",
            input: #"{"prompt":"生成周刊"}"#,
            output: #"{"artifact":"markdown"}"#,
            log: "latency=1ms"
        )
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: BuiltInAgents.githubWeeklyReport.title),
            .planCreated([AgentPlanStep(title: "计划", detail: "确认输出")]),
            .stepUpdated(step),
            .toolOutput(AgentToolOutput(toolName: "report.generate", summary: "ok", detail: "done")),
            .trace(traceSpan),
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
        #expect(viewModel.planSteps.count == 1)
        #expect(viewModel.steps == [step])
        #expect(viewModel.toolOutputs.count == 1)
        #expect(viewModel.traceSpans == [traceSpan])
        #expect(viewModel.artifacts.count == 2)
        #expect(viewModel.selectedArtifact?.content == "# 周刊")
        #expect(viewModel.errorMessage == nil)
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

    @Test("confirmationRequested 会保存待确认动作")
    func confirmationRequestedStoresPendingAction() async throws {
        let action = AgentConfirmationAction(
            title: "建议创建 tag: database",
            detail: "确认后才写入 repo tag。",
            toolName: "tag.propose",
            input: #"{"tag":"database"}"#
        )
        let runtime = EventReplayAgentRuntime(events: [
            .runStarted(title: BuiltInAgents.githubWeeklyReport.title),
            .confirmationRequested(action),
            .runCompleted
        ])
        let viewModel = AgentWorkspaceViewModel(
            agents: [BuiltInAgents.githubWeeklyReport],
            runtime: runtime
        )
        viewModel.prompt = "规划标签"

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.pendingConfirmations == [action])
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

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.selectedArtifact?.content.contains("Unit Snapshot: 1 repo") == true)
        #expect(viewModel.selectedArtifact?.content.contains("groue/GRDB.swift") == true)
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
        #expect(viewModel.steps.map(\.title) == ["history_tool"])
        #expect(viewModel.toolOutputs.map(\.toolName) == ["history_tool"])
        #expect(viewModel.traceSpans.map(\.title) == ["history_tool"])
        #expect(viewModel.selectedArtifact?.content == "# 历史")
        #expect(viewModel.assistantOutput == "# 历史")
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !predicate() {
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
            continuation.yield(.runStarted(title: definition.title))
            continuation.yield(.artifactCreated(AgentArtifact(
                type: .markdown,
                title: "Context Echo",
                content: "\(context.sourceDescription)\n\(repoNames)"
            )))
            continuation.yield(.runCompleted)
            continuation.finish()
        }
    }
}
