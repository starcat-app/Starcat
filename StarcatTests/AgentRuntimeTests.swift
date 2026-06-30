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
        var completedStepCount = 0
        var markdownArtifact: AgentArtifact?
        var didComplete = false

        for await event in stream {
            switch event {
            case .runStarted(let title):
                didStart = title == BuiltInAgents.githubWeeklyReport.title
            case .stepUpdated(let step):
                if step.status == .completed {
                    completedStepCount += 1
                }
            case .artifactCreated(let artifact):
                markdownArtifact = artifact
            case .runCompleted:
                didComplete = true
            case .stepStarted, .assistantDelta, .runFailed, .runCancelled:
                break
            }
        }

        #expect(didStart)
        #expect(completedStepCount == 5)
        #expect(markdownArtifact?.type == .markdown)
        #expect(markdownArtifact?.content.contains("# 本周 GitHub 热门项目观察") == true)
        #expect(markdownArtifact?.content.contains("Unit Test") == true)
        #expect(didComplete)
    }
}
