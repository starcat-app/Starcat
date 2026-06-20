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

    init(facade: StarcatMCPFacade, writeFacade: StarcatMCPWriteFacade) {
        self.facade = facade
        self.writeFacade = writeFacade
    }

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
            let result = try await self.facade.readResource(uri: params.uri)
            return .init(contents: [
                .text(result.text, uri: params.uri, mimeType: result.mimeType)
            ])
        }
    }

    private var tools: [Tool] {
        [
            Tool(
                name: "starcat.search_repos",
                title: "Search Starcat repositories",
                description: "Search the user's starred repositories cached in Starcat using local keyword/FTS data.",
                inputSchema: Self.objectSchema([
                    "query": .string("Optional keyword query. Empty or omitted returns recent/all starred repositories."),
                    "limit": .int(20)
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "starcat.semantic_search",
                title: "Semantic search Starcat repositories",
                description: "Use Starcat's local embedding index and configured BYOK provider to semantically search starred repositories.",
                inputSchema: Self.objectSchema([
                    "query": .string("Required semantic search query."),
                    "limit": .int(20)
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
                        "content": .string("Markdown note content. Empty string clears the note body."),
                        "dry_run": .bool(false)
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
                        "status": .string("One of: unread, read, using."),
                        "dry_run": .bool(false)
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
                    "name": .string("Tag name."),
                    "color": .string("Optional hex color, e.g. #0A84FF."),
                    "icon": .string("Optional SF Symbol name."),
                    "dry_run": .bool(false)
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
                        "create_missing": .bool(true),
                        "dry_run": .bool(false)
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
                        "dry_run": .bool(false)
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
                        "create_missing": .bool(true),
                        "dry_run": .bool(false)
                    ]) { _, new in new },
                    required: ["tags"]
                ),
                annotations: .init(readOnlyHint: false, openWorldHint: false)
            )
        ]
    }

    private func callTool(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            switch params.name {
            case "starcat.search_repos":
                let query = params.arguments?["query"]?.stringValue
                let limit = params.arguments?["limit"]?.intValue ?? 20
                let value = try await facade.searchRepos(query: query, limit: limit)
                return try Self.result(value)

            case "starcat.semantic_search":
                guard let query = params.arguments?["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StarcatMCPError.invalidArguments("Missing required argument: query")
                }
                let limit = params.arguments?["limit"]?.intValue ?? 20
                let value = try await facade.semanticSearch(query: query, limit: limit)
                return try Self.result(value)

            case "starcat.get_repo":
                let selector = Self.repoSelector(from: params.arguments)
                let value = try await facade.getRepo(repoID: selector.repoID, owner: selector.owner, name: selector.name)
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
                throw StarcatMCPError.invalidArguments("Unknown tool: \(params.name)")
            }
        } catch {
            return .init(
                content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)],
                isError: true
            )
        }
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
            "repo_id": .int(0),
            "owner": .string("Repository owner, e.g. apple"),
            "name": .string("Repository name, e.g. swift")
        ]
    }

    private static func objectSchema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(Value.string))
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
