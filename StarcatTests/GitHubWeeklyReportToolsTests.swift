//
//  GitHubWeeklyReportToolsTests.swift
//  StarcatTests
//
//  GitHub Weekly Report Agent 只读工具测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHubWeeklyReportTools")
struct GitHubWeeklyReportToolsTests {

    @Test("resolveCandidateRepos 默认保留 Weekly 最近观察顺序")
    func resolveCandidateReposUsesContextSnapshot() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [
                repo(fullName: "swiftlang/swift-markdown", language: "Swift", stars: 3_100),
                repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800),
                repo(fullName: "modelcontextprotocol/swift-sdk", language: "Swift", stars: 1_400)
            ]
        )

        let result = try await GitHubWeeklyReportTools.resolveCandidateRepos(context: context, limit: 2)

        #expect(result.output.summary == "2 repos")
        #expect(result.output.output.contains("groue/GRDB.swift"))
        #expect(result.output.output.contains("swiftlang/swift-markdown"))
        #expect(result.output.output.contains("modelcontextprotocol/swift-sdk") == false)
        #expect(result.trace.input.contains("Unit Snapshot"))
        #expect(result.trace.input.contains("sort:\nrecent"))
    }

    @Test("context_resolve_repos 遇到冻结范围外 ID 时整次失败")
    func resolveReposToolFailsClosedForUnknownRepository() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
        )
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let tool = try registry.tool(named: "context_resolve_repos")

        let result = await tool.execute(AgentToolInput(
            arguments: .object([
                "repoIDs": .array([.number(Double(context.repos[0].id)), .number(999_999)])
            ]),
            prompt: "resolve",
            context: context
        ))

        #expect(result.status == .failed)
        #expect(result.output.log == "Unknown Agent repository IDs: 999999")
        #expect(result.output.output.contains("groue/GRDB.swift") == false)
    }

    @Test("context_resolve_repos 消费模型数量和排序参数")
    func resolveReposToolUsesModelArguments() async throws {
        let swiftMarkdown = repo(fullName: "swiftlang/swift-markdown", language: "Swift", stars: 3_100)
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [
                swiftMarkdown,
                repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800),
                repo(fullName: "modelcontextprotocol/swift-sdk", language: "Swift", stars: 1_400)
            ]
        )
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let tool = try registry.tool(named: "context_resolve_repos")

        let result = await tool.execute(AgentToolInput(
            arguments: .object([
                "repoIDs": .array([.number(Double(swiftMarkdown.id))]),
                "maxRepositories": .number(1),
                "sort": .string("name")
            ]),
            prompt: "ignored for sorting",
            context: context
        ))

        #expect(result.output.summary == "1 repos")
        #expect(result.output.output.contains("swiftlang/swift-markdown"))
        #expect(result.output.output.contains("groue/GRDB.swift") == false)
        #expect(result.output.input.contains("sort:\nname"))
    }

    @Test("clusterTopics 按语言生成主题并保留 repo 名称")
    func clusterTopicsGroupsByLanguage() {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [
                repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800),
                repo(fullName: "vercel/next.js", language: "TypeScript", stars: 130_000)
            ]
        )

        let (topics, result) = GitHubWeeklyReportTools.clusterTopics(context: context)

        #expect(topics.count == 2)
        #expect(topics.map(\.title).contains("Swift 生态项目"))
        #expect(result.output.output.contains("vercel/next.js"))
        #expect(result.trace.output.contains("groue/GRDB.swift"))
    }

    @Test("repo_cluster_topics 只聚类模型选择的真实 repo IDs")
    func clusterTopicsToolUsesSelectedRepoIDs() async throws {
        let swift = repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)
        let web = repo(fullName: "vercel/next.js", language: "TypeScript", stars: 130_000)
        let context = AgentRunContext(sourceDescription: "Unit Snapshot", repos: [swift, web])
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let tool = try registry.tool(named: "repo_cluster_topics")

        let result = await tool.execute(AgentToolInput(
            arguments: .object([
                "repoIDs": .array([.number(Double(swift.id))]),
                "maxTopics": .number(1)
            ]),
            prompt: "cluster",
            context: context
        ))

        #expect(result.output.output.contains("groue/GRDB.swift"))
        #expect(result.output.output.contains("vercel/next.js") == false)
    }

    @Test("artifact_build_weekly_report 用模型结构化内容和真实 repo 引用生成 artifact")
    func buildMarkdownUsesStructuredModelContent() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
        )
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let tool = try registry.tool(named: "artifact_build_weekly_report")

        let result = await tool.execute(AgentToolInput(
            arguments: weeklyArtifactArguments(repoIDs: context.repos.map(\.id)),
            prompt: "生成 Swift 周刊",
            context: context
        ))

        #expect(result.status == .completed)
        #expect(result.output.toolName == "artifact_build_weekly_report")
        #expect(result.trace.output.contains("# Swift Agent Weekly"))
        #expect(result.trace.output.contains("本周重点是 Swift 数据层"))
        #expect(result.trace.output.contains("groue/GRDB.swift"))
        #expect(result.sources.first?.url.contains("github.com/groue/GRDB.swift") == true)
    }

    @Test("buildMarkdown 把外部搜索摘要写入草稿")
    func buildMarkdownIncludesExternalContext() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
        )
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let tool = try registry.tool(named: "artifact_build_weekly_report")

        let result = await tool.execute(AgentToolInput(
            arguments: weeklyArtifactArguments(repoIDs: context.repos.map(\.id)),
            prompt: "生成 Swift 周刊",
            context: context,
            values: ["externalContextMarkdown": "<external_context source=\"Exa\">\n- [GRDB release](https://example.com/release)\n</external_context>"]
        ))

        guard case .markdown(let markdown) = result.payload else {
            Issue.record("Expected weekly report markdown")
            return
        }
        #expect(markdown.contains("### \(String.l10n("agent.artifact.common.externalSearch"))"))
        #expect(markdown.contains("https://example.com/release"))
        #expect(markdown.contains("<external_context") == false)
    }

    @Test("artifact_build_weekly_report 拒绝引用 run 之外的 repo ID")
    func weeklyArtifactRejectsUnknownRepository() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
        )
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let tool = try registry.tool(named: "artifact_build_weekly_report")

        let result = await tool.execute(AgentToolInput(
            arguments: weeklyArtifactArguments(repoIDs: [999_999]),
            prompt: "生成周刊",
            context: context
        ))

        #expect(result.status == .failed)
        #expect(result.output.log == String(
            format: String.l10n("agent.artifact.weekly.error.unknownRepositoriesFormat"),
            "999999"
        ))
    }

    @Test("Weekly tools 可以通过 AgentToolRegistry 执行")
    func weeklyToolsExecuteThroughRegistry() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
        )
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let clusterTool = try registry.tool(named: "repo_cluster_topics")
        let markdownTool = try registry.tool(named: "artifact_build_weekly_report")

        let clusterResult = await clusterTool.execute(AgentToolInput(
            prompt: "生成 Swift 周刊",
            context: context
        ))
        let markdownResult = await markdownTool.execute(AgentToolInput(
            arguments: weeklyArtifactArguments(repoIDs: context.repos.map(\.id)),
            prompt: "生成 Swift 周刊",
            context: context,
            values: ["externalContextMarkdown": externalContext("GRDB docs")],
            payload: clusterResult.payload
        ))

        #expect(clusterResult.output.toolName == "repo_cluster_topics")
        #expect(markdownResult.output.toolName == "artifact_build_weekly_report")
        if case .markdown(let markdown) = markdownResult.payload {
            #expect(markdown.contains("groue/GRDB.swift"))
            #expect(markdown.contains("GRDB docs"))
        } else {
            Issue.record("Expected markdown payload")
        }
    }

    @Test("Repo Insight tools 选择提示词命中的仓库并生成分析草稿")
    func repoInsightToolsSelectMentionedRepoAndBuildMarkdown() async throws {
        let target = repo(fullName: "swiftlang/swift-markdown", language: "Swift", stars: 3_100)
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [
                repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800),
                target
            ]
        )
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let selectTool = try registry.tool(named: "context_select_repo")
        let markdownTool = try registry.tool(named: "artifact_build_repo_insight")

        let selectResult = await selectTool.execute(AgentToolInput(
            arguments: .object(["fullName": .string("swiftlang/swift-markdown")]),
            prompt: "提示词故意提到 GRDB,参数应优先",
            context: context
        ))
        let markdownResult = await markdownTool.execute(AgentToolInput(
            arguments: repoInsightArtifactArguments(repoID: target.id),
            prompt: "帮我分析 swift-markdown 的定位和风险",
            context: context,
            values: ["externalContextMarkdown": externalContext("parser docs")],
            payload: selectResult.payload
        ))

        #expect(selectResult.output.output.contains("swiftlang/swift-markdown"))
        #expect(markdownResult.output.toolName == "artifact_build_repo_insight")
        if case .markdown(let markdown) = markdownResult.payload {
            #expect(markdown.contains("# Swift Markdown Adoption Insight"))
            #expect(markdown.contains("适合作为 Markdown 语法树基础设施"))
            #expect(markdown.contains("[R1]"))
            #expect(markdown.contains("parser docs"))
        } else {
            Issue.record("Expected Repo Insight markdown payload")
        }
    }

    @Test("artifact_build_repo_insight 拒绝 run 外仓库")
    func repoInsightRejectsUnknownRepository() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
        )
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let tool = try registry.tool(named: "artifact_build_repo_insight")

        let result = await tool.execute(AgentToolInput(
            arguments: repoInsightArtifactArguments(repoID: 999_999),
            prompt: "分析仓库",
            context: context
        ))

        #expect(result.status == .failed)
        #expect(result.output.log == String(
            format: String.l10n("agent.artifact.repoInsight.error.unknownRepositoryFormat"),
            Int64(999_999)
        ))
    }

    @Test("Repo Alternatives 只接受 External Search 已返回的 GitHub 候选")
    func repoAlternativesBuildsComparisonFromExternalEvidence() async throws {
        let source = repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)
        let context = AgentRunContext(sourceDescription: "Unit Snapshot", repos: [source])
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let tool = try registry.tool(named: "artifact_build_repo_alternatives")
        let candidateURL = "https://github.com/stephencelis/SQLite.swift"

        let result = await tool.execute(AgentToolInput(
            arguments: repoAlternativesArtifactArguments(
                candidateFullName: "stephencelis/SQLite.swift",
                candidateURL: candidateURL
            ),
            prompt: "对比 GRDB.swift 的替代方案",
            context: context,
            values: [
                "externalContextMarkdown": externalContext("- [SQLite.swift](\(candidateURL)) — typed SQLite wrapper")
            ]
        ))

        #expect(result.status == .completed)
        #expect(result.sources.map(\.url).contains(candidateURL))
        if case .markdown(let markdown) = result.payload {
            #expect(markdown.contains("# GRDB.swift Alternatives"))
            #expect(markdown.contains("[stephencelis/SQLite.swift](\(candidateURL))"))
            #expect(markdown.contains(String.l10n("agent.definition.repoAlternatives.title")))
            #expect(markdown.contains("<external_context") == false)
        } else {
            Issue.record("Expected Repo Alternatives markdown payload")
        }
    }

    @Test("Repo Alternatives 拒绝没有 External Search 证据的候选")
    func repoAlternativesRejectsUnevidencedCandidate() async throws {
        let source = repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)
        let context = AgentRunContext(sourceDescription: "Unit Snapshot", repos: [source])
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let tool = try registry.tool(named: "artifact_build_repo_alternatives")

        let result = await tool.execute(AgentToolInput(
            arguments: repoAlternativesArtifactArguments(
                candidateFullName: "invented/fake-db",
                candidateURL: "https://github.com/invented/fake-db"
            ),
            prompt: "对比替代方案",
            context: context,
            values: ["externalContextMarkdown": externalContext("No matching repository")]
        ))

        #expect(result.status == .failed)
        #expect(result.output.log.contains("invented/fake-db"))
    }

    @Test("Repo Alternatives 搜索不可用时允许提交空候选和限制")
    func repoAlternativesAllowsEmptyCandidatesWithoutSearch() throws {
        let source = repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)
        let request = try RepoAlternativesArtifactRequest(arguments: .object([
            "title": .string("GRDB.swift Alternatives"),
            "summary": .string("当前没有可核验的公开候选。"),
            "candidates": .array([]),
            "recommendedActions": .array([.string("启用 External Search 后重试。")]),
            "limitations": .array([.string("External Search 当前不可用。")])
        ]))

        let markdown = try RepoAlternativesArtifactBuilder.build(
            request: request,
            prompt: "对比替代方案",
            context: AgentRunContext(sourceDescription: "Unit Snapshot", repos: [source]),
            externalContextMarkdown: ""
        )

        #expect(markdown.contains(String.l10n("agent.artifact.common.externalUnavailable")))
        #expect(markdown.contains("External Search 当前不可用。"))
    }

    @Test("Repo Alternatives 的源仓库身份只取自单仓冻结 Context")
    func repoAlternativesRequiresExactlyOneFrozenSourceRepository() throws {
        let request = try RepoAlternativesArtifactRequest(arguments: .object([
            "title": .string("Alternatives"),
            "summary": .string("Summary"),
            "candidates": .array([]),
            "recommendedActions": .array([]),
            "limitations": .array([])
        ]))

        #expect(throws: RepoAlternativesArtifactError.invalidArguments(
            "frozen context must contain exactly one source repository"
        )) {
            _ = try RepoAlternativesArtifactBuilder.build(
                request: request,
                prompt: "对比替代方案",
                context: AgentRunContext(
                    sourceDescription: "Unit Snapshot",
                    repos: [
                        repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800),
                        repo(fullName: "stephencelis/SQLite.swift", language: "Swift", stars: 9_000)
                    ]
                ),
                externalContextMarkdown: ""
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
            id: Int64(fullName.utf8.reduce(0) { ($0 * 31 + Int($1)) % 1_000_000_000 }),
            owner: parts.first ?? "owner",
            name: parts.dropFirst().first ?? "repo",
            fullName: fullName,
            description: "\(fullName) description",
            language: language,
            starsCount: stars,
            topics: ["agent", "database"],
            isPrivate: false,
            isStarred: true,
            starredAt: "2026-07-07T00:00:00Z",
            htmlUrl: "https://github.com/\(fullName)"
        )
    }

    private func externalContext(_ content: String) -> String {
        """
        <external_context>
        \(content)
        </external_context>
        """
    }

    private func weeklyArtifactArguments(repoIDs: [Int64]) -> AgentJSONValue {
        .object([
            "title": .string("Swift Agent Weekly"),
            "executiveSummary": .string("本周重点是 Swift 数据层与 Agent 工具链。"),
            "sections": .array([
                .object([
                    "heading": .string("Swift 基础设施"),
                    "analysis": .string("这些仓库覆盖数据持久化与工具调用基础设施。"),
                    "repoIDs": .array(repoIDs.map { .number(Double($0)) })
                ])
            ]),
            "limitations": .array([.string("未读取本周实时 GitHub 活跃度。")]),
            "includeSources": .bool(true)
        ])
    }

    private func repoInsightArtifactArguments(repoID: Int64) -> AgentJSONValue {
        .object([
            "repoID": .number(Double(repoID)),
            "title": .string("Swift Markdown Adoption Insight"),
            "summary": .string("该仓库提供 Swift 原生 Markdown 解析能力。"),
            "positioning": .string("适合作为 Markdown 语法树基础设施。"),
            "adoptionFit": .string("适合需要原生 Swift 解析链路的桌面应用。"),
            "risks": .array([.string("需要继续核验 API 稳定性。")]),
            "recommendedActions": .array([.string("用真实 README 样本做兼容性测试。")]),
            "limitations": .array([.string("没有实时维护活跃度数据。")]),
            "includeSources": .bool(true)
        ])
    }

    private func repoAlternativesArtifactArguments(
        candidateFullName: String,
        candidateURL: String
    ) -> AgentJSONValue {
        .object([
            "title": .string("GRDB.swift Alternatives"),
            "summary": .string("基于公开证据比较 SQLite 访问层方案。"),
            "candidates": .array([.object([
                "fullName": .string(candidateFullName),
                "url": .string(candidateURL),
                "positioning": .string("轻量 Swift SQLite 封装。"),
                "adoptionFit": .string("适合偏好类型安全查询 API 的项目。"),
                "risks": .array([.string("仍需核验迁移与并发模型。")])
            ])]),
            "recommendedActions": .array([.string("使用同一 schema 做基准验证。")]),
            "limitations": .array([.string("实时维护状态以公开搜索结果为准。")]),
            "includeSources": .bool(true)
        ])
    }
}
