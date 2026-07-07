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
        var skippedStepCount = 0
        var toolOutputCount = 0
        var traceCount = 0
        var traceTitles: [String] = []
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
                } else if step.status == .skipped {
                    skippedStepCount += 1
                }
            case .toolOutput(let output):
                toolOutputCount += 1
                #expect(output.toolName.isEmpty == false)
                #expect(output.input.isEmpty == false)
                #expect(output.output.isEmpty == false)
            case .trace(let span):
                traceCount += 1
                traceTitles.append(span.title)
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
        #expect(skippedStepCount == 1)
        #expect(toolOutputCount == 5)
        #expect(traceCount == 7)
        #expect(traceTitles.suffix(2) == ["AI 生成周刊正文", "本周 GitHub 热门项目周刊"])
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

    @Test("Runtime 缺少声明工具时显式失败")
    func missingDeclaredToolFailsRun() async {
        let runtime = DefaultAgentRuntime(
            stepStartDelayNanoseconds: 0,
            stepCompletionDelayNanoseconds: 0,
            textGenerator: StaticAgentTextGenerator(markdown: "# Should Not Run")
        )
        let definition = AgentDefinition(
            id: "unit-missing-tool",
            title: "Missing Tool Agent",
            subtitle: "Unit",
            systemImage: "wrench",
            capabilityLabels: [],
            defaultPrompt: "",
            isEnabled: true,
            toolIDs: ["agent.missing"]
        )

        let stream = runtime.run(
            definition: definition,
            prompt: "run",
            context: .empty
        )

        var failedMessage: String?
        var didComplete = false
        for await event in stream {
            switch event {
            case .runFailed(let message):
                failedMessage = message
            case .runCompleted:
                didComplete = true
            default:
                break
            }
        }

        #expect(failedMessage?.contains("agent.missing") == true)
        #expect(didComplete == false)
    }

    @Test("Weekly Runtime 在聚类前执行 external.search 并把外部上下文传给 LLM")
    func weeklyRuntimeExecutesExternalSearchBeforeClustering() async throws {
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.makeAll(
            externalSearchTool: StubExternalSearchTool()
        ))
        let runtime = DefaultAgentRuntime(
            stepStartDelayNanoseconds: 0,
            stepCompletionDelayNanoseconds: 0,
            textGenerator: EchoDraftAgentTextGenerator(),
            toolRegistry: registry
        )

        let stream = runtime.run(
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成 Swift 周刊",
            context: AgentRunContext(
                sourceDescription: "Unit Test",
                repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
            )
        )

        var toolNames: [String] = []
        var markdownArtifact: AgentArtifact?
        for await event in stream {
            switch event {
            case .toolOutput(let output):
                toolNames.append(output.toolName)
            case .artifactCreated(let artifact) where artifact.type == .markdown:
                markdownArtifact = artifact
            default:
                break
            }
        }

        #expect(toolNames == [
            "agent.parseGoal",
            "context.resolveRepos",
            "external.search",
            "report.clusterTopics",
            "artifact.buildMarkdown"
        ])
        #expect(markdownArtifact?.content.contains("External Search Unit Context") == true)
    }

    @Test("external.search 失败时 Weekly Runtime 记录失败 trace 并继续本地生成")
    func weeklyRuntimeContinuesWhenExternalSearchFails() async throws {
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.makeAll(
            externalSearchTool: FailedExternalSearchTool()
        ))
        let runtime = DefaultAgentRuntime(
            stepStartDelayNanoseconds: 0,
            stepCompletionDelayNanoseconds: 0,
            textGenerator: EchoDraftAgentTextGenerator(),
            toolRegistry: registry
        )

        let stream = runtime.run(
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成 Swift 周刊",
            context: AgentRunContext(
                sourceDescription: "Unit Test",
                repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
            )
        )

        var failedTrace: AgentTraceSpan?
        var failedMessage: String?
        var markdownArtifact: AgentArtifact?
        var didComplete = false
        for await event in stream {
            switch event {
            case .trace(let span) where span.title == "external.search" && span.status == .failed:
                failedTrace = span
            case .runFailed(let message):
                failedMessage = message
            case .artifactCreated(let artifact) where artifact.type == .markdown:
                markdownArtifact = artifact
            case .runCompleted:
                didComplete = true
            default:
                break
            }
        }

        #expect(failedTrace?.output.contains("provider timeout") == true)
        #expect(failedMessage == nil)
        #expect(markdownArtifact?.content.contains("groue/GRDB.swift") == true)
        #expect(didComplete)
    }

    @Test("Runtime 注入 repository 时持久化 run 快照")
    func runtimePersistsRunSnapshotWhenRepositoryProvided() async throws {
        let database = try InMemoryDatabaseManager()
        let repository = GRDBAgentRunRepository(database: database)
        let runtime = DefaultAgentRuntime(
            stepStartDelayNanoseconds: 0,
            stepCompletionDelayNanoseconds: 0,
            textGenerator: EchoDraftAgentTextGenerator(),
            runRepository: repository
        )

        let stream = runtime.run(
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成 Swift 周刊",
            context: AgentRunContext(
                sourceDescription: "Unit Test",
                repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
            )
        )

        for await _ in stream {}

        let recent = try await repository.recentRuns(limit: 1)
        let runID = try #require(UUID(uuidString: recent.first?.id ?? ""))
        let snapshot = try await repository.snapshot(runID: runID)

        #expect(snapshot?.run.status == AgentRunStatus.completed.rawValue)
        #expect(snapshot?.run.userPrompt == "生成 Swift 周刊")
        #expect(snapshot?.steps.isEmpty == false)
        #expect(snapshot?.traces.map(\.title).contains("external.search") == true)
        #expect(snapshot?.traces.last?.kind == "Artifact")
        #expect(snapshot?.artifacts.map(\.type) == [
            AgentArtifactType.markdown.rawValue,
            AgentArtifactType.log.rawValue
        ])
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

private struct EchoDraftAgentTextGenerator: AgentTextGenerating {
    func generateWeeklyReport(
        prompt: String,
        context: AgentRunContext,
        draftMarkdown: String
    ) async throws -> String {
        draftMarkdown
    }
}

private struct StubExternalSearchTool: AgentTool {
    let id = "external.search"
    let displayName = "External Search"
    let permission: AgentToolPermission = .readOnly

    func execute(_ input: AgentToolInput) async -> AgentToolResult {
        let output = AgentToolOutput(
            toolName: id,
            summary: "1 sources",
            detail: "External Search Unit Context",
            input: "query: GRDB",
            output: "https://example.com/grdb",
            log: "provider=stub\ncache=hit"
        )
        return AgentToolResult(
            output: output,
            trace: AgentTraceSpan(
                kind: "Tool",
                title: id,
                summary: output.summary,
                input: output.input,
                output: output.output,
                log: output.log,
                relatedToolOutputID: output.id
            ),
            payload: .externalContextMarkdown("External Search Unit Context")
        )
    }
}

private struct FailedExternalSearchTool: AgentTool {
    let id = "external.search"
    let displayName = "External Search"
    let permission: AgentToolPermission = .readOnly

    func execute(_ input: AgentToolInput) async -> AgentToolResult {
        let output = AgentToolOutput(
            toolName: id,
            summary: "failed",
            detail: "provider timeout",
            input: "query: GRDB",
            output: "provider timeout",
            log: "provider=stub\nstatus=failed"
        )
        return AgentToolResult(
            status: .failed,
            output: output,
            trace: AgentTraceSpan(
                kind: "Tool",
                title: id,
                summary: output.summary,
                input: output.input,
                output: output.output,
                log: output.log,
                status: .failed,
                relatedToolOutputID: output.id
            )
        )
    }
}

private func repo(
    fullName: String,
    language: String,
    stars: Int
) -> AgentRepoSnapshot {
    let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
    return AgentRepoSnapshot(
        id: Int64(abs(fullName.hashValue)),
        owner: parts.first ?? "owner",
        name: parts.dropFirst().first ?? "repo",
        fullName: fullName,
        description: "\(fullName) description",
        language: language,
        starsCount: stars,
        topics: ["agent", "database"],
        isStarred: true,
        starredAt: "2026-07-07T00:00:00Z",
        htmlUrl: "https://github.com/\(fullName)"
    )
}
