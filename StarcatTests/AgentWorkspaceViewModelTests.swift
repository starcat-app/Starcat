//
//  AgentWorkspaceViewModelTests.swift
//  StarcatTests
//
//  Agent Workspace ViewModel 的事件消费测试。
//
//  这些测试不验证 SwiftUI 布局,只锁住 ViewModel 对 AgentRunEvent 的状态投影。
//  这样后续 runtime 从 deterministic 实现切换到真实 tool-calling 时,工作台仍能依赖
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

        viewModel.run()
        viewModel.cancel()

        #expect(viewModel.status == .cancelled)
        #expect(viewModel.isRunning == false)
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

        viewModel.run()
        try await waitUntil { viewModel.status == .completed }

        #expect(viewModel.selectedArtifact?.content.contains("Unit Snapshot: 1 repo") == true)
        #expect(viewModel.selectedArtifact?.content.contains("groue/GRDB.swift") == true)
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
