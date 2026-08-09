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
    /// 保留 Context Provider 按 Weekly 最近观察时间冻结的顺序。
    case recent
    case stars
    case name
}

enum GitHubWeeklyReportTools {

    static func parseGoal(prompt: String, context: AgentRunContext) -> WeeklyReportToolResult {
        let effectivePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGoal = effectivePrompt.isEmpty ? "生成 GitHub 技术周刊 Markdown" : effectivePrompt
        return makeResult(
            toolName: "agent_parse_goal",
            summary: String.l10n("agent.weekly.tool.summary.report"),
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
            log: String.l10n("agent.weekly.tool.log.goalParsed")
        )
    }

    static func resolveCandidateRepos(
        context: AgentRunContext,
        repoIDs: [Int64] = [],
        limit: Int = 12,
        sort: WeeklyReportRepoSort = .recent
    ) async throws -> WeeklyReportToolResult {
        let executor = RepositoryReadCapabilityExecutor(
            source: FrozenRepositoryReadCapabilitySource(repositories: context.repos)
        )
        let result = try await executor.search(
            RepositorySearchCapabilityRequest(
                limit: limit,
                restrictedRepoIDs: repoIDs,
                // Agent 的 repoIDs 是模型对冻结上下文施加的进一步约束。任何未知 ID 都
                // 必须让整次读取失败，不能被静默丢弃后继续生成不完整 artifact。
                requiresCompleteRestriction: true,
                sort: sort.capabilitySort
            )
        )
        let repos = result.repositories
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
            log: String.l10n("agent.weekly.tool.log.repositoriesResolved")
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
            nonEmpty(repo.language) ?? String.l10n("agent.weekly.topic.other")
        }
        let unsortedTopics: [WeeklyReportTopic] = groupedByLanguage.map { language, repos in
            let sortedRepos = repos.sorted { $0.starsCount > $1.starsCount }
            return WeeklyReportTopic(
                title: language == String.l10n("agent.weekly.topic.other")
                    ? String.l10n("agent.weekly.topic.crossLanguage")
                    : String(format: String.l10n("agent.weekly.topic.languageFormat"), language),
                reason: String.l10n("agent.weekly.topic.reason"),
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
                log: String.l10n("agent.weekly.tool.log.topicsClustered")
            )
        )
    }

    fileprivate static func makeResult(
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
                kind: String.l10n("agent.trace.kind.tool"),
                title: toolName,
                summary: summary,
                input: input,
                output: output,
                log: log,
                relatedToolOutputID: toolOutput.id
            )
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension WeeklyReportRepoSort {
    var capabilitySort: RepositoryCapabilitySort {
        switch self {
        case .recent: .sourceOrder
        case .stars: .stars
        case .name: .name
        }
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
        summary: String.l10n("agent.tool.status.failed"),
        detail: message,
        input: input,
        output: "error: \(message)",
        log: message
    )
    return AgentToolResult(
        status: .failed,
        output: output,
        trace: AgentTraceSpan(
            kind: String.l10n("agent.trace.kind.tool"),
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
        makeAll(
            externalSearchTool: ExternalSearchAgentTool(collector: DisabledAgentExternalSearchCollector()),
            knowledgeTool: AgentKnowledgeTool(searcher: UnavailableAgentKnowledgeSearcher())
        )
    }

    static func makeAll(externalSearchTool: any AgentTool) -> [any AgentTool] {
        makeAll(
            externalSearchTool: externalSearchTool,
            knowledgeTool: AgentKnowledgeTool(searcher: UnavailableAgentKnowledgeSearcher())
        )
    }

    static func makeAll(
        externalSearchTool: any AgentTool,
        knowledgeTool: any AgentTool
    ) -> [any AgentTool] {
        [
            ParseGoalTool(),
            ResolveReposTool(),
            knowledgeTool,
            externalSearchTool,
            ClusterTopicsTool(),
            BuildMarkdownTool(),
            RepoInsightAgentTools.ParseGoalTool(),
            RepoInsightAgentTools.SelectRepoTool(),
            RepoInsightAgentTools.BuildMarkdownTool(),
            RepoAlternativesAgentTools.ParseGoalTool(),
            RepoAlternativesAgentTools.BuildMarkdownTool()
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
                    enumValues: [.string("recent"), .string("stars"), .string("name")],
                    defaultValue: .string("recent")
                )
            ]
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            let arguments = input.arguments.objectValue ?? [:]
            let repoIDs = arguments["repoIDs"]?.integerArrayValue.map(Int64.init) ?? []
            let limit = min(max(arguments["maxRepositories"]?.integerValue ?? 40, 1), 100)
            let sort = arguments["sort"]?.stringValue.flatMap(WeeklyReportRepoSort.init(rawValue:)) ?? .recent
            do {
                return try await GitHubWeeklyReportTools.resolveCandidateRepos(
                    context: input.context,
                    repoIDs: repoIDs,
                    limit: limit,
                    sort: sort
                ).agentToolResult()
            } catch RepositoryReadCapabilityError.repositoriesOutsideScope(let unknownIDs) {
                return failedAgentToolResult(
                    toolName: id,
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    message: "Unknown Agent repository IDs: \(unknownIDs.map(String.init).joined(separator: ", "))"
                )
            } catch {
                return failedAgentToolResult(
                    toolName: id,
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    message: error.localizedDescription
                )
            }
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
        private static let sectionSchema = AgentJSONSchema(
            type: .object,
            properties: [
                "heading": AgentJSONSchema(type: .string, description: "Section heading"),
                "analysis": AgentJSONSchema(type: .string, description: "Evidence-based analysis for this section"),
                "repoIDs": AgentJSONSchema(
                    type: .array,
                    description: "Frozen Starcat repository IDs referenced by this section",
                    items: AgentJSONSchema(type: .integer)
                )
            ],
            required: ["heading", "analysis", "repoIDs"]
        )

        let definition = makeReadOnlyToolDefinition(
            name: "artifact_build_weekly_report",
            description: "Submit a structured weekly report. Sections must cite frozen repository IDs when repositories exist; use an empty sections array for a valid no-new-stars report.",
            properties: [
                "title": AgentJSONSchema(type: .string, description: "Report title"),
                "executiveSummary": AgentJSONSchema(type: .string, description: "Concise report overview grounded in prior tool results"),
                "sections": AgentJSONSchema(
                    type: .array,
                    description: "Ordered report sections",
                    items: Self.sectionSchema
                ),
                "limitations": AgentJSONSchema(
                    type: .array,
                    description: "Known evidence or freshness limitations",
                    items: AgentJSONSchema(type: .string)
                ),
                "includeSources": AgentJSONSchema(type: .boolean, description: "Include source references", defaultValue: .bool(true))
            ],
            required: ["title", "executiveSummary", "sections", "limitations"],
            completesRun: true
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            do {
                let request = try WeeklyReportArtifactRequest(arguments: input.arguments)
                let markdown = try WeeklyReportArtifactBuilder.build(
                    request: request,
                    prompt: input.prompt,
                    context: input.context,
                    externalContextMarkdown: input.values["externalContextMarkdown"] ?? ""
                )
                let result = GitHubWeeklyReportTools.makeResult(
                    toolName: id,
                    summary: "\(markdown.count) chars",
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    output: String(markdown.prefix(1_200)),
                    log: String.l10n("agent.weekly.tool.log.artifactBuilt")
                )
                let referencedIDs = Set(request.sections.flatMap(\.repoIDs))
                let sources = input.context.repos.filter { referencedIDs.contains($0.id) }.map {
                    AgentToolResultSource(title: $0.fullName, url: $0.htmlUrl, provider: "Starcat")
                }
                return result.agentToolResult(payload: .markdown(markdown), sources: sources)
            } catch {
                return failedAgentToolResult(
                    toolName: id,
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    message: error.localizedDescription
                )
            }
        }
    }
}

private extension WeeklyReportToolResult {
    func agentToolResult(
        payload: AgentToolPayload = .none,
        sources: [AgentToolResultSource] = []
    ) -> AgentToolResult {
        AgentToolResult(
            status: trace.status == .failed ? .failed : .completed,
            output: output,
            trace: trace,
            payload: payload,
            sources: sources
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
                summary: String.l10n("agent.repoInsight.tool.summary.report"),
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
                log: String.l10n("agent.repoInsight.tool.log.goalParsed")
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
            let selector = RepositoryCapabilitySelector(
                repoID: arguments["repoID"]?.integerValue.map(Int64.init),
                fullName: arguments["fullName"]?.stringValue
            )
            let executor = RepositoryReadCapabilityExecutor(
                source: FrozenRepositoryReadCapabilitySource(repositories: input.context.repos)
            )
            let repo: AgentRepoSnapshot
            do {
                repo = try await executor.get(selector)
            } catch {
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
                log: String.l10n("agent.repoInsight.tool.log.repositorySelected")
            )
            return result.agentToolResult(payload: .repo(repo))
        }
    }

    struct BuildMarkdownTool: AgentTool {
        let definition = makeReadOnlyToolDefinition(
            name: "artifact_build_repo_insight",
            description: "Submit a structured evidence-oriented insight for one repository from the frozen Starcat context.",
            properties: [
                "repoID": AgentJSONSchema(type: .integer, description: "Selected Starcat repository ID"),
                "title": AgentJSONSchema(type: .string, description: "Artifact title"),
                "summary": AgentJSONSchema(type: .string, description: "Concise evidence-based summary"),
                "positioning": AgentJSONSchema(type: .string, description: "Repository positioning and primary use case"),
                "adoptionFit": AgentJSONSchema(type: .string, description: "Adoption fit based on available evidence"),
                "risks": AgentJSONSchema(
                    type: .array,
                    description: "Evidence-backed risks",
                    items: AgentJSONSchema(type: .string)
                ),
                "recommendedActions": AgentJSONSchema(
                    type: .array,
                    description: "Concrete follow-up actions",
                    items: AgentJSONSchema(type: .string)
                ),
                "limitations": AgentJSONSchema(
                    type: .array,
                    description: "Known evidence limitations",
                    items: AgentJSONSchema(type: .string)
                ),
                "includeSources": AgentJSONSchema(type: .boolean, description: "Include External Search references", defaultValue: .bool(true))
            ],
            required: [
                "repoID", "title", "summary", "positioning", "adoptionFit",
                "risks", "recommendedActions", "limitations"
            ],
            completesRun: true
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            do {
                let request = try RepoInsightArtifactRequest(arguments: input.arguments)
                let markdown = try RepoInsightArtifactBuilder.build(
                    request: request,
                    prompt: input.prompt,
                    context: input.context,
                    externalContextMarkdown: input.values["externalContextMarkdown"] ?? ""
                )
                let repo = input.context.repos.first(where: { $0.id == request.repoID })!
                let result = makeResult(
                    toolName: id,
                    summary: "\(markdown.count) chars",
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    output: String(markdown.prefix(1_200)),
                    log: String.l10n("agent.repoInsight.tool.log.artifactBuilt")
                )
                return result.agentToolResult(
                    payload: .markdown(markdown),
                    sources: [AgentToolResultSource(title: repo.fullName, url: repo.htmlUrl, provider: "Starcat")]
                )
            } catch {
                return failedAgentToolResult(
                    toolName: id,
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    message: error.localizedDescription
                )
            }
        }
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
                kind: String.l10n("agent.trace.kind.tool"),
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

/// Repo Alternatives 复用单仓选择工具，但使用独立的目标解析和 artifact 契约。
///
/// 候选仓库只能由 External Search 提供，因此这里不增加“扫描全部本地仓库”的旁路工具，
/// 也不会把单仓冻结上下文误解释成候选池。
enum RepoAlternativesAgentTools {
    struct ParseGoalTool: AgentTool {
        let definition = makeReadOnlyToolDefinition(
            name: "agent_parse_repo_alternatives_goal",
            description: "Normalize a repository alternatives goal without creating write-capable actions.",
            properties: ["goal": AgentJSONSchema(type: .string, description: "Repository comparison goal")],
            required: ["goal"]
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            let prompt = (input.arguments.objectValue?["goal"]?.stringValue ?? input.prompt)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let effectivePrompt = prompt.isEmpty
                ? String.l10n("agent.definition.repoAlternatives.defaultPrompt")
                : prompt
            return makeResult(
                toolName: id,
                summary: String.l10n("agent.definition.repoAlternatives.title"),
                input: """
                prompt:
                \(effectivePrompt)

                context_source:
                \(input.context.sourceDescription)
                """,
                output: """
                goal: Repo Alternatives
                artifact: markdown
                write_policy: read-only
                repo_count: \(input.context.repos.count)
                """
            ).agentToolResult()
        }
    }

    struct BuildMarkdownTool: AgentTool {
        private static let candidateSchema = AgentJSONSchema(
            type: .object,
            properties: [
                "fullName": AgentJSONSchema(type: .string, description: "Candidate GitHub owner/name from External Search evidence"),
                "url": AgentJSONSchema(type: .string, description: "Candidate https://github.com/owner/name repository URL"),
                "positioning": AgentJSONSchema(type: .string, description: "Evidence-grounded positioning"),
                "adoptionFit": AgentJSONSchema(type: .string, description: "Fit compared with the source repository"),
                "risks": AgentJSONSchema(
                    type: .array,
                    description: "Evidence limitations or adoption risks",
                    items: AgentJSONSchema(type: .string)
                )
            ],
            required: ["fullName", "url", "positioning", "adoptionFit", "risks"]
        )

        let definition = makeReadOnlyToolDefinition(
            name: "artifact_build_repo_alternatives",
            description: "Submit a structured comparison. Every candidate must be a public GitHub repository present in External Search evidence; use an empty candidates array when no evidence is available.",
            properties: [
                "sourceRepoID": AgentJSONSchema(type: .integer, description: "Selected Starcat source repository ID"),
                "title": AgentJSONSchema(type: .string, description: "Artifact title"),
                "summary": AgentJSONSchema(type: .string, description: "Concise evidence-based comparison summary"),
                "candidates": AgentJSONSchema(
                    type: .array,
                    description: "At most 6 externally evidenced alternative repositories",
                    items: Self.candidateSchema
                ),
                "recommendedActions": AgentJSONSchema(
                    type: .array,
                    description: "Concrete follow-up evaluation actions",
                    items: AgentJSONSchema(type: .string)
                ),
                "limitations": AgentJSONSchema(
                    type: .array,
                    description: "Known evidence or freshness limitations",
                    items: AgentJSONSchema(type: .string)
                ),
                "includeSources": AgentJSONSchema(type: .boolean, description: "Include External Search references", defaultValue: .bool(true))
            ],
            required: [
                "sourceRepoID", "title", "summary", "candidates",
                "recommendedActions", "limitations"
            ],
            completesRun: true
        )

        func execute(_ input: AgentToolInput) async -> AgentToolResult {
            do {
                let request = try RepoAlternativesArtifactRequest(arguments: input.arguments)
                let markdown = try RepoAlternativesArtifactBuilder.build(
                    request: request,
                    prompt: input.prompt,
                    context: input.context,
                    externalContextMarkdown: input.values["externalContextMarkdown"] ?? ""
                )
                let sourceRepo = input.context.repos.first(where: { $0.id == request.sourceRepoID })!
                let sources = [
                    AgentToolResultSource(title: sourceRepo.fullName, url: sourceRepo.htmlUrl, provider: "Starcat")
                ] + request.candidates.map {
                    AgentToolResultSource(title: $0.fullName, url: $0.url.absoluteString, provider: "External Search")
                }
                return makeResult(
                    toolName: id,
                    summary: "\(markdown.count) chars",
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    output: String(markdown.prefix(1_200))
                ).agentToolResult(payload: .markdown(markdown), sources: sources)
            } catch {
                return failedAgentToolResult(
                    toolName: id,
                    input: (try? input.arguments.jsonString()) ?? "{}",
                    message: error.localizedDescription
                )
            }
        }
    }

    private static func makeResult(
        toolName: String,
        summary: String,
        input: String,
        output: String
    ) -> WeeklyReportToolResult {
        let completed = String.l10n("agent.tool.status.completed")
        let toolOutput = AgentToolOutput(
            toolName: toolName,
            summary: summary,
            detail: output,
            input: input,
            output: output,
            log: completed
        )
        return WeeklyReportToolResult(
            output: toolOutput,
            trace: AgentTraceSpan(
                kind: String.l10n("agent.trace.kind.tool"),
                title: toolName,
                summary: summary,
                input: input,
                output: output,
                log: completed,
                relatedToolOutputID: toolOutput.id
            )
        )
    }
}
