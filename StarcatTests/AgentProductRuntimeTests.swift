//
//  AgentProductRuntimeTests.swift
//  StarcatTests
//
//  内置 Agent 的产品级 Runtime 测试。
//
//  单工具测试只能证明各组件可用；这里使用真实 AgentDefinition、真实工具集合和真实
//  artifact builder 跑完整模型循环，锁住 External Search 降级与最终产物的交付语义。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Agent Product Runtime")
struct AgentProductRuntimeTests {
    @Test("Weekly 时间窗无采集项目时允许生成可审计的空周报")
    func weeklyBuildsValidEmptyReport() throws {
        let request = try WeeklyReportArtifactRequest(arguments: .object([
            "title": .string("Weekly"),
            "executiveSummary": .string("本周暂无可用项目。"),
            "sections": .array([]),
            "limitations": .array([]),
            "includeSources": .bool(true)
        ]))

        let markdown = try WeeklyReportArtifactBuilder.build(
            request: request,
            prompt: "生成本周周报",
            context: AgentRunContext(
                sourceDescription: String(
                    format: String.l10n("agent.context.source.weeklyHotspotsFormat"),
                    7,
                    0
                )
            ),
            externalContextMarkdown: ""
        )

        #expect(markdown.contains(String.l10n("agent.artifact.weekly.emptyReport")))
        #expect(markdown.contains(String.l10n("agent.artifact.common.localSnapshot")))
    }

    @Test("Weekly 在 External Search 关闭时基于本地事实生成底部产物")
    func weeklyCompletesWithLocalFactsWhenSearchIsDisabled() async throws {
        let outcome = try await runWeekly(searchStatus: .skipped)
        let artifact = try #require(outcome.events.compactMap { event -> AgentArtifact? in
            guard case .artifactCreated(let artifact) = event else { return nil }
            return artifact
        }.first)
        let searchResult = try #require(toolResult(named: "external_search", in: outcome.requests[1]))
        let artifactIndex = try #require(outcome.events.firstIndex(where: {
            if case .artifactCreated = $0 { return true }
            return false
        }))
        let completedIndex = try #require(outcome.events.firstIndex(where: {
            if case .runCompleted = $0 { return true }
            return false
        }))

        #expect(searchResult.status == .skipped)
        #expect(artifact.content.contains("groue/GRDB.swift"))
        #expect(artifact.content.contains(String.l10n("agent.artifact.common.externalUnavailable")))
        #expect(artifactIndex < completedIndex)
        #expect(outcome.requests.count == 2)
    }

    @Test("Weekly 在 External Search 失败时不伪造来源并继续本地收敛")
    func weeklyCompletesWithoutFakeSourcesWhenSearchFails() async throws {
        let outcome = try await runWeekly(searchStatus: .failed)
        let artifact = try #require(outcome.events.compactMap { event -> AgentArtifact? in
            guard case .artifactCreated(let artifact) = event else { return nil }
            return artifact
        }.first)
        let searchResult = try #require(toolResult(named: "external_search", in: outcome.requests[1]))

        #expect(searchResult.status == .failed)
        #expect(searchResult.isError)
        #expect(artifact.content.contains("groue/GRDB.swift"))
        #expect(artifact.content.contains(String.l10n("agent.artifact.common.externalUnavailable")))
        #expect(!artifact.content.contains("https://search.invalid"))
    }

    @Test("Repo Insight 通过同一 Loop Runtime 选仓并提交真实产物")
    func repoInsightSelectsRepositoryAndBuildsArtifactThroughLoop() async throws {
        let context = AgentRunContext(sourceDescription: "Unit Snapshot", repos: [repoSnapshot()])
        let recorder = ProductModelRecorder(responses: [
            AgentModelResponse(
                text: "",
                reasoning: "先选择冻结快照中的目标仓库",
                toolCalls: [AgentModelToolCall(
                    id: "select-repo",
                    name: "context_select_repo",
                    arguments: try AgentJSONValue.object([
                        "fullName": .string("groue/GRDB.swift")
                    ]).jsonString()
                )],
                model: "test",
                finishReason: "tool_calls"
            ),
            AgentModelResponse(
                text: "",
                reasoning: "提交结构化分析",
                toolCalls: [AgentModelToolCall(
                    id: "build-insight",
                    name: "artifact_build_repo_insight",
                    arguments: try repoInsightArguments(repoID: 42).jsonString()
                )],
                model: "test",
                finishReason: "tool_calls"
            )
        ])
        let runtime = LoopAgentRuntime(
            modelClient: ProductModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.makeAll(
                externalSearchTool: ProductSearchTool(status: .skipped)
            ))
        )

        let events = await collect(runtime.run(
            definition: BuiltInAgents.repoInsight,
            prompt: "分析 GRDB.swift 的定位和风险",
            context: context
        ))
        let requests = await recorder.recordedRequests()
        let artifact = try #require(events.compactMap { event -> AgentArtifact? in
            guard case .artifactCreated(let artifact) = event else { return nil }
            return artifact
        }.first)
        let selectedRepo = try #require(toolResult(named: "context_select_repo", in: requests[1]))

        #expect(selectedRepo.output.jsonDescription.contains("groue/GRDB.swift"))
        #expect(artifact.content.contains("# GRDB.swift Adoption Insight"))
        #expect(artifact.content.contains("groue/GRDB.swift"))
        #expect(requests.count == 2)
        #expect(events.contains(where: { if case .runCompleted = $0 { return true }; return false }))
    }

    @Test("Repo Alternatives 通过 External Search 证据生成可审计对比产物")
    func repoAlternativesBuildsEvidenceBoundArtifactThroughLoop() async throws {
        let context = AgentRunContext(sourceDescription: "Unit Snapshot", repos: [repoSnapshot()])
        let candidateURL = "https://github.com/stephencelis/SQLite.swift"
        let recorder = ProductModelRecorder(responses: [
            AgentModelResponse(
                text: "",
                reasoning: "先确认冻结快照中的源仓库",
                toolCalls: [AgentModelToolCall(
                    id: "select-source",
                    name: "context_select_repo",
                    arguments: try AgentJSONValue.object([
                        "fullName": .string("groue/GRDB.swift")
                    ]).jsonString()
                )],
                model: "test",
                finishReason: "tool_calls"
            ),
            AgentModelResponse(
                text: "",
                reasoning: "搜索公开 GitHub 候选",
                toolCalls: [AgentModelToolCall(
                    id: "search-alternatives",
                    name: "external_search",
                    arguments: "{\"query\":\"GRDB.swift alternatives\",\"allowedDomains\":[\"github.com\"]}"
                )],
                model: "test",
                finishReason: "tool_calls"
            ),
            AgentModelResponse(
                text: "",
                reasoning: "候选已由公开搜索证据确认，提交对比产物",
                toolCalls: [AgentModelToolCall(
                    id: "build-alternatives",
                    name: "artifact_build_repo_alternatives",
                    arguments: try repoAlternativesArguments(
                        sourceRepoID: 42,
                        candidateURL: candidateURL
                    ).jsonString()
                )],
                model: "test",
                finishReason: "tool_calls"
            )
        ])
        let searchTool = ProductAlternativesSearchTool(candidateURL: candidateURL)
        let runtime = LoopAgentRuntime(
            modelClient: ProductModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.makeAll(
                externalSearchTool: searchTool
            ))
        )

        let events = await collect(runtime.run(
            definition: BuiltInAgents.repoAlternatives,
            prompt: "寻找 GRDB.swift 的替代方案",
            context: context
        ))
        let requests = await recorder.recordedRequests()
        let artifact = try #require(events.compactMap { event -> AgentArtifact? in
            guard case .artifactCreated(let artifact) = event else { return nil }
            return artifact
        }.first)
        let searchResult = try #require(toolResult(named: "external_search", in: requests[2]))

        #expect(searchResult.output.jsonDescription.contains(candidateURL))
        #expect(artifact.content.contains("# GRDB.swift Alternatives"))
        #expect(artifact.content.contains(candidateURL))
        #expect(requests.count == 3)
        #expect(events.contains(where: { if case .runCompleted = $0 { return true }; return false }))
    }

    private func runWeekly(searchStatus: AgentToolStatus) async throws -> ProductRunOutcome {
        let context = AgentRunContext(sourceDescription: "Unit Snapshot", repos: [repoSnapshot()])
        let recorder = ProductModelRecorder(responses: [
            AgentModelResponse(
                text: "",
                reasoning: "先尝试补充外部证据",
                toolCalls: [AgentModelToolCall(
                    id: "search-1",
                    name: "external_search",
                    arguments: "{\"query\":\"GRDB Swift release\"}"
                )],
                model: "test",
                finishReason: "tool_calls"
            ),
            AgentModelResponse(
                text: "",
                reasoning: "搜索不可用，改用冻结本地事实提交周刊",
                toolCalls: [AgentModelToolCall(
                    id: "build-weekly",
                    name: "artifact_build_weekly_report",
                    arguments: try weeklyArguments(repoID: 42).jsonString()
                )],
                model: "test",
                finishReason: "tool_calls"
            )
        ])
        let runtime = LoopAgentRuntime(
            modelClient: ProductModelClient(recorder: recorder),
            toolRegistry: try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.makeAll(
                externalSearchTool: ProductSearchTool(status: searchStatus)
            ))
        )

        let events = await collect(runtime.run(
            definition: BuiltInAgents.githubWeeklyReport,
            prompt: "生成本周 Swift 周刊",
            context: context
        ))
        return ProductRunOutcome(events: events, requests: await recorder.recordedRequests())
    }

    private func weeklyArguments(repoID: Int64) -> AgentJSONValue {
        .object([
            "title": .string("Swift Weekly"),
            "executiveSummary": .string("本周基于 Starcat 冻结快照整理 Swift 数据层项目。"),
            "sections": .array([.object([
                "heading": .string("数据持久化"),
                "analysis": .string("GRDB.swift 是本地快照中的高关注 Swift 数据库工具。"),
                "repoIDs": .array([.number(Double(repoID))])
            ])]),
            "limitations": .array([.string("External Search 当前不可用。")]),
            "includeSources": .bool(true)
        ])
    }

    private func repoInsightArguments(repoID: Int64) -> AgentJSONValue {
        .object([
            "repoID": .number(Double(repoID)),
            "title": .string("GRDB.swift Adoption Insight"),
            "summary": .string("GRDB.swift 为 Swift 应用提供 SQLite 工具链。"),
            "positioning": .string("适合作为本地优先桌面应用的数据层。"),
            "adoptionFit": .string("与 Starcat 的 macOS 和 SQLite 技术栈匹配。"),
            "risks": .array([.string("需要结合目标 schema 做迁移测试。")]),
            "recommendedActions": .array([.string("先用隔离数据库验证查询与迁移。")]),
            "limitations": .array([.string("未使用实时 README 和维护活跃度证据。")]),
            "includeSources": .bool(true)
        ])
    }

    private func repoAlternativesArguments(
        sourceRepoID: Int64,
        candidateURL: String
    ) -> AgentJSONValue {
        .object([
            "sourceRepoID": .number(Double(sourceRepoID)),
            "title": .string("GRDB.swift Alternatives"),
            "summary": .string("SQLite.swift 是公开搜索证据中的候选方案。"),
            "candidates": .array([.object([
                "fullName": .string("stephencelis/SQLite.swift"),
                "url": .string(candidateURL),
                "positioning": .string("Swift SQLite 类型安全封装。"),
                "adoptionFit": .string("适合希望使用轻量查询 API 的项目。"),
                "risks": .array([.string("需要核验迁移能力和并发模型。")])
            ])]),
            "recommendedActions": .array([.string("在同一 schema 上做迁移验证。")]),
            "limitations": .array([.string("实时指标仅以当前公开搜索证据为准。")]),
            "includeSources": .bool(true)
        ])
    }

    private func repoSnapshot() -> AgentRepoSnapshot {
        AgentRepoSnapshot(
            id: 42,
            owner: "groue",
            name: "GRDB.swift",
            fullName: "groue/GRDB.swift",
            description: "A toolkit for SQLite databases, with a focus on application development.",
            language: "Swift",
            starsCount: 8_000,
            topics: ["sqlite", "database"],
            isPrivate: false,
            isStarred: true,
            starredAt: "2026-07-07T00:00:00Z",
            htmlUrl: "https://github.com/groue/GRDB.swift"
        )
    }

    private func toolResult(named name: String, in request: AgentModelRequest) -> AgentToolResultMessage? {
        request.prompt.messages.lazy.flatMap(\.parts).compactMap { part in
            guard case .toolResult(let result) = part, result.toolName == name else { return nil }
            return result
        }.first
    }

    private func collect(_ stream: AsyncStream<AgentRunEvent>) async -> [AgentRunEvent] {
        var events: [AgentRunEvent] = []
        for await event in stream { events.append(event) }
        return events
    }
}

private struct ProductRunOutcome {
    var events: [AgentRunEvent]
    var requests: [AgentModelRequest]
}

private actor ProductModelRecorder {
    private var responses: [AgentModelResponse]
    private var requests: [AgentModelRequest] = []

    init(responses: [AgentModelResponse]) {
        self.responses = responses
    }

    func next(for request: AgentModelRequest) throws -> AgentModelResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw LoopAgentRuntimeError.emptyModelResponse }
        return responses.removeFirst()
    }

    func recordedRequests() -> [AgentModelRequest] { requests }
}

private struct ProductModelClient: AgentLoopModelClient {
    let recorder: ProductModelRecorder

    func stream(request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(.completed(try await recorder.next(for: request)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

private struct ProductSearchTool: AgentTool {
    let status: AgentToolStatus
    let definition = AgentToolDefinition(
        name: "external_search",
        description: "Search external sources when enabled.",
        inputSchema: AgentJSONSchema(
            type: .object,
            properties: ["query": AgentJSONSchema(type: .string)],
            required: ["query"]
        )
    )

    func execute(_ input: AgentToolInput) async -> AgentToolResult {
        let summary = status == .skipped ? "External Search disabled" : "External Search failed"
        let output = AgentToolOutput(
            toolName: definition.name,
            summary: summary,
            detail: summary,
            input: (try? input.arguments.jsonString()) ?? "{}",
            output: summary,
            log: summary
        )
        return AgentToolResult(
            status: status,
            output: output,
            trace: AgentTraceSpan(
                kind: "Tool",
                title: definition.name,
                summary: summary,
                input: output.input,
                output: summary,
                log: summary,
                status: status == .failed ? .failed : .skipped
            )
        )
    }
}

private struct ProductAlternativesSearchTool: AgentTool {
    let candidateURL: String
    let definition = AgentToolDefinition(
        name: "external_search",
        description: "Search public GitHub repositories.",
        inputSchema: AgentJSONSchema(
            type: .object,
            properties: [
                "query": AgentJSONSchema(type: .string),
                "allowedDomains": AgentJSONSchema(
                    type: .array,
                    items: AgentJSONSchema(type: .string)
                )
            ],
            required: ["query"]
        )
    )

    func execute(_ input: AgentToolInput) async -> AgentToolResult {
        let markdown = """
        <external_context source="Test Search">
        - [stephencelis/SQLite.swift](\(candidateURL)) — Swift SQLite wrapper
        </external_context>
        """
        let output = AgentToolOutput(
            toolName: definition.name,
            summary: "1 source",
            detail: markdown,
            input: (try? input.arguments.jsonString()) ?? "{}",
            output: candidateURL,
            log: "completed"
        )
        return AgentToolResult(
            output: output,
            trace: AgentTraceSpan(
                kind: "Tool",
                title: definition.name,
                summary: output.summary,
                input: output.input,
                output: output.output,
                log: output.log
            ),
            payload: .externalContextMarkdown(markdown),
            sources: [AgentToolResultSource(
                title: "stephencelis/SQLite.swift",
                url: candidateURL,
                provider: "Test Search"
            )]
        )
    }
}

private extension AgentJSONValue {
    var jsonDescription: String { (try? jsonString()) ?? "" }
}
