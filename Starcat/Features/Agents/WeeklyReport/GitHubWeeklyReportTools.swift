//
//  GitHubWeeklyReportTools.swift
//  Starcat
//
//  GitHub Weekly Report Agent 的首批只读工具。
//
//  模型只负责选择工具和提交分析内容；仓库筛选、排序、引用解析与 artifact 校验均由
//  本地 Swift 工具执行，确保输出只能引用冻结在本次 run 中的真实 Starcat 数据。
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

enum WeeklyReportRepoSort: String, Sendable {
    case starredAt = "starred_at"
    case stars
    case name
}

enum GitHubWeeklyReportTools {

    static func parseGoal(prompt: String, context: AgentRunContext) -> WeeklyReportToolResult {
        let effectivePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGoal = effectivePrompt.isEmpty ? "生成 GitHub 技术周刊 Markdown" : effectivePrompt
        return makeResult(
            toolName: "agent_parse_goal",
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

    static func resolveCandidateRepos(
        context: AgentRunContext,
        repoIDs: [Int64] = [],
        limit: Int = 12,
        sort: WeeklyReportRepoSort = .stars
    ) -> WeeklyReportToolResult {
        let allowedIDs = Set(repoIDs)
        let scopedRepos = repoIDs.isEmpty ? context.repos : context.repos.filter { allowedIDs.contains($0.id) }
        let sorted = scopedRepos
            .sorted { orderedBefore($0, $1, sort: sort) }
            .prefix(limit)
        let repos = Array(sorted)
        let output = repos.isEmpty
            ? "repos: []"
            : repos.map { "- id=\($0.id) | \($0.displaySummary)" }.joined(separator: "\n")
        return makeResult(
            toolName: "context_resolve_repos",
            summary: "\(repos.count) repos",
            input: """
            source:
            \(context.sourceDescription)

            requested_repo_ids:
            \(repoIDs)

            limit:
            \(limit)

            sort:
            \(sort.rawValue)
            """,
            output: output,
            log: "Resolved top candidates from frozen AgentRunContext."
        )
    }

    static func clusterTopics(
        context: AgentRunContext,
        repoIDs: [Int64] = [],
        maxTopics: Int = 4
    ) -> ([WeeklyReportTopic], WeeklyReportToolResult) {
        let allowedIDs = Set(repoIDs)
        let repos = repoIDs.isEmpty ? context.repos : context.repos.filter { allowedIDs.contains($0.id) }
        let groupedByLanguage = Dictionary(grouping: repos) { repo in
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
                toolName: "repo_cluster_topics",
                summary: "\(topicList.count) topics",
                input: "repo_count: \(repos.count)\nrepo_ids: \(repos.map(\.id))\nmax_topics: \(maxTopics)\nstrategy: language-first clustering",
                output: output,
                log: "Clustered frozen repo snapshots into weekly report topics."
            )
        )
    }

    private static func orderedBefore(
        _ lhs: AgentRepoSnapshot,
        _ rhs: AgentRepoSnapshot,
        sort: WeeklyReportRepoSort
    ) -> Bool {
        switch sort {
        case .starredAt:
            let lhsDate = lhs.starredAt ?? ""
            let rhsDate = rhs.starredAt ?? ""
            if lhsDate != rhsDate { return lhsDate > rhsDate }
        case .stars:
            if lhs.starsCount != rhs.starsCount { return lhs.starsCount > rhs.starsCount }
        case .name:
            break
        }
        return lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
    }

    static func buildMarkdown(
        prompt: String,
        context: AgentRunContext,
        topics: [WeeklyReportTopic],
        externalContextMarkdown: String = ""
    ) -> (String, WeeklyReportToolResult) {
        let externalSection = externalContextSection(externalContextMarkdown)
        let markdown: String
        if topics.isEmpty {
            markdown = """
            # GitHub Weekly Report

            > 用户目标：\(prompt)
            > 数据来源：\(context.sourceDescription)
            \(externalSection.headerLine)

            当前 Starcat 本地没有可用于生成周刊的仓库快照。请先完成 GitHub Stars 同步，或把仓库加入知识库后再运行 Agent。
            \(externalSection.body)
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
            \(externalSection.headerLine)

            本期周刊基于 Starcat 本地仓库快照生成,并在 External Search 开启时补充网络来源。Agent 只读取上下文并生成 Markdown,不会写入标签、笔记、状态或修改 Star。
            \(externalSection.body)

            \(sections)

            ## 可继续追问

            - 基于其中某个主题继续做替代品对比。
            - 把某个项目展开成采用建议。
            - 要求 Agent 重新按 README / License / 活跃度维度排序。
            """
        }

        let result = makeResult(
            toolName: "artifact_build_weekly_report",
            summary: "\(markdown.count) chars",
            input: "topics: \(topics.count)\nrepo_count: \(context.repos.count)\nexternal_context_chars: \(externalContextMarkdown.count)",
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

    private static func externalContextSection(_ markdown: String) -> (headerLine: String, body: String) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("> 外部来源：未启用或无结果", "")
        }
        let capped = String(trimmed.prefix(2_400))
        return (
            "> 外部来源：External Search",
            """

            ## 外部来源摘要

            \(capped)
            """
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func makeReadOnlyToolDefinition(
    name: String,
    description: String,
    properties: [String: AgentJSONSchema] = [:],
    required: [String] = [],
    completesRun: Bool = false
) -> AgentToolDefinition {
    AgentToolDefinition(
        name: name,
        description: description,
        inputSchema: AgentJSONSchema(
            type: .object,
            properties: properties,
            required: required
        ),
        permission: .readOnly,
        completesRun: completesRun,
        timeoutMilliseconds: 20_000
    )
}

private func failedAgentToolResult(toolName: String, input: String, message: String) -> AgentToolResult {
    let output = AgentToolOutput(
        toolName: toolName,
        summary: "failed",
        detail: message,
        input: input,
        output: "error: \(message)",
        log: message
    )
    return AgentToolResult(
        status: .failed,
        output: output,
        trace: AgentTraceSpan(
            kind: "Tool",
            title: toolName,
            summary: output.summary,
            input: input,
            output: output.output,
            log: message,
            status: .failed,
            relatedToolOutputID: output.id
        )
    )
}

private extension AgentJSONValue {
    var integerArrayValue: [Int] {
        guard case .array(let values) = self else { return [] }
        return values.compactMap(\.integerValue)
    }
}

enum GitHubWeeklyReportAgentTools {
    static var all: [any AgentTool] {
        makeAll(externalSearchTool: ExternalSearchAgentTool(collector: DisabledAgentExternalSearchCollector()))
    }

    static func makeAll(externalSearchTool: any AgentTool) -> [any AgentTool] {
        [
            ParseGoalTool(),
            ResolveReposTool(),
            externalSearchTool,
            ClusterTopicsTool(),
            BuildMarkdownTool(),
            RepoInsightAgentTools.ParseGoalTool(),
            RepoInsightAgentTools.SelectRepoTool(),
            RepoInsightAgentTools.BuildMarkdownTool()
        ]
    }

    struct ParseGoalTool: AgentTool {
        let definition = makeReadOnlyToolDefinition(
            name: "agent_parse_goal",
            description: "Normalize the user's weekly report goal and record the read-only execution scope.",
            properties: ["goal": AgentJSONSchema(type: .string, description: "User's report goal")],
            required: ["goal"]
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            let goal = input.arguments.objectValue?["goal"]?.stringValue ?? input.prompt
            return GitHubWeeklyReportTools.parseGoal(prompt: goal, context: input.context).agentToolResult()
        }
    }

    struct ResolveReposTool: AgentTool {
        let definition = makeReadOnlyToolDefinition(
            name: "context_resolve_repos",
            description: "Resolve repositories from the frozen Starcat run snapshot.",
            properties: [
                "repoIDs": AgentJSONSchema(
                    type: .array,
                    description: "Optional repository IDs that define the report scope",
                    items: AgentJSONSchema(type: .integer)
                ),
                "maxRepositories": AgentJSONSchema(type: .integer, description: "Maximum repositories to return", defaultValue: .number(40)),
                "sort": AgentJSONSchema(
                    type: .string,
                    description: "Repository ordering",
                    enumValues: [.string("starred_at"), .string("stars"), .string("name")],
                    defaultValue: .string("starred_at")
                )
            ]
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            let arguments = input.arguments.objectValue ?? [:]
            let repoIDs = arguments["repoIDs"]?.integerArrayValue.map(Int64.init) ?? []
            let unknownIDs = repoIDs.filter { id in !input.context.repos.contains(where: { $0.id == id }) }
            guard unknownIDs.isEmpty else {
                return failedAgentToolResult(
                    toolName: id,
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    message: "Unknown Agent repository IDs: \(unknownIDs.map(String.init).joined(separator: ", "))"
                )
            }
            let limit = min(max(arguments["maxRepositories"]?.integerValue ?? 40, 1), 100)
            let sort = arguments["sort"]?.stringValue.flatMap(WeeklyReportRepoSort.init(rawValue:)) ?? .starredAt
            return GitHubWeeklyReportTools.resolveCandidateRepos(
                context: input.context,
                repoIDs: repoIDs,
                limit: limit,
                sort: sort
            ).agentToolResult()
        }
    }

    struct ClusterTopicsTool: AgentTool {
        let definition = makeReadOnlyToolDefinition(
            name: "repo_cluster_topics",
            description: "Cluster resolved repositories into evidence-backed weekly report topics.",
            properties: [
                "repoIDs": AgentJSONSchema(
                    type: .array,
                    description: "Repository IDs to cluster",
                    items: AgentJSONSchema(type: .integer)
                ),
                "maxTopics": AgentJSONSchema(type: .integer, description: "Maximum topic count", defaultValue: .number(4))
            ]
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            let arguments = input.arguments.objectValue ?? [:]
            let repoIDs = arguments["repoIDs"]?.integerArrayValue.map(Int64.init) ?? []
            let unknownIDs = repoIDs.filter { id in !input.context.repos.contains(where: { $0.id == id }) }
            guard unknownIDs.isEmpty else {
                return failedAgentToolResult(
                    toolName: id,
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    message: "Unknown Agent repository IDs: \(unknownIDs.map(String.init).joined(separator: ", "))"
                )
            }
            let maxTopics = min(max(arguments["maxTopics"]?.integerValue ?? 4, 1), 12)
            let (topics, result) = GitHubWeeklyReportTools.clusterTopics(
                context: input.context,
                repoIDs: repoIDs,
                maxTopics: maxTopics
            )
            return result.agentToolResult(payload: .topics(topics))
        }
    }

    struct BuildMarkdownTool: AgentTool {
        let definition = makeReadOnlyToolDefinition(
            name: "artifact_build_weekly_report",
            description: "Build a Markdown weekly report draft from resolved repositories, topics, and source evidence.",
            properties: [
                "title": AgentJSONSchema(type: .string, description: "Report title"),
                "style": AgentJSONSchema(type: .string, description: "Requested editorial style"),
                "includeSources": AgentJSONSchema(type: .boolean, description: "Include source references", defaultValue: .bool(true))
            ],
            completesRun: true
        )

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
                topics: topics,
                externalContextMarkdown: input.values["externalContextMarkdown"] ?? ""
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

enum RepoInsightAgentTools {
    struct ParseGoalTool: AgentTool {
        let definition = makeReadOnlyToolDefinition(
            name: "agent_parse_repo_insight_goal",
            description: "Normalize a repository insight goal without creating write-capable actions.",
            properties: ["goal": AgentJSONSchema(type: .string, description: "Repository analysis goal")],
            required: ["goal"]
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            let prompt = (input.arguments.objectValue?["goal"]?.stringValue ?? input.prompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let effectivePrompt = prompt.isEmpty ? String.l10n("agent.definition.repoInsight.defaultPrompt") : prompt
            return makeResult(
                toolName: id,
                summary: "Repo Insight",
                input: """
                prompt:
                \(effectivePrompt)

                context_source:
                \(input.context.sourceDescription)
                """,
                output: """
                goal: Repo Insight
                artifact: markdown
                write_policy: read-only
                repo_count: \(input.context.repos.count)
                """,
                log: "Parsed repo insight goal without write-capable actions."
            ).agentToolResult()
        }
    }

    struct SelectRepoTool: AgentTool {
        let definition = makeReadOnlyToolDefinition(
            name: "context_select_repo",
            description: "Select one repository from the frozen Starcat run snapshot.",
            properties: [
                "repoID": AgentJSONSchema(type: .integer, description: "Preferred Starcat repository ID"),
                "fullName": AgentJSONSchema(type: .string, description: "Preferred owner/name when ID is unavailable")
            ]
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            let arguments = input.arguments.objectValue ?? [:]
            guard let repo = selectRepo(arguments: arguments, repos: input.context.repos) else {
                return failedAgentToolResult(
                    toolName: id,
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    message: "No repository matches repoID/fullName in the frozen Agent context."
                )
            }
            let result = makeResult(
                toolName: id,
                summary: repo.fullName,
                input: """
                requested:
                \((try? input.arguments.jsonString()) ?? "{}")

                candidates:
                \(input.context.repos.map { "- \($0.displaySummary)" }.joined(separator: "\n"))
                """,
                output: repoDetail(repo),
                log: "Selected target repo from frozen AgentRunContext."
            )
            return result.agentToolResult(payload: .repo(repo))
        }

        private func selectRepo(
            arguments: [String: AgentJSONValue],
            repos: [AgentRepoSnapshot]
        ) -> AgentRepoSnapshot? {
            if let repoID = arguments["repoID"]?.integerValue {
                return repos.first(where: { $0.id == Int64(repoID) })
            }
            if let fullName = arguments["fullName"]?.stringValue {
                return repos.first(where: { $0.fullName.caseInsensitiveCompare(fullName) == .orderedSame })
            }
            return nil
        }
    }

    struct BuildMarkdownTool: AgentTool {
        let definition = makeReadOnlyToolDefinition(
            name: "artifact_build_repo_insight",
            description: "Build an evidence-oriented Markdown insight artifact for the selected repository.",
            properties: [
                "repoID": AgentJSONSchema(type: .integer, description: "Selected Starcat repository ID"),
                "style": AgentJSONSchema(type: .string, description: "Requested analysis style")
            ],
            completesRun: true
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            guard case .repo(let repo) = input.payload else {
                let output = AgentToolOutput(
                    toolName: id,
                    summary: "missing repo",
                    detail: "Repo Insight requires a selected repository payload.",
                    input: "payload: \(input.payload)",
                    output: "artifact: null",
                    log: "Selected repo payload is missing."
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
            let markdown = buildMarkdown(
                prompt: input.prompt,
                context: input.context,
                repo: repo,
                externalContextMarkdown: input.values["externalContextMarkdown"] ?? ""
            )
            let result = makeResult(
                toolName: id,
                summary: "\(markdown.count) chars",
                input: "selected_repo: \(repo.fullName)\nexternal_context_chars: \((input.values["externalContextMarkdown"] ?? "").count)",
                output: String(markdown.prefix(1_200)),
                log: "Built Repo Insight Markdown artifact from read-only context."
            )
            return result.agentToolResult(payload: .markdown(markdown))
        }
    }

    private static func buildMarkdown(
        prompt: String,
        context: AgentRunContext,
        repo: AgentRepoSnapshot,
        externalContextMarkdown: String
    ) -> String {
        let topics = repo.topics.prefix(8).joined(separator: ", ")
        let topicsLine = topics.isEmpty ? "暂无 topic" : topics
        let external = externalContextMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let externalSection = external.isEmpty ? "> 外部来源：未启用或无结果" : """
        > 外部来源：External Search

        ## 外部来源摘要

        \(String(external.prefix(2_400)))
        """
        return """
        # Repo Insight: \(repo.fullName)

        > 用户目标：\(prompt)
        > 数据来源：\(context.sourceDescription)
        > 只读约束：Agent 不会写入标签、笔记、状态或修改 Star。
        \(externalSection)

        ## 仓库快照

        \(repoDetail(repo))

        ## 初步分析方向

        - 定位：根据描述、语言、stars 和 topics 判断仓库适合解决的问题。
        - 采用价值：结合活跃度信号和 Starcat 本地知识库上下文给出采用建议。
        - 风险：标记需要人工继续核验的 README、License、维护活跃度或替代品风险。
        - 后续动作：建议继续追问替代品对比、README 深读或接入成本评估。

        ## Topics

        \(topicsLine)
        """
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

    private static func repoDetail(_ repo: AgentRepoSnapshot) -> String {
        """
        repo: \(repo.fullName)
        language: \(repo.language ?? "Unknown")
        stars: \(repo.starsCount)
        description: \(repo.description ?? "暂无描述")
        topics: \(repo.topics.joined(separator: ", "))
        url: \(repo.htmlUrl)
        """
    }
}
