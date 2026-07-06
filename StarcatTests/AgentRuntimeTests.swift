//
//  AgentRuntimeTests.swift
//  StarcatTests
//
//  Agent 底座 runtime 的事件流测试。
//
//  这组测试锁住 Agent Runtime 的最小契约：一次 run 必须能启动、推进只读工具、
//  调用文本生成器、生成 Artifact 并正常完成。后续接入模型 tool-calling 时，
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
            stepCompletionDelayNanoseconds: 0,
            textGenerator: StaticAgentTextGenerator(markdown: "# GitHub Weekly Report\n\nUnit Test AI Output")
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
        var traceCount = 0
        var assistantOutput = ""
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
                #expect(output.input.isEmpty == false)
                #expect(output.output.isEmpty == false)
            case .trace(let span):
                traceCount += 1
                #expect(span.input.isEmpty == false)
                #expect(span.output.isEmpty == false)
            case .assistantDelta(let text):
                assistantOutput += text
            case .artifactCreated(let artifact):
                switch artifact.type {
                case .markdown:
                    markdownArtifact = artifact
                case .log:
                    logArtifact = artifact
                }
            case .runCompleted:
                didComplete = true
            case .stepStarted, .runFailed, .runCancelled:
                break
            }
        }

        #expect(didStart)
        #expect(planStepCount == 3)
        #expect(completedStepCount == 4)
        #expect(toolOutputCount == 4)
        #expect(traceCount == 6)
        #expect(assistantOutput.contains("Unit Test AI Output"))
        #expect(markdownArtifact?.type == .markdown)
        #expect(markdownArtifact?.content.contains("# GitHub Weekly Report") == true)
        #expect(markdownArtifact?.content.contains("Unit Test") == true)
        #expect(logArtifact?.type == .log)
        #expect(logArtifact?.content.contains("DefaultAgentRuntime read-only tools") == true)
        #expect(logArtifact?.content.contains("Tool output: artifact.buildMarkdown") == true)
        #expect(didComplete)
    }

    @Test("缺少 AI 配置时 runtime 失败且不生成假 artifact")
    func missingAIDoesNotGenerateFallbackArtifact() async {
        let runtime = DefaultAgentRuntime(
            stepStartDelayNanoseconds: 0,
            stepCompletionDelayNanoseconds: 0
        )

        let stream = runtime.run(
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成周刊",
            context: AgentRunContext(sourceDescription: "Unit Test")
        )

        var failedMessage: String?
        var artifactCount = 0
        for await event in stream {
            switch event {
            case .runFailed(let message):
                failedMessage = message
            case .artifactCreated:
                artifactCount += 1
            default:
                break
            }
        }

        #expect(failedMessage?.contains("AI Provider") == true)
        #expect(artifactCount == 0)
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

private struct StaticAgentTextGenerator: AgentTextGenerating {
    let markdown: String

    func generateWeeklyReport(
        prompt: String,
        context: AgentRunContext,
        draftMarkdown: String
    ) async throws -> String {
        markdown
    }
}
