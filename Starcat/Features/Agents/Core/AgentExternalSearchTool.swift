//
//  AgentExternalSearchTool.swift
//  Starcat
//
//  Agent 使用的外部网络搜索工具。
//
//  这里不创建新的搜索 Provider 或 API Key 设置,而是复用现有 External Search 体系:
//  `AppSettings` -> `ExternalSearchRegistry` -> `ExternalSearchContextProvider`。
//  Agent 只拿到预算受控的 markdown 和来源清单,完整联网细节由中栏 trace 审计。
//

import Foundation

struct AgentExternalSearchCollection: Sendable {
    var status: AgentToolStatus
    var markdown: String
    var sourceItems: [AIExternalContextSource]
    var querySummary: String
    var log: String
}

@MainActor
protocol AgentExternalSearchCollecting: Sendable {
    func collect(prompt: String, context: AgentRunContext) async -> AgentExternalSearchCollection
}

/// 默认降级 collector。
///
/// Runtime 单测和无 Settings 注入的调用路径仍需要完整工具链,但不能凭空联网或伪造来源。
/// 真正的工作台会注入 `AppSettingsAgentExternalSearchCollector`。
@MainActor
struct DisabledAgentExternalSearchCollector: AgentExternalSearchCollecting {
    func collect(prompt: String, context: AgentRunContext) async -> AgentExternalSearchCollection {
        AgentExternalSearchCollection(
            status: .skipped,
            markdown: "",
            sourceItems: [],
            querySummary: "external_search=disabled_default_collector",
            log: "External Search collector is not configured for this runtime."
        )
    }
}

struct ExternalSearchAgentTool: AgentTool {
    let definition = AgentToolDefinition(
        name: "external_search",
        description: "Search configured external providers for public evidence relevant to repositories or the user goal.",
        inputSchema: AgentJSONSchema(
            type: .object,
            properties: [
                "query": AgentJSONSchema(type: .string, description: "Focused search query"),
                "maxResults": AgentJSONSchema(type: .integer, description: "Maximum result count", defaultValue: .number(10)),
                "allowedDomains": AgentJSONSchema(
                    type: .array,
                    description: "Optional domain allowlist",
                    items: AgentJSONSchema(type: .string)
                ),
                "recency": AgentJSONSchema(
                    type: .string,
                    description: "Optional recency window",
                    enumValues: [.string("day"), .string("week"), .string("month"), .string("year")]
                ),
                "repoIDs": AgentJSONSchema(
                    type: .array,
                    description: "Optional Starcat repository IDs",
                    items: AgentJSONSchema(type: .integer)
                )
            ],
            required: ["query"]
        ),
        permission: .readOnly,
        timeoutMilliseconds: 45_000,
        retryPolicy: .transientRead
    )

    private let collector: any AgentExternalSearchCollecting

    init(collector: any AgentExternalSearchCollecting) {
        self.collector = collector
    }

    func execute(_ input: AgentToolInput) async -> AgentToolResult {
        let collection = await collector.collect(prompt: input.prompt, context: input.context)
        let outputText = Self.formatSources(collection.sourceItems)
        let output = AgentToolOutput(
            toolName: id,
            summary: Self.summary(for: collection),
            detail: collection.markdown.isEmpty ? collection.log : collection.markdown,
            input: collection.querySummary,
            output: outputText.isEmpty ? collection.log : outputText,
            log: collection.log
        )
        return AgentToolResult(
            status: collection.status,
            output: output,
            trace: AgentTraceSpan(
                kind: "Tool",
                title: id,
                summary: output.summary,
                input: output.input,
                output: output.output,
                log: output.log,
                status: collection.status.stepStatus,
                relatedToolOutputID: output.id
            ),
            payload: collection.markdown.isEmpty ? .none : .externalContextMarkdown(collection.markdown)
        )
    }

    private static func summary(for collection: AgentExternalSearchCollection) -> String {
        switch collection.status {
        case .completed:
            return "\(collection.sourceItems.count) sources"
        case .skipped:
            return "skipped"
        case .failed:
            return "failed"
        case .requiresConfirmation:
            return "requires confirmation"
        }
    }

    private static func formatSources(_ sources: [AIExternalContextSource]) -> String {
        sources.map { source in
            "- [\(source.provider.displayName)] \(source.title) — \(source.url.absoluteString)"
        }
        .joined(separator: "\n")
    }
}

@MainActor
final class AppSettingsAgentExternalSearchCollector: AgentExternalSearchCollecting {
    private let settings: AppSettings
    private let contextProvider: ExternalSearchContextProvider
    private let maxRepos: Int

    init(
        settings: AppSettings,
        contextProvider: ExternalSearchContextProvider? = nil,
        maxRepos: Int = 3
    ) {
        self.settings = settings
        self.contextProvider = contextProvider ?? ExternalSearchContextProvider(settings: settings)
        self.maxRepos = maxRepos
    }

    func collect(prompt: String, context: AgentRunContext) async -> AgentExternalSearchCollection {
        guard settings.externalContextEnabled else {
            return AgentExternalSearchCollection(
                status: .skipped,
                markdown: "",
                sourceItems: [],
                querySummary: "externalContextEnabled=false",
                log: "External Search is disabled in Settings."
            )
        }

        let repos = context.repos.prefix(maxRepos).map(Self.repo(from:))
        guard !repos.isEmpty else {
            return AgentExternalSearchCollection(
                status: .skipped,
                markdown: "",
                sourceItems: [],
                querySummary: "repo_count=0",
                log: "No Agent repo snapshots available for External Search."
            )
        }

        var markdownBlocks: [String] = []
        var sourceItems: [AIExternalContextSource] = []
        var errors: [String] = []
        for repo in repos {
            do {
                if let context = try await contextProvider.collect(for: repo) {
                    markdownBlocks.append(context.markdown)
                    sourceItems.append(contentsOf: context.sourceItems)
                }
            } catch {
                errors.append("\(repo.fullName): \(error.localizedDescription)")
            }
        }

        if markdownBlocks.isEmpty, !errors.isEmpty {
            return AgentExternalSearchCollection(
                status: .failed,
                markdown: "",
                sourceItems: [],
                querySummary: Self.querySummary(for: repos),
                log: "External Search failed:\n\(errors.joined(separator: "\n"))"
            )
        }

        let status: AgentToolStatus = markdownBlocks.isEmpty ? .skipped : .completed
        let logLines = [
            "provider_selection=\(settings.externalContextProviderSelection.rawValue)",
            "aggregate=\(settings.aggregateExternalContextSearchEnabled && settings.isProUser)",
            "cache=managed_by_ExternalSearchContextProvider",
            "sources=\(sourceItems.count)"
        ] + errors.map { "degraded=\($0)" }
        return AgentExternalSearchCollection(
            status: status,
            markdown: markdownBlocks.joined(separator: "\n\n"),
            sourceItems: sourceItems,
            querySummary: Self.querySummary(for: repos),
            log: logLines.joined(separator: "\n")
        )
    }

    private static func querySummary(for repos: [Repo]) -> String {
        repos.map { repo in
            let queries = ExternalSearchContextProvider.queries(for: repo)
            return """
            repo: \(repo.fullName)
            queries:
            \(queries.map { "- \($0)" }.joined(separator: "\n"))
            """
        }
        .joined(separator: "\n\n")
    }

    private static func repo(from snapshot: AgentRepoSnapshot) -> Repo {
        Repo(
            id: snapshot.id,
            owner: snapshot.owner,
            name: snapshot.name,
            fullName: snapshot.fullName,
            description: snapshot.description,
            language: snapshot.language,
            starsCount: snapshot.starsCount,
            forksCount: 0,
            watchersCount: 0,
            topics: encodeTopics(snapshot.topics),
            license: nil,
            homepage: nil,
            htmlUrl: snapshot.htmlUrl,
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: snapshot.isStarred,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: snapshot.starredAt,
            cachedAt: nil
        )
    }

    private static func encodeTopics(_ topics: [String]) -> String? {
        guard !topics.isEmpty,
              let data = try? JSONEncoder().encode(topics)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
