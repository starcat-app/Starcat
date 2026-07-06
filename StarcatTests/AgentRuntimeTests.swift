//
//  AgentRuntimeTests.swift
//  StarcatTests
//
//  Agent 底座 runtime 的事件流测试。
//
//  这组测试先锁住 P0 deterministic runtime 的最小契约：一次 run 必须能启动、
//  推进步骤、生成 Artifact 并正常完成。后续接入真实 tool-calling runtime 时，
//  Workspace 仍可以依赖同一组事件语义。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AgentRuntime")
struct AgentRuntimeTests {

    @Test("默认 Weekly Report Agent 能产出完整事件流和 Markdown artifact")
    func weeklyReportRuntimeEmitsStepsArtifactAndCompletion() async {
        let runtime = DefaultAgentRuntime(
            stepStartDelayNanoseconds: 0,
            stepCompletionDelayNanoseconds: 0
        )

        let stream = runtime.run(
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成本周 GitHub 热门项目周刊",
            context: AgentRunContext(sourceDescription: "Unit Test")
        )

        var didStart = false
        var planStepCount = 0
        var completedStepCount = 0
        var toolOutputCount = 0
        var markdownArtifact: AgentArtifact?
        var logArtifact: AgentArtifact?
        var didComplete = false

        for await event in stream {
            switch event {
            case .runStarted(let title):
                didStart = title == BuiltInAgents.githubWeeklyReport.title
            case .planCreated(let plan):
                planStepCount = plan.count
            case .stepUpdated(let step):
                if step.status == .completed {
                    completedStepCount += 1
                }
            case .toolOutput(let output):
                toolOutputCount += 1
                #expect(output.toolName.isEmpty == false)
            case .artifactCreated(let artifact):
                switch artifact.type {
                case .markdown:
                    markdownArtifact = artifact
                case .log:
                    logArtifact = artifact
                }
            case .runCompleted:
                didComplete = true
            case .stepStarted, .trace, .assistantDelta, .runFailed, .runCancelled:
                break
            }
        }

        #expect(didStart)
        #expect(planStepCount == 3)
        #expect(completedStepCount == 5)
        #expect(toolOutputCount == 5)
        #expect(markdownArtifact?.type == .markdown)
        #expect(markdownArtifact?.content.contains("# 本周 GitHub 热门项目观察") == true)
        #expect(markdownArtifact?.content.contains("Unit Test") == true)
        #expect(logArtifact?.type == .log)
        #expect(logArtifact?.content.contains("DefaultAgentRuntime deterministic mode") == true)
        #expect(logArtifact?.content.contains("Tool output: report.generate") == true)
        #expect(didComplete)
    }

    @Test("取消 runtime stream 会终止后续步骤")
    func cancellingRuntimeStreamStopsTheRun() async {
        let runtime = DefaultAgentRuntime(
            stepStartDelayNanoseconds: 1_000_000_000,
            stepCompletionDelayNanoseconds: 1_000_000_000
        )

        let stream = runtime.run(
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成周刊",
            context: .empty
        )

        let task = Task {
            var receivedEvents = 0
            for await _ in stream {
                receivedEvents += 1
            }
            return receivedEvents
        }

        task.cancel()
        let receivedEvents = await task.value
        #expect(receivedEvents <= 2)
    }
}
