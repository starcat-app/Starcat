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

/// 模型传给 `external_search` 的稳定业务参数。
///
/// Runtime 会先按 JSON Schema 校验；这里仍做一次类型化解析，确保工具执行层不会退回
/// 使用整段用户 prompt，也不会静默忽略模型明确给出的筛选条件。
struct AgentExternalSearchRequest: Equatable, Sendable {
    var query: String
    var maxResults: Int
    var allowedDomains: [String]
    var recency: String?
    var repoIDs: [Int64]

    init(
        query: String,
        maxResults: Int,
        allowedDomains: [String],
        recency: String?,
        repoIDs: [Int64]
    ) {
        self.query = query
        self.maxResults = maxResults
        self.allowedDomains = allowedDomains
        self.recency = recency
        self.repoIDs = repoIDs
    }

    init(arguments: AgentJSONValue) throws {
        guard let object = arguments.objectValue,
              let query = object["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else {
            throw AgentExternalSearchRequestError.missingQuery
        }

        self.query = query
        self.maxResults = min(max(object["maxResults"]?.integerValue ?? 10, 1), 20)
        self.allowedDomains = try Self.stringArray(object["allowedDomains"], key: "allowedDomains")
            .compactMap(Self.normalizedDomain)
        self.recency = object["recency"]?.stringValue
        self.repoIDs = try Self.integerArray(object["repoIDs"], key: "repoIDs")
            .compactMap(Int64.init(exactly:))
            .uniqued()
    }

    var providerRequest: ExternalSearchRequest {
        ExternalSearchRequest(
            query: query,
            purpose: .aiContext,
            maxResults: maxResults,
            freshness: recency,
            includeDomains: allowedDomains
        )
    }

    var auditSummary: String {
        [
            "query=\(query)",
            "max_results=\(maxResults)",
            "allowed_domains=\(allowedDomains.joined(separator: ","))",
            "recency=\(recency ?? "none")",
            "repo_ids=\(repoIDs.map(String.init).joined(separator: ","))"
        ].joined(separator: "\n")
    }

    private static func stringArray(_ value: AgentJSONValue?, key: String) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let values) = value else {
            throw AgentExternalSearchRequestError.invalidArray(key)
        }
        return try values.map { item in
            guard let string = item.stringValue else {
                throw AgentExternalSearchRequestError.invalidArray(key)
            }
            return string
        }
    }

    private static func integerArray(_ value: AgentJSONValue?, key: String) throws -> [Int] {
        guard let value else { return [] }
        guard case .array(let values) = value else {
            throw AgentExternalSearchRequestError.invalidArray(key)
        }
        return try values.map { item in
            guard let integer = item.integerValue else {
                throw AgentExternalSearchRequestError.invalidArray(key)
            }
            return integer
        }
    }

    private static func normalizedDomain(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let host = url.host {
            return host.lowercased()
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
}

private enum AgentExternalSearchRequestError: LocalizedError {
    case missingQuery
    case invalidArray(String)

    var errorDescription: String? {
        switch self {
        case .missingQuery:
            return String.l10n("agent.externalSearch.error.missingQuery")
        case .invalidArray(let key):
            return String(format: String.l10n("agent.externalSearch.error.invalidArgumentFormat"), key)
        }
    }
}

@MainActor
protocol AgentExternalSearchCollecting: Sendable {
    func collect(request: AgentExternalSearchRequest, context: AgentRunContext) async -> AgentExternalSearchCollection
}

/// 默认降级 collector。
///
/// Runtime 单测和无 Settings 注入的调用路径仍需要完整工具链,但不能凭空联网或伪造来源。
/// 真正的工作台会注入 `AppSettingsAgentExternalSearchCollector`。
@MainActor
struct DisabledAgentExternalSearchCollector: AgentExternalSearchCollecting {
    func collect(request: AgentExternalSearchRequest, context: AgentRunContext) async -> AgentExternalSearchCollection {
        AgentExternalSearchCollection(
            status: .skipped,
            markdown: "",
            sourceItems: [],
            querySummary: request.auditSummary,
            log: String.l10n("agent.externalSearch.log.unconfigured")
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
        permission: .openWorldRead,
        timeoutMilliseconds: 45_000,
        retryPolicy: .transientRead
    )

    private let collector: any AgentExternalSearchCollecting

    init(collector: any AgentExternalSearchCollecting) {
        self.collector = collector
    }

    func execute(_ input: AgentToolInput) async -> AgentToolResult {
        let collection: AgentExternalSearchCollection
        if input.context.webSearchEnabled == false {
            // 全局设置只代表“能力可用”；每个 run 还必须由 Composer 单独授权。
            collection = AgentExternalSearchCollection(
                status: .skipped,
                markdown: "",
                sourceItems: [],
                querySummary: (try? input.arguments.jsonString()) ?? "",
                log: String.l10n("agent.externalSearch.log.disabledForRun")
            )
        } else {
            do {
                let request = try AgentExternalSearchRequest(arguments: input.arguments)
                collection = await collector.collect(request: request, context: input.context)
            } catch {
                collection = AgentExternalSearchCollection(
                    status: .failed,
                    markdown: "",
                    sourceItems: [],
                    querySummary: (try? input.arguments.jsonString()) ?? "invalid_arguments",
                    log: error.localizedDescription
                )
            }
        }
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
                kind: String.l10n("agent.trace.kind.tool"),
                title: id,
                summary: output.summary,
                input: output.input,
                output: output.output,
                log: output.log,
                status: collection.status.stepStatus,
                relatedToolOutputID: output.id
            ),
            payload: collection.markdown.isEmpty ? .none : .externalContextMarkdown(collection.markdown),
            sources: collection.sourceItems.map {
                AgentToolResultSource(
                    title: $0.title,
                    url: $0.url.absoluteString,
                    provider: $0.provider.displayName
                )
            }
        )
    }

    private static func summary(for collection: AgentExternalSearchCollection) -> String {
        switch collection.status {
        case .completed:
            return String(
                format: String.l10n("agent.externalSearch.summary.sourcesFormat"),
                collection.sourceItems.count
            )
        case .skipped:
            return String.l10n("agent.tool.status.skipped")
        case .failed:
            return String.l10n("agent.tool.status.failed")
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

    init(
        settings: AppSettings,
        contextProvider: ExternalSearchContextProvider? = nil
    ) {
        self.settings = settings
        self.contextProvider = contextProvider ?? ExternalSearchContextProvider(settings: settings)
    }

    func collect(request: AgentExternalSearchRequest, context: AgentRunContext) async -> AgentExternalSearchCollection {
        guard settings.externalContextEnabled else {
            return AgentExternalSearchCollection(
                status: .skipped,
                markdown: "",
                sourceItems: [],
                querySummary: request.auditSummary,
                log: String.l10n("agent.externalSearch.log.disabledInSettings")
            )
        }

        let reposByID = Dictionary(uniqueKeysWithValues: context.repos.map { ($0.id, $0) })
        let unknownRepoIDs = request.repoIDs.filter { reposByID[$0] == nil }
        guard unknownRepoIDs.isEmpty else {
            return AgentExternalSearchCollection(
                status: .failed,
                markdown: "",
                sourceItems: [],
                querySummary: request.auditSummary,
                log: String(
                    format: String.l10n("agent.externalSearch.log.unknownRepositoriesFormat"),
                    unknownRepoIDs.map(String.init).joined(separator: ", ")
                )
            )
        }

        let selectedRepos = request.repoIDs.compactMap { reposByID[$0] }
        // 模型已经看过完整冻结上下文，不能靠 query 是否恰好包含 fullName 判断泄漏。
        // 用户未授权私有仓库联网时，只要业务上下文含私有仓库，就关闭该 run 的外部搜索。
        let blockedPrivateRepos = settings.externalSearchAllowPrivateRepos
            ? []
            : context.repos.filter(\.isPrivate)
        guard blockedPrivateRepos.isEmpty else {
            return AgentExternalSearchCollection(
                status: .skipped,
                markdown: "",
                sourceItems: [],
                querySummary: request.auditSummary,
                log: String(
                    format: String.l10n("agent.externalSearch.log.privateRepositoriesBlockedFormat"),
                    blockedPrivateRepos.map(\.fullName).joined(separator: ", ")
                )
            )
        }

        do {
            let externalContext = try await contextProvider.collect(
                request: request.providerRequest,
                cacheScopeID: selectedRepos.first?.id ?? 0
            )
            let sourceItems = externalContext?.sourceItems ?? []
            let log = [
                "provider_selection=\(settings.externalContextProviderSelection.rawValue)",
                "aggregate=\(settings.aggregateExternalContextSearchEnabled && settings.isProUser)",
                "cache=managed_by_ExternalSearchContextProvider",
                "sources=\(sourceItems.count)"
            ].joined(separator: "\n")
            return AgentExternalSearchCollection(
                status: externalContext == nil ? .skipped : .completed,
                markdown: externalContext?.markdown ?? "",
                sourceItems: sourceItems,
                querySummary: request.auditSummary,
                log: log
            )
        } catch {
            return AgentExternalSearchCollection(
                status: .failed,
                markdown: "",
                sourceItems: [],
                querySummary: request.auditSummary,
                log: String(
                    format: String.l10n("agent.externalSearch.log.failedFormat"),
                    error.localizedDescription
                )
            )
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
