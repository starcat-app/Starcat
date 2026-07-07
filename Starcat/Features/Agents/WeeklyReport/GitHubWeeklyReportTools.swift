//
//  GitHubWeeklyReportTools.swift
//  Starcat
//
//  GitHub Weekly Report Agent 的首批只读工具。
//
//  这些工具暂时是本地 Swift 实现，而不是 OpenAI function calling。这样可以先把
//  Starcat 真实数据、可审计输入输出和 artifact schema 跑通；后续接入模型 tool-calling
//  时，工具的输入/输出契约可以继续复用。
//

import Foundation

struct WeeklyReportTopic: Hashable, Sendable {
    var title: String
    var reason: String
    var repos: [AgentRepoSnapshot]
}

struct WeeklyReportToolResult: Sendable {
    var output: AgentToolOutput
    var trace: AgentTraceSpan
}

enum GitHubWeeklyReportTools {

    static func parseGoal(prompt: String, context: AgentRunContext) -> WeeklyReportToolResult {
        let effectivePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGoal = effectivePrompt.isEmpty ? "生成 GitHub 技术周刊 Markdown" : effectivePrompt
        return makeResult(
            toolName: "agent.parseGoal",
            summary: "Markdown Weekly Report",
            input: """
            prompt:
            \(normalizedGoal)

            context_source:
            \(context.sourceDescription)
            """,
            output: """
            goal: GitHub Weekly Report
            artifact: markdown
            write_policy: read-only
            repo_count: \(context.repos.count)
            """,
            log: "Parsed user goal without write-capable actions."
        )
    }

    static func resolveCandidateRepos(context: AgentRunContext, limit: Int = 12) -> WeeklyReportToolResult {
        let sorted = context.repos
            .sorted { lhs, rhs in
                if lhs.starsCount == rhs.starsCount {
                    return lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
                }
                return lhs.starsCount > rhs.starsCount
            }
            .prefix(limit)
        let repos = Array(sorted)
        let output = repos.isEmpty
            ? "repos: []"
            : repos.map { "- \($0.displaySummary)" }.joined(separator: "\n")
        return makeResult(
            toolName: "context.resolveRepos",
            summary: "\(repos.count) repos",
            input: """
            source:
            \(context.sourceDescription)

            limit:
            \(limit)
            """,
            output: output,
            log: "Resolved top candidates from frozen AgentRunContext."
        )
    }

    static func clusterTopics(context: AgentRunContext, maxTopics: Int = 4) -> ([WeeklyReportTopic], WeeklyReportToolResult) {
        let groupedByLanguage = Dictionary(grouping: context.repos) { repo in
            nonEmpty(repo.language) ?? "Other"
        }
        let unsortedTopics: [WeeklyReportTopic] = groupedByLanguage.map { language, repos in
            let sortedRepos = repos.sorted { $0.starsCount > $1.starsCount }
            return WeeklyReportTopic(
                title: language == "Other" ? "跨语言工具与基础设施" : "\(language) 生态项目",
                reason: "按主要语言聚合,用于形成周刊主题段落。",
                repos: Array(sortedRepos.prefix(5))
            )
        }
        let sortedTopics = unsortedTopics.sorted { lhs, rhs in
            let lhsStars = lhs.repos.reduce(0) { $0 + $1.starsCount }
            let rhsStars = rhs.repos.reduce(0) { $0 + $1.starsCount }
            return lhsStars > rhsStars
        }
        let topicList = Array(sortedTopics.prefix(maxTopics))
        let output = topicList.isEmpty
            ? "topics: []"
            : topicList.map { topic in
                let names = topic.repos.map { $0.fullName }.joined(separator: ", ")
                return "- \(topic.title): \(names)"
            }.joined(separator: "\n")
        return (
            topicList,
            makeResult(
                toolName: "report.clusterTopics",
                summary: "\(topicList.count) topics",
                input: "repo_count: \(context.repos.count)\nstrategy: language-first clustering",
                output: output,
                log: "Clustered frozen repo snapshots into weekly report topics."
            )
        )
    }

    static func buildMarkdown(
        prompt: String,
        context: AgentRunContext,
        topics: [WeeklyReportTopic]
    ) -> (String, WeeklyReportToolResult) {
        let markdown: String
        if topics.isEmpty {
            markdown = """
            # GitHub Weekly Report

            > 用户目标：\(prompt)
            > 数据来源：\(context.sourceDescription)

            当前 Starcat 本地没有可用于生成周刊的仓库快照。请先完成 GitHub Stars 同步，或把仓库加入知识库后再运行 Agent。
            """
        } else {
            let sections = topics.enumerated().map { index, topic in
                """
                ## \(index + 1). \(topic.title)

                \(topic.reason)

                \(topic.repos.map(Self.repoBullet).joined(separator: "\n"))
                """
            }.joined(separator: "\n\n")
            markdown = """
            # GitHub Weekly Report

            > 用户目标：\(prompt)
            > 数据来源：\(context.sourceDescription)
            > 生成时间：\(context.generatedAt.formatted())

            本期周刊基于 Starcat 本地仓库快照生成。Agent 只读取本地数据并生成 Markdown，不会写入标签、笔记、状态或修改 Star。

            \(sections)

            ## 可继续追问

            - 基于其中某个主题继续做替代品对比。
            - 把某个项目展开成采用建议。
            - 要求 Agent 重新按 README / License / 活跃度维度排序。
            """
        }

        let result = makeResult(
            toolName: "artifact.buildMarkdown",
            summary: "\(markdown.count) chars",
            input: "topics: \(topics.count)\nrepo_count: \(context.repos.count)",
            output: String(markdown.prefix(1_200)),
            log: "Built Markdown artifact from read-only tool outputs."
        )
        return (markdown, result)
    }

    private static func makeResult(
        toolName: String,
        summary: String,
        input: String,
        output: String,
        log: String
    ) -> WeeklyReportToolResult {
        let toolOutput = AgentToolOutput(
            toolName: toolName,
            summary: summary,
            detail: output,
            input: input,
            output: output,
            log: log
        )
        return WeeklyReportToolResult(
            output: toolOutput,
            trace: AgentTraceSpan(
                kind: "Tool",
                title: toolName,
                summary: summary,
                input: input,
                output: output,
                log: log,
                relatedToolOutputID: toolOutput.id
            )
        )
    }

    private static func repoBullet(_ repo: AgentRepoSnapshot) -> String {
        let description = nonEmpty(repo.description) ?? "暂无描述"
        let topics = repo.topics.prefix(4).joined(separator: ", ")
        let topicsSuffix = topics.isEmpty ? "" : " 主题：\(topics)。"
        return "- **\(repo.fullName)** (\(repo.starsCount) stars): \(description)\(topicsSuffix)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum GitHubWeeklyReportAgentTools {
    static let all: [any AgentTool] = [
        ParseGoalTool(),
        ResolveReposTool(),
        ClusterTopicsTool(),
        BuildMarkdownTool()
    ]

    struct ParseGoalTool: AgentTool {
        let id = "agent.parseGoal"
        let displayName = "Parse Goal"
        let permission: AgentToolPermission = .readOnly

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            GitHubWeeklyReportTools.parseGoal(prompt: input.prompt, context: input.context).agentToolResult()
        }
    }

    struct ResolveReposTool: AgentTool {
        let id = "context.resolveRepos"
        let displayName = "Resolve Repositories"
        let permission: AgentToolPermission = .readOnly

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            GitHubWeeklyReportTools.resolveCandidateRepos(context: input.context).agentToolResult()
        }
    }

    struct ClusterTopicsTool: AgentTool {
        let id = "report.clusterTopics"
        let displayName = "Cluster Topics"
        let permission: AgentToolPermission = .readOnly

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            let (topics, result) = GitHubWeeklyReportTools.clusterTopics(context: input.context)
            return result.agentToolResult(payload: .topics(topics))
        }
    }

    struct BuildMarkdownTool: AgentTool {
        let id = "artifact.buildMarkdown"
        let displayName = "Build Markdown Artifact"
        let permission: AgentToolPermission = .readOnly

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            let topics: [WeeklyReportTopic]
            if case .topics(let payloadTopics) = input.payload {
                topics = payloadTopics
            } else {
                topics = []
            }
            let (markdown, result) = GitHubWeeklyReportTools.buildMarkdown(
                prompt: input.prompt,
                context: input.context,
                topics: topics
            )
            return result.agentToolResult(payload: .markdown(markdown))
        }
    }
}

private extension WeeklyReportToolResult {
    func agentToolResult(payload: AgentToolPayload = .none) -> AgentToolResult {
        AgentToolResult(
            status: trace.status == .failed ? .failed : .completed,
            output: output,
            trace: trace,
            payload: payload
        )
    }
}
