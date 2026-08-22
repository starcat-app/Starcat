//
//  StarcatMCPToolRegistry.swift
//  Starcat
//
//  MCP tools/resources 注册表。
//
//  本文件只描述 MCP 协议层：工具 schema、参数解析、结果包装。实际数据读取统一委托
//  `StarcatMCPFacade`，让权限、审计和后续写入审批有单一接入点。
//

import Foundation
import MCP

@MainActor
final class StarcatMCPToolRegistry {
    private let facade: StarcatMCPFacade
    private let writeFacade: StarcatMCPWriteFacade
    private let allowedToolNames: Set<String>?
    private let exposesResources: Bool

    init(
        facade: StarcatMCPFacade,
        writeFacade: StarcatMCPWriteFacade,
        allowedToolNames: Set<String>? = nil,
        exposesResources: Bool = true
    ) {
        self.facade = facade
        self.writeFacade = writeFacade
        self.allowedToolNames = allowedToolNames
        self.exposesResources = exposesResources
    }

    /// 临时外部 Runtime MCP Bridge 只能从这组工具中继续收窄。即使模型绕过
    /// `tools/list` 直接构造 `tools/call`，Registry 入口也会再次执行 allowlist。
    static let readOnlyToolNames: Set<String> = [
        "starcat.get_capabilities",
        "starcat.get_overview_statistics",
        "starcat.get_ai_usage_statistics",
        "starcat.get_knowledge_base_statistics",
        "starcat.search_repos",
        "starcat.global_search_repos",
        "starcat.semantic_search",
        "starcat.get_repo",
        "starcat.get_repo_context",
        "starcat.get_repo_summary",
        "starcat.get_readme",
        "starcat.list_tags",
        "starcat.get_repo_note",
    ]

    func register(on server: Server) async {
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self else { return .init(tools: []) }
            return await MainActor.run {
                .init(tools: self.tools)
            }
        }

        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else {
                return .init(content: [.text(text: "MCP registry is unavailable.", annotations: nil, _meta: nil)], isError: true)
            }
            return await self.callTool(params)
        }

        await server.withMethodHandler(ListResources.self) { [weak self] _ in
            guard let self else { return .init(resources: []) }
            guard self.exposesResources else { return .init(resources: []) }
            do {
                let descriptors = try await self.facade.resources()
                return .init(resources: descriptors.map { item in
                    Resource(
                        name: item.name,
                        uri: item.uri,
                        description: item.description,
                        mimeType: item.mimeType
                    )
                })
            } catch {
                return .init(resources: [])
            }
        }

        await server.withMethodHandler(ReadResource.self) { [weak self] params in
            guard let self else {
                throw MCPError.internalError("MCP registry is unavailable.")
            }
            guard self.exposesResources else {
                throw MCPError.invalidRequest("MCP resources are disabled for this Runtime.")
            }
            let result = try await self.facade.readResource(uri: params.uri)
            return .init(contents: [
                .text(result.text, uri: params.uri, mimeType: result.mimeType)
            ])
        }
    }

    private var tools: [Tool] {
        let allTools = [
            Tool(
                name: "starcat.get_capabilities",
                title: "Get Starcat MCP capabilities",
                description: "Read the current Starcat MCP privacy and write-permission capabilities before planning a workflow.",
                inputSchema: Self.objectSchema([:]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.get_overview_statistics",
                title: "Get Starcat overview statistics",
                description: "Read common local counts in one call: starred repositories, knowledge-base projects, all-time AI token usage, and RAG index health.",
                inputSchema: Self.objectSchema([:]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.get_ai_usage_statistics",
                title: "Get Starcat AI usage statistics",
                description: "Read local aggregate AI token and call statistics. This never returns prompts, responses, API keys, or raw error text.",
                inputSchema: Self.objectSchema([
                    "time_range": Self.stringSchema(
                        "Aggregation window.",
                        enumValues: AIUsageTimeRange.allCases.map(\.rawValue),
                        defaultValue: AIUsageTimeRange.all.rawValue
                    ),
                    "feature": Self.stringSchema(
                        "Optional Starcat feature filter.",
                        enumValues: AIUsageFeature.allCases.map(\.rawValue)
                    ),
                    "provider_id": Self.stringSchema("Optional AI provider profile identifier."),
                    "model": Self.stringSchema("Optional model name.")
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.get_knowledge_base_statistics",
                title: "Get Starcat knowledge-base statistics",
                description: "Read local knowledge-base organization, source coverage, RAG chunk counts, and index health. Private-note counts follow the private_notes_read capability.",
                inputSchema: Self.objectSchema([:]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.search_repos",
                title: "Search Starcat repositories",
                description: "Search repositories cached in Starcat using local keyword/FTS data.",
                inputSchema: Self.objectSchema([
                    "query": Self.stringSchema("Optional keyword query. Empty or omitted returns recent/all repositories for the selected scope."),
                    "scope": Self.semanticScopeSchema(),
                    "limit": Self.integerSchema("Maximum number of repositories to return.", defaultValue: 20, minimum: 1, maximum: 100)
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.global_search_repos",
                title: "Search local and GitHub repositories",
                description: "Search Starcat local repositories and GitHub in one request. Results preserve source labels, prefer local metadata, and include safe open URLs for external launchers.",
                inputSchema: Self.objectSchema([
                    "query": Self.stringSchema("Required repository keyword query, 1 to 200 characters."),
                    "limit": Self.integerSchema(
                        "Maximum number of deduplicated repositories to return.",
                        defaultValue: 30,
                        minimum: 1,
                        maximum: 50
                    ),
                    "sources": Self.stringArraySchema(
                        "Optional search sources. Supported values: local, github. Defaults to both."
                    )
                ], required: ["query"]),
                annotations: .init(readOnlyHint: true, openWorldHint: true)
            ),
            Tool(
                name: "starcat.semantic_search",
                title: "Semantic search Starcat repositories",
                description: "Use Starcat's local embedding index and configured BYOK provider to semantically search repositories.",
                inputSchema: Self.objectSchema([
                    "query": Self.stringSchema("Required semantic search query."),
                    "scope": Self.semanticScopeSchema(),
                    "limit": Self.integerSchema("Maximum number of semantic matches to return.", defaultValue: 20, minimum: 1, maximum: 80)
                ], required: ["query"]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.get_repo",
                title: "Get Starcat repository",
                description: "Read metadata for one repository by repo_id or owner/name.",
                inputSchema: Self.repoSelectorSchema(),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.get_repo_context",
                title: "Get aggregated repository context",
                description: "Read repository metadata, assigned tags, optional private note/status, and cached AI summary in one call.",
                inputSchema: Self.repoSelectorSchema(),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.get_repo_summary",
                title: "Get cached repository summary",
                description: "Read the latest cached Starcat AI summary without generating content or making network requests.",
                inputSchema: Self.repoSelectorSchema(),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.generate_repo_summary",
                title: "Generate repository summary",
                description: "Generate a Starcat AI summary using the user's configured provider. This consumes AI quota and may use external context when explicitly allowed.",
                inputSchema: Self.objectSchema(
                    Self.repoSelectorProperties().merging([
                        "allow_external_context": Self.booleanSchema(
                            "Allow Starcat's configured External Search provider to supplement the summary.",
                            defaultValue: false
                        )
                    ]) { _, new in new }
                ),
                annotations: .init(readOnlyHint: false, openWorldHint: true)
            ),
            Tool(
                name: "starcat.get_readme",
                title: "Get cached README",
                description: "Read cached README HTML and markdown for one repository by repo_id or owner/name.",
                inputSchema: Self.repoSelectorSchema(),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.list_tags",
                title: "List Starcat tags",
                description: "List all user-defined Starcat tags.",
                inputSchema: Self.objectSchema([:]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.get_repo_note",
                title: "Get private repo note",
                description: "Read a repository private note and status. This only works when private note exposure is enabled in Starcat Settings.",
                inputSchema: Self.repoSelectorSchema(),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.upsert_repo_note",
                title: "Write private repo note",
                description: "Write or clear a repository private note. Requires MCP local writes in Starcat Settings. Passing an empty content clears the note body.",
                inputSchema: Self.objectSchema(
                    Self.repoSelectorProperties().merging([
                        "content": Self.stringSchema("Markdown note content. Empty string clears the note body."),
                        "dry_run": Self.booleanSchema("Validate the write without persisting it.", defaultValue: false)
                    ]) { _, new in new }
                ),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ),
            Tool(
                name: "starcat.set_repo_status",
                title: "Set repo reading status",
                description: "Set a repository status to unread, read, or using. Requires MCP local writes in Starcat Settings.",
                inputSchema: Self.objectSchema(
                    Self.repoSelectorProperties().merging([
                        "status": Self.stringSchema("Repository reading status.", enumValues: ["unread", "read", "using"]),
                        "dry_run": Self.booleanSchema("Validate the write without persisting it.", defaultValue: false)
                    ]) { _, new in new },
                    required: ["status"]
                ),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ),
            Tool(
                name: "starcat.create_tag",
                title: "Create Starcat tag",
                description: "Create a user tag. Existing tag names are returned as unchanged. Requires MCP local writes in Starcat Settings.",
                inputSchema: Self.objectSchema([
                    "name": Self.stringSchema("Tag name."),
                    "color": Self.stringSchema("Optional hex color, e.g. #0A84FF."),
                    "icon": Self.stringSchema("Optional SF Symbol name."),
                    "dry_run": Self.booleanSchema("Validate the write without persisting it.", defaultValue: false)
                ], required: ["name"]),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ),
            Tool(
                name: "starcat.add_repo_tags",
                title: "Add repo tags",
                description: "Add one or more tags to a repository. Missing tags are created by default. Requires MCP local writes in Starcat Settings.",
                inputSchema: Self.objectSchema(
                    Self.repoSelectorProperties().merging([
                        "tags": Self.stringArraySchema("Tag names to add."),
                        "create_missing": Self.booleanSchema("Create tags that do not already exist.", defaultValue: true),
                        "dry_run": Self.booleanSchema("Validate the write without persisting it.", defaultValue: false)
                    ]) { _, new in new },
                    required: ["tags"]
                ),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ),
            Tool(
                name: "starcat.remove_repo_tags",
                title: "Remove repo tags",
                description: "Remove one or more tags from a repository. Missing tag names are ignored. Requires MCP local writes in Starcat Settings.",
                inputSchema: Self.objectSchema(
                    Self.repoSelectorProperties().merging([
                        "tags": Self.stringArraySchema("Tag names to remove."),
                        "dry_run": Self.booleanSchema("Validate the write without persisting it.", defaultValue: false)
                    ]) { _, new in new },
                    required: ["tags"]
                ),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            ),
            Tool(
                name: "starcat.set_repo_tags",
                title: "Replace repo tags",
                description: "Replace all tags on a repository with the provided tag list. Requires MCP replace/delete writes in Starcat Settings.",
                inputSchema: Self.objectSchema(
                    Self.repoSelectorProperties().merging([
                        "tags": Self.stringArraySchema("Complete tag names that should remain on the repository."),
                        "create_missing": Self.booleanSchema("Create tags that do not already exist.", defaultValue: true),
                        "dry_run": Self.booleanSchema("Validate the write without persisting it.", defaultValue: false)
                    ]) { _, new in new },
                    required: ["tags"]
                ),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            )
        ]
        guard let allowedToolNames else { return allTools }
        return allTools.filter { allowedToolNames.contains($0.name) }
    }

    private func callTool(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            guard allowedToolNames?.contains(params.name) ?? true else {
                throw StarcatMCPError.unsupported("Tool is not allowed for this Agent: \(params.name)")
            }
            switch params.name {
            case "starcat.get_capabilities":
                return try Self.result(facade.getCapabilities())

            case "starcat.get_overview_statistics":
                return try Self.result(try await facade.getOverviewStatistics())

            case "starcat.get_ai_usage_statistics":
                let filter = try Self.aiUsageFilter(from: params.arguments)
                return try Self.result(try await facade.getAIUsageStatistics(filter: filter))

            case "starcat.get_knowledge_base_statistics":
                return try Self.result(try await facade.getKnowledgeBaseStatistics())

            case "starcat.search_repos":
                let query = params.arguments?["query"]?.stringValue
                let limit = params.arguments?["limit"]?.intValue ?? 20
                let scope = try Self.semanticScope(from: params.arguments)
                let value = try await facade.searchRepos(query: query, limit: limit, scope: scope)
                return try Self.result(value)

            case "starcat.global_search_repos":
                guard let query = params.arguments?["query"]?.stringValue else {
                    throw StarcatMCPError.invalidArguments("Missing required argument: query")
                }
                let limit = params.arguments?["limit"]?.intValue ?? 30
                let sources = try Self.globalSearchSources(from: params.arguments)
                let value = try await facade.globalSearchRepos(
                    query: query,
                    limit: limit,
                    sources: sources
                )
                return try Self.result(value)

            case "starcat.semantic_search":
                guard let query = params.arguments?["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StarcatMCPError.invalidArguments("Missing required argument: query")
                }
                let limit = params.arguments?["limit"]?.intValue ?? 20
                let scope = try Self.semanticScope(from: params.arguments)
                let value = try await facade.semanticSearch(query: query, limit: limit, scope: scope)
                return try Self.result(value)

            case "starcat.get_repo":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await facade.getRepo(repoID: selector.repoID, owner: selector.owner, name: selector.name)
                return try Self.result(value)

            case "starcat.get_repo_context":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await facade.getRepoContext(repoID: selector.repoID, owner: selector.owner, name: selector.name)
                return try Self.result(value)

            case "starcat.get_repo_summary":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await facade.getRepoSummary(repoID: selector.repoID, owner: selector.owner, name: selector.name)
                return try Self.result(value)

            case "starcat.generate_repo_summary":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await facade.generateRepoSummary(
                    repoID: selector.repoID,
                    owner: selector.owner,
                    name: selector.name,
                    allowExternalContext: Self.bool(params.arguments, "allow_external_context", defaultValue: false)
                )
                return try Self.result(value)

            case "starcat.get_readme":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await facade.getReadme(repoID: selector.repoID, owner: selector.owner, name: selector.name)
                return try Self.result(value)

            case "starcat.list_tags":
                let value = try await facade.listTags()
                return try Self.result(value)

            case "starcat.get_repo_note":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await facade.getRepoNote(repoID: selector.repoID, owner: selector.owner, name: selector.name)
                return try Self.result(value)

            case "starcat.upsert_repo_note":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await writeFacade.upsertRepoNote(
                    repoID: selector.repoID,
                    owner: selector.owner,
                    name: selector.name,
                    content: params.arguments?["content"]?.stringValue,
                    dryRun: Self.bool(params.arguments, "dry_run", defaultValue: false)
                )
                return try Self.result(value)

            case "starcat.set_repo_status":
                let selector = Self.repoSelector(from: params.arguments)
                guard let rawStatus = params.arguments?["status"]?.stringValue else {
                    throw StarcatMCPError.invalidArguments("Missing required argument: status")
                }
                guard let status = RepoStatus(rawValue: rawStatus) else {
                    throw StarcatMCPError.invalidArguments("status must be one of: unread, read, using")
                }
                let value = try await writeFacade.setRepoStatus(
                    repoID: selector.repoID,
                    owner: selector.owner,
                    name: selector.name,
                    status: status,
                    dryRun: Self.bool(params.arguments, "dry_run", defaultValue: false)
                )
                return try Self.result(value)

            case "starcat.create_tag":
                guard let name = params.arguments?["name"]?.stringValue else {
                    throw StarcatMCPError.invalidArguments("Missing required argument: name")
                }
                let value = try await writeFacade.createTag(
                    name: name,
                    color: params.arguments?["color"]?.stringValue,
                    icon: params.arguments?["icon"]?.stringValue,
                    dryRun: Self.bool(params.arguments, "dry_run", defaultValue: false)
                )
                return try Self.result(value)

            case "starcat.add_repo_tags":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await writeFacade.addRepoTags(
                    repoID: selector.repoID,
                    owner: selector.owner,
                    name: selector.name,
                    tagNames: try Self.stringArray(params.arguments, "tags"),
                    createMissing: Self.bool(params.arguments, "create_missing", defaultValue: true),
                    dryRun: Self.bool(params.arguments, "dry_run", defaultValue: false)
                )
                return try Self.result(value)

            case "starcat.remove_repo_tags":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await writeFacade.removeRepoTags(
                    repoID: selector.repoID,
                    owner: selector.owner,
                    name: selector.name,
                    tagNames: try Self.stringArray(params.arguments, "tags"),
                    dryRun: Self.bool(params.arguments, "dry_run", defaultValue: false)
                )
                return try Self.result(value)

            case "starcat.set_repo_tags":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await writeFacade.setRepoTags(
                    repoID: selector.repoID,
                    owner: selector.owner,
                    name: selector.name,
                    tagNames: try Self.stringArray(params.arguments, "tags"),
                    createMissing: Self.bool(params.arguments, "create_missing", defaultValue: true),
                    dryRun: Self.bool(params.arguments, "dry_run", defaultValue: false)
                )
                return try Self.result(value)

            default:
                throw StarcatMCPError.unsupported("Unknown tool: \(params.name)")
            }
        } catch {
            return Self.errorResult(error)
        }
    }

    /// 同时返回人类文本与稳定错误 code。
    ///
    /// MCP SDK 把 Tool 业务失败放在 `result.isError`，不是 JSON-RPC 顶层 error；
    /// 因此机器可读 code 必须跟随 `structuredContent` 返回。构造失败时才退化为
    /// 纯文本结果，避免错误处理自身让整次协议调用失败。
    private static func errorResult(_ error: Error) -> CallTool.Result {
        let message = error.localizedDescription
        let payload = MCPToolErrorDTO(code: toolErrorCode(for: error), message: message)
        return (try? .init(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            structuredContent: payload,
            isError: true
        )) ?? .init(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private static func toolErrorCode(for error: Error) -> String {
        if let error = error as? StarcatMCPError {
            switch error {
            case .disabled:
                return "MCP_DISABLED"
            case .requiresPro:
                return "REQUIRES_PRO"
            case .unauthorized:
                return "UNAUTHORIZED"
            case .invalidArguments:
                return "INVALID_ARGUMENTS"
            case .notFound:
                return "NOT_FOUND"
            case .privateNotesDisabled:
                return "PRIVATE_NOTES_DISABLED"
            case .unsupported:
                return "UPGRADE_REQUIRED"
            }
        }
        if let error = error as? GlobalRepositorySearchError {
            switch error {
            case .noSources:
                return "INVALID_ARGUMENTS"
            case .allProvidersFailed:
                return "SEARCH_FAILED"
            }
        }
        if let entitlementError = error as? EntitlementGateError,
           case .requiresPro = entitlementError {
            return "REQUIRES_PRO"
        }
        return "INTERNAL_ERROR"
    }

    private static func result<T: Codable>(_ value: T) throws -> CallTool.Result {
        let text = try prettyJSON(value)
        return try .init(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: value,
            isError: false
        )
    }

    private static func repoSelector(from arguments: [String: Value]?) -> (repoID: Int64?, owner: String?, name: String?) {
        let repoID = arguments?["repo_id"]?.intValue.map(Int64.init)
        let owner = arguments?["owner"]?.stringValue
        let name = arguments?["name"]?.stringValue
        return (repoID, owner, name)
    }

    private static func repoSelectorSchema() -> Value {
        objectSchema(repoSelectorProperties())
    }

    private static func repoSelectorProperties() -> [String: Value] {
        [
            "repo_id": integerSchema("Starcat/GitHub repository id.", minimum: 1),
            "owner": stringSchema("Repository owner, e.g. apple."),
            "name": stringSchema("Repository name, e.g. swift.")
        ]
    }

    private static func semanticScope(from arguments: [String: Value]?) throws -> SemanticIndexScope {
        guard let raw = arguments?["scope"]?.stringValue, !raw.isEmpty else {
            return .starred
        }
        guard let scope = SemanticIndexScope(rawValue: raw) else {
            throw StarcatMCPError.invalidArguments("scope must be one of: starred, knowledge, all")
        }
        return scope
    }

    private static func semanticScopeSchema() -> Value {
        stringSchema(
            "Repository scope. Defaults to starred.",
            enumValues: SemanticIndexScope.allCases.map(\.rawValue)
        )
    }

    private static func globalSearchSources(
        from arguments: [String: Value]?
    ) throws -> Set<GlobalRepositorySearchSource> {
        guard let value = arguments?["sources"] else {
            return Set(GlobalRepositorySearchSource.allCases)
        }
        guard let rawSources = value.arrayValue else {
            throw StarcatMCPError.invalidArguments("sources must be an array of strings")
        }
        let strings = rawSources.compactMap(\.stringValue)
        guard strings.count == rawSources.count, !strings.isEmpty else {
            throw StarcatMCPError.invalidArguments(
                "sources must contain at least one of: local, github"
            )
        }
        let parsed = strings.compactMap(GlobalRepositorySearchSource.init(rawValue:))
        guard parsed.count == strings.count else {
            throw StarcatMCPError.invalidArguments("sources must only contain: local, github")
        }
        return Set(parsed)
    }

    private static func aiUsageFilter(from arguments: [String: Value]?) throws -> AIUsageFilter {
        let rawRange = arguments?["time_range"]?.stringValue ?? AIUsageTimeRange.all.rawValue
        guard let timeRange = AIUsageTimeRange(rawValue: rawRange) else {
            throw StarcatMCPError.invalidArguments(
                "time_range must be one of: \(AIUsageTimeRange.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }

        let feature: AIUsageFeature?
        if let rawFeature = Self.trimmedString(arguments?["feature"]?.stringValue) {
            guard let parsed = AIUsageFeature(rawValue: rawFeature) else {
                throw StarcatMCPError.invalidArguments(
                    "feature must be one of: \(AIUsageFeature.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            feature = parsed
        } else {
            feature = nil
        }

        return AIUsageFilter(
            timeRange: timeRange,
            feature: feature,
            providerID: Self.trimmedString(arguments?["provider_id"]?.stringValue),
            model: Self.trimmedString(arguments?["model"]?.stringValue)
        )
    }

    private static func objectSchema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(Value.string))
        ])
    }

    private static func stringSchema(
        _ description: String,
        enumValues: [String]? = nil,
        defaultValue: String? = nil
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("string"),
            "description": .string(description)
        ]
        if let enumValues {
            schema["enum"] = .array(enumValues.map(Value.string))
        }
        if let defaultValue {
            schema["default"] = .string(defaultValue)
        }
        return .object(schema)
    }

    private static func trimmedString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integerSchema(
        _ description: String,
        defaultValue: Int? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("integer"),
            "description": .string(description)
        ]
        if let defaultValue {
            schema["default"] = .int(defaultValue)
        }
        if let minimum {
            schema["minimum"] = .int(minimum)
        }
        if let maximum {
            schema["maximum"] = .int(maximum)
        }
        return .object(schema)
    }

    private static func booleanSchema(_ description: String, defaultValue: Bool) -> Value {
        .object([
            "type": .string("boolean"),
            "description": .string(description),
            "default": .bool(defaultValue)
        ])
    }

    private static func stringArraySchema(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "type": .string("string")
            ])
        ])
    }

    private static func bool(_ arguments: [String: Value]?, _ key: String, defaultValue: Bool) -> Bool {
        arguments?[key]?.boolValue ?? defaultValue
    }

    private static func stringArray(_ arguments: [String: Value]?, _ key: String) throws -> [String] {
        guard let values = arguments?[key]?.arrayValue else {
            throw StarcatMCPError.invalidArguments("Missing required argument: \(key)")
        }
        let strings = values.compactMap(\.stringValue)
        guard strings.count == values.count else {
            throw StarcatMCPError.invalidArguments("\(key) must be an array of strings")
        }
        return strings
    }

    private static func prettyJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
