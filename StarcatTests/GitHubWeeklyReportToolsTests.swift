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

    @Test("resolveCandidateRepos 使用真实 context 快照并按 stars 排序")
    func resolveCandidateReposUsesContextSnapshot() {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [
                repo(fullName: "swiftlang/swift-markdown", language: "Swift", stars: 3_100),
                repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800),
                repo(fullName: "modelcontextprotocol/swift-sdk", language: "Swift", stars: 1_400)
            ]
        )

        let result = GitHubWeeklyReportTools.resolveCandidateRepos(context: context, limit: 2)

        #expect(result.output.summary == "2 repos")
        #expect(result.output.output.contains("groue/GRDB.swift"))
        #expect(result.output.output.contains("swiftlang/swift-markdown"))
        #expect(result.output.output.contains("modelcontextprotocol/swift-sdk") == false)
        #expect(result.trace.input.contains("Unit Snapshot"))
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

    @Test("buildMarkdown 从 topic 生成只读 artifact 草稿")
    func buildMarkdownUsesTopicRepos() {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
        )
        let topics = [
            WeeklyReportTopic(
                title: "Swift 生态项目",
                reason: "按主要语言聚合。",
                repos: context.repos
            )
        ]

        let (markdown, result) = GitHubWeeklyReportTools.buildMarkdown(
            prompt: "生成 Swift 周刊",
            context: context,
            topics: topics
        )

        #expect(markdown.contains("groue/GRDB.swift"))
        #expect(markdown.contains("本地仓库快照"))
        #expect(result.output.toolName == "artifact.build_weekly_report")
        #expect(result.trace.output.contains("# GitHub Weekly Report"))
    }

    @Test("buildMarkdown 把外部搜索摘要写入草稿")
    func buildMarkdownIncludesExternalContext() {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
        )
        let topics = [
            WeeklyReportTopic(
                title: "Swift 生态项目",
                reason: "按主要语言聚合。",
                repos: context.repos
            )
        ]

        let (markdown, result) = GitHubWeeklyReportTools.buildMarkdown(
            prompt: "生成 Swift 周刊",
            context: context,
            topics: topics,
            externalContextMarkdown: "<external_context>GRDB release notes</external_context>"
        )

        #expect(markdown.contains("外部来源摘要"))
        #expect(markdown.contains("GRDB release notes"))
        #expect(result.output.input.contains("external_context_chars"))
    }

    @Test("Weekly tools 可以通过 AgentToolRegistry 执行")
    func weeklyToolsExecuteThroughRegistry() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800)]
        )
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let clusterTool = try registry.tool(named: "repo.cluster_topics")
        let markdownTool = try registry.tool(named: "artifact.build_weekly_report")

        let clusterResult = await clusterTool.execute(AgentToolInput(
            prompt: "生成 Swift 周刊",
            context: context
        ))
        let markdownResult = await markdownTool.execute(AgentToolInput(
            prompt: "生成 Swift 周刊",
            context: context,
            values: ["externalContextMarkdown": "<external_context>GRDB docs</external_context>"],
            payload: clusterResult.payload
        ))

        #expect(clusterResult.output.toolName == "repo.cluster_topics")
        #expect(markdownResult.output.toolName == "artifact.build_weekly_report")
        if case .markdown(let markdown) = markdownResult.payload {
            #expect(markdown.contains("groue/GRDB.swift"))
            #expect(markdown.contains("GRDB docs"))
        } else {
            Issue.record("Expected markdown payload")
        }
    }

    @Test("Repo Insight tools 选择提示词命中的仓库并生成分析草稿")
    func repoInsightToolsSelectMentionedRepoAndBuildMarkdown() async throws {
        let context = AgentRunContext(
            sourceDescription: "Unit Snapshot",
            repos: [
                repo(fullName: "groue/GRDB.swift", language: "Swift", stars: 7_800),
                repo(fullName: "swiftlang/swift-markdown", language: "Swift", stars: 3_100)
            ]
        )
        let registry = try AgentToolRegistry(tools: GitHubWeeklyReportAgentTools.all)
        let selectTool = try registry.tool(named: "context.select_repo")
        let markdownTool = try registry.tool(named: "artifact.build_repo_insight")

        let selectResult = await selectTool.execute(AgentToolInput(
            prompt: "帮我分析 swift-markdown 的定位和风险",
            context: context
        ))
        let markdownResult = await markdownTool.execute(AgentToolInput(
            prompt: "帮我分析 swift-markdown 的定位和风险",
            context: context,
            values: ["externalContextMarkdown": "<external_context>parser docs</external_context>"],
            payload: selectResult.payload
        ))

        #expect(selectResult.output.output.contains("swiftlang/swift-markdown"))
        #expect(markdownResult.output.toolName == "artifact.build_repo_insight")
        if case .markdown(let markdown) = markdownResult.payload {
            #expect(markdown.contains("# Repo Insight: swiftlang/swift-markdown"))
            #expect(markdown.contains("parser docs"))
        } else {
            Issue.record("Expected Repo Insight markdown payload")
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
}
