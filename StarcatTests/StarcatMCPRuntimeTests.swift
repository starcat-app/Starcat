//
//  StarcatMCPRuntimeTests.swift
//  StarcatTests
//
//  MCP 协议运行时回归测试。
//
//  这组测试覆盖的是之前漏掉的 HTTP/MCP 会话层，而不是业务 facade 本身：
//  - registry 必须跟随 SDK Server 会话存活，tools/list 不能退化为空；
//  - tools/call 必须能进入真实 facade，不应返回 registry unavailable；
//  - Claude 重新 initialize 时，Starcat 需要重建 SDK 会话，不能复用已初始化的 Server。
//

import Foundation
import MCP
import Testing
@testable import Starcat

@MainActor
@Suite("StarcatMCPRuntime")
struct StarcatMCPRuntimeTests {

    @Test("initialize 后 tools/list 返回完整工具列表且 tools/call 可用")
    func listsAndCallsToolsAfterInitialize() async throws {
        let runtime = try await Self.makeRuntime()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let initialize = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))
        #expect(initialize.statusCode == 200)

        let initialized = await runtime.handle(Self.notification(method: "notifications/initialized"))
        #expect(initialized.statusCode == 202)

        let list = await runtime.handle(Self.request(id: 2, method: "tools/list"))
        let listJSON = try Self.jsonObject(from: list)
        let tools = try #require((listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == 20)
        #expect(tools.contains { $0["name"] as? String == "starcat.get_capabilities" })
        #expect(tools.contains { $0["name"] as? String == "starcat.get_overview_statistics" })
        #expect(tools.contains { $0["name"] as? String == "starcat.get_ai_usage_statistics" })
        #expect(tools.contains { $0["name"] as? String == "starcat.get_knowledge_base_statistics" })
        #expect(tools.contains { $0["name"] as? String == "starcat.get_repo_context" })
        #expect(tools.contains { $0["name"] as? String == "starcat.get_repo_summary" })
        #expect(tools.contains { $0["name"] as? String == "starcat.generate_repo_summary" })
        #expect(tools.contains { $0["name"] as? String == "starcat.search_repos" })
        #expect(tools.contains { $0["name"] as? String == "starcat.semantic_search" })
        #expect(tools.contains { $0["name"] as? String == "starcat.global_search_repos" })
        // knowledge.search 当前只完成内部共享 capability；不能在没有独立 MCP 契约评审时
        // 偷偷扩张已发布的公共 tool catalog。
        #expect(tools.contains { $0["name"] as? String == "starcat.search_knowledge" } == false)
        let searchTool = try #require(tools.first { $0["name"] as? String == "starcat.search_repos" })
        let inputSchema = try #require(searchTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let querySchema = try #require(properties["query"] as? [String: Any])
        let scopeSchema = try #require(properties["scope"] as? [String: Any])
        let limitSchema = try #require(properties["limit"] as? [String: Any])
        #expect(querySchema["type"] as? String == "string")
        #expect(scopeSchema["type"] as? String == "string")
        #expect(scopeSchema["enum"] as? [String] == ["starred", "knowledge", "all"])
        #expect(limitSchema["type"] as? String == "integer")
        #expect(limitSchema["default"] as? Int == 20)

        let generateTool = try #require(tools.first { $0["name"] as? String == "starcat.generate_repo_summary" })
        let generateSchema = try #require(generateTool["inputSchema"] as? [String: Any])
        let generateProperties = try #require(generateSchema["properties"] as? [String: Any])
        let externalContextSchema = try #require(generateProperties["allow_external_context"] as? [String: Any])
        #expect(externalContextSchema["type"] as? String == "boolean")
        #expect(externalContextSchema["default"] as? Bool == false)

        let usageTool = try #require(tools.first { $0["name"] as? String == "starcat.get_ai_usage_statistics" })
        let usageSchema = try #require(usageTool["inputSchema"] as? [String: Any])
        let usageProperties = try #require(usageSchema["properties"] as? [String: Any])
        let timeRangeSchema = try #require(usageProperties["time_range"] as? [String: Any])
        #expect(timeRangeSchema["enum"] as? [String] == ["today", "seven_days", "thirty_days", "all"])
        #expect(timeRangeSchema["default"] as? String == "all")

        let call = await runtime.handle(Self.request(
            id: 3,
            method: "tools/call",
            params: [
                "name": "starcat.search_repos",
                "arguments": ["limit": 1]
            ]
        ))
        let callJSON = try Self.jsonObject(from: call)
        let result = try #require(callJSON["result"] as? [String: Any])
        #expect(result["isError"] as? Bool != true)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["total"] as? Int == 1)

        let knowledgeSearchCall = await runtime.handle(Self.request(
            id: 4,
            method: "tools/call",
            params: [
                "name": "starcat.search_repos",
                "arguments": ["query": "codex", "scope": "knowledge", "limit": 5]
            ]
        ))
        let knowledgeJSON = try Self.jsonObject(from: knowledgeSearchCall)
        let knowledgeResult = try #require(knowledgeJSON["result"] as? [String: Any])
        #expect(knowledgeResult["isError"] as? Bool != true)
        let knowledgeStructured = try #require(knowledgeResult["structuredContent"] as? [String: Any])
        let repos = try #require(knowledgeStructured["repos"] as? [[String: Any]])
        #expect(knowledgeStructured["total"] as? Int == 1)
        #expect(repos.first?["full_name"] as? String == "openai/codex")

        let getRepoCall = await runtime.handle(Self.request(
            id: 28,
            method: "tools/call",
            params: [
                "name": "starcat.get_repo",
                "arguments": ["owner": "apple", "name": "swift"]
            ]
        ))
        let getRepoJSON = try Self.jsonObject(from: getRepoCall)
        let getRepoResult = try #require(getRepoJSON["result"] as? [String: Any])
        #expect(getRepoResult["isError"] as? Bool != true)
        let getRepo = try #require(getRepoResult["structuredContent"] as? [String: Any])
        #expect(getRepo["full_name"] as? String == "apple/swift")
        #expect(getRepo["owner"] as? String == "apple")
        #expect(getRepo["name"] as? String == "swift")

        let capabilitiesCall = await runtime.handle(Self.request(
            id: 20,
            method: "tools/call",
            params: ["name": "starcat.get_capabilities", "arguments": [:]]
        ))
        let capabilitiesJSON = try Self.jsonObject(from: capabilitiesCall)
        let capabilitiesResult = try #require(capabilitiesJSON["result"] as? [String: Any])
        let capabilities = try #require(capabilitiesResult["structuredContent"] as? [String: Any])
        #expect(capabilities["private_notes_read"] as? Bool == true)
        #expect(capabilities["statistics_read"] as? Bool == true)
        #expect(capabilities["local_writes"] as? Bool == true)
        #expect(capabilities["loopback_only"] as? Bool == true)

        let contextCall = await runtime.handle(Self.request(
            id: 21,
            method: "tools/call",
            params: [
                "name": "starcat.get_repo_context",
                "arguments": ["owner": "apple", "name": "swift"]
            ]
        ))
        let contextJSON = try Self.jsonObject(from: contextCall)
        let contextResult = try #require(contextJSON["result"] as? [String: Any])
        let context = try #require(contextResult["structuredContent"] as? [String: Any])
        let contextRepo = try #require(context["repo"] as? [String: Any])
        #expect(contextRepo["full_name"] as? String == "apple/swift")
        #expect(context["private_notes_exposed"] as? Bool == true)

        let overviewCall = await runtime.handle(Self.request(
            id: 22,
            method: "tools/call",
            params: ["name": "starcat.get_overview_statistics", "arguments": [:]]
        ))
        let overviewJSON = try Self.jsonObject(from: overviewCall)
        let overviewResult = try #require(overviewJSON["result"] as? [String: Any])
        let overview = try #require(overviewResult["structuredContent"] as? [String: Any])
        #expect(overview["starred_repository_count"] as? Int == 1)
        #expect(overview["knowledge_base_project_count"] as? Int == 1)
        let overviewUsage = try #require(overview["ai_usage"] as? [String: Any])
        #expect(overviewUsage["total_tokens"] as? Int == 42)
        let overviewIndex = try #require(overview["rag_index"] as? [String: Any])
        #expect(overviewIndex["total_chunks"] as? Int == 1)
        #expect(overviewIndex["pending_chunks"] as? Int == 1)

        let usageCall = await runtime.handle(Self.request(
            id: 23,
            method: "tools/call",
            params: [
                "name": "starcat.get_ai_usage_statistics",
                "arguments": ["time_range": "all", "provider_id": "test-provider"]
            ]
        ))
        let usageJSON = try Self.jsonObject(from: usageCall)
        let usageResult = try #require(usageJSON["result"] as? [String: Any])
        let usage = try #require(usageResult["structuredContent"] as? [String: Any])
        let usageSummary = try #require(usage["summary"] as? [String: Any])
        #expect(usageSummary["total_tokens"] as? Int == 42)
        let providers = try #require(usage["by_provider"] as? [[String: Any]])
        #expect(providers.first?["key"] as? String == "test-provider")

        let invalidUsageCall = await runtime.handle(Self.request(
            id: 25,
            method: "tools/call",
            params: [
                "name": "starcat.get_ai_usage_statistics",
                "arguments": ["time_range": "yesterday"]
            ]
        ))
        let invalidUsageJSON = try Self.jsonObject(from: invalidUsageCall)
        let invalidUsageResult = try #require(invalidUsageJSON["result"] as? [String: Any])
        #expect(invalidUsageResult["isError"] as? Bool == true)

        let invalidGlobalSearchCall = await runtime.handle(Self.request(
            id: 26,
            method: "tools/call",
            params: [
                "name": "starcat.global_search_repos",
                "arguments": ["query": "swift", "limit": 51]
            ]
        ))
        let invalidGlobalSearchJSON = try Self.jsonObject(from: invalidGlobalSearchCall)
        let invalidGlobalSearchResult = try #require(invalidGlobalSearchJSON["result"] as? [String: Any])
        #expect(invalidGlobalSearchResult["isError"] as? Bool == true)
        let structuredError = try #require(invalidGlobalSearchResult["structuredContent"] as? [String: Any])
        #expect(structuredError["schema_version"] as? Int == 1)
        #expect(structuredError["code"] as? String == "INVALID_ARGUMENTS")
        #expect(structuredError["message"] as? String == "limit must be between 1 and 50")

        let unsupportedToolCall = await runtime.handle(Self.request(
            id: 27,
            method: "tools/call",
            params: ["name": "starcat.future_tool", "arguments": [:]]
        ))
        let unsupportedToolJSON = try Self.jsonObject(from: unsupportedToolCall)
        let unsupportedToolResult = try #require(unsupportedToolJSON["result"] as? [String: Any])
        let unsupportedError = try #require(unsupportedToolResult["structuredContent"] as? [String: Any])
        #expect(unsupportedError["code"] as? String == "UPGRADE_REQUIRED")

        let knowledgeStatisticsCall = await runtime.handle(Self.request(
            id: 24,
            method: "tools/call",
            params: ["name": "starcat.get_knowledge_base_statistics", "arguments": [:]]
        ))
        let knowledgeStatsJSON = try Self.jsonObject(from: knowledgeStatisticsCall)
        let knowledgeStatsResult = try #require(knowledgeStatsJSON["result"] as? [String: Any])
        let knowledgeStats = try #require(knowledgeStatsResult["structuredContent"] as? [String: Any])
        #expect(knowledgeStats["project_count"] as? Int == 1)
        #expect(knowledgeStats["retained_after_unstar_count"] as? Int == 1)
        #expect(knowledgeStats["private_notes_exposed"] as? Bool == true)

        let resourcesList = await runtime.handle(Self.request(id: 5, method: "resources/list"))
        let resourcesJSON = try Self.jsonObject(from: resourcesList)
        let resources = try #require((resourcesJSON["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        let uris = Set(resources.compactMap { $0["uri"] as? String })
        #expect(uris.contains("starcat://repos/starred/apple/swift"))
        #expect(uris.contains("starcat://repos/knowledge/openai/codex"))
        #expect(uris.contains("starcat://repos/all/openai/codex"))
    }

    @Test("重复 initialize 会重建 SDK 会话，不返回 Server is already initialized")
    func repeatedInitializeRecreatesSession() async throws {
        let runtime = try await Self.makeRuntime()
        defer { Task { @MainActor in await runtime.shutdown() } }

        let first = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))
        #expect(first.statusCode == 200)

        let second = await runtime.handle(Self.request(id: 2, method: "initialize", params: Self.initializeParams()))
        #expect(second.statusCode == 200)
        let secondJSON = try Self.jsonObject(from: second)
        #expect(secondJSON["error"] == nil)
        #expect((secondJSON["result"] as? [String: Any])?["serverInfo"] != nil)

        let list = await runtime.handle(Self.request(id: 3, method: "tools/list"))
        let listJSON = try Self.jsonObject(from: list)
        let tools = try #require((listJSON["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        #expect(tools.count == 20)
    }

    @Test("关闭私有笔记读取后知识库统计不返回笔记数量")
    func knowledgeStatisticsRespectPrivateNotesCapability() async throws {
        let runtime = try await Self.makeRuntime(exposePrivateNotes: false)
        defer { Task { @MainActor in await runtime.shutdown() } }

        _ = await runtime.handle(Self.request(id: 1, method: "initialize", params: Self.initializeParams()))
        let call = await runtime.handle(Self.request(
            id: 2,
            method: "tools/call",
            params: ["name": "starcat.get_knowledge_base_statistics", "arguments": [:]]
        ))
        let json = try Self.jsonObject(from: call)
        let result = try #require(json["result"] as? [String: Any])
        let statistics = try #require(result["structuredContent"] as? [String: Any])

        #expect(statistics["private_notes_exposed"] as? Bool == false)
        #expect(statistics["private_note_project_count"] == nil)
        #expect(statistics["ai_generated_note_project_count"] == nil)
        #expect(statistics["private_notes_edited_in_last_30_days_project_count"] == nil)
    }

    @Test("可信网络 hostname 可访问，未授权 Host 仍返回 421")
    func validatesConfiguredRemoteHost() async throws {
        let port = 5_555
        let runtime = try await Self.makeRuntime(originValidator: OriginValidator(
            allowedHosts: [
                "127.0.0.1:\(port)",
                "localhost:\(port)",
                "[::1]:\(port)",
                "studio.local:\(port)"
            ],
            allowedOrigins: ["https://studio.local:\(port)"]
        ))
        defer { Task { @MainActor in await runtime.shutdown() } }

        let allowed = await runtime.handle(Self.request(
            id: 1,
            method: "initialize",
            params: Self.initializeParams(),
            host: "studio.local:\(port)"
        ))
        #expect(allowed.statusCode == 200)

        let rejected = await runtime.handle(Self.request(
            id: 2,
            method: "initialize",
            params: Self.initializeParams(),
            host: "attacker.example:\(port)"
        ))
        #expect(rejected.statusCode == 421)
        let body = try #require(rejected.bodyData.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("Host header not allowed"))
    }

    private static func makeRuntime(
        originValidator: OriginValidator = .localhost(),
        exposePrivateNotes: Bool = true
    ) async throws -> StarcatMCPRuntime {
        let db = try InMemoryDatabaseManager()
        try await db.insertRepoFixture(id: 1, owner: "apple", name: "swift")
        try await db.insertRepoFixture(id: 2, owner: "openai", name: "codex")
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE repos SET is_starred = 0, starred_at = NULL WHERE id = 2")
        }

        let settings = AppSettings(defaults: UserDefaults(suiteName: "test.starcat.mcp.runtime.\(UUID().uuidString)")!)
        settings.mcpExposePrivateNotes = exposePrivateNotes
        settings.mcpAllowLocalWrites = true

        let gate = EntitlementGate(
            entitlementProvider: MCPRuntimeTestEntitlementProvider(isPro: true),
            userIDProvider: { 1 }
        )
        let repoRepository = GRDBRepoRepository(database: db)
        let tagRepository = GRDBTagRepository(database: db)
        let repoTagRepository = GRDBRepoTagRepository(database: db)
        let noteRepository = GRDBRepoNoteRepository(database: db)
        try await noteRepository.updateLibraryState(repoId: 2, state: .inLibrary)
        try await db.writer.write { database in
            try database.execute(sql: """
                INSERT INTO rag_chunks (
                    repo_id, source, source_id, parent_type, parent_key, parent_title, chunk_key,
                    chunk_index, section_path, title, content, content_hash, token_count, is_truncated,
                    embedding_model, embedding_status, created_at, updated_at
                ) VALUES (
                    2, 'readme', '', 'readme', 'readme', 'README', 'readme:0',
                    0, '', 'README', 'pending content', 'mcp-pending', 2, 0,
                    NULL, 'pending', datetime('now'), datetime('now')
                )
                """)
        }
        try await GRDBAIUsageRepository(database: db).insert(AIUsageEvent(
            id: "mcp-test-usage",
            startedAt: 1,
            completedAt: 2,
            durationMs: 1_000,
            providerId: "test-provider",
            providerKind: "openAICompatible",
            model: "test-model",
            feature: AIUsageFeature.mcp.rawValue,
            phase: "statistics_test",
            operation: AIUsageOperation.chat.rawValue,
            inputTokens: 30,
            outputTokens: 12,
            totalTokens: 42,
            cachedInputTokens: nil,
            reasoningOutputTokens: nil,
            itemCount: 1,
            usageSource: AIUsageSource.provider.rawValue,
            status: AIUsageStatus.succeeded.rawValue,
            errorCategory: nil,
            correlationId: nil
        ))
        let readmeRepository = ReadmeRepository(database: db)
        let summaryRepository = GRDBAISummaryRepository(database: db)
        let testKeychain = InMemoryKeychain()
        let semanticSearch = SemanticSearchService(
            embeddingRepository: GRDBRepoEmbeddingRepository(database: db),
            settings: settings,
            readmeRepository: readmeRepository,
            noteRepository: noteRepository,
            summaryRepository: summaryRepository,
            entitlementGate: gate,
            keychain: testKeychain
        )
        let insightService = RepoAIInsightService(
            summaryRepository: summaryRepository,
            readmeRepository: readmeRepository,
            settings: settings,
            keychain: testKeychain,
            entitlementGate: gate
        )
        let facade = StarcatMCPFacade(
            repoRepository: repoRepository,
            readmeRepository: readmeRepository,
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository,
            repoNoteRepository: noteRepository,
            semanticSearchService: semanticSearch,
            repoAIInsightService: insightService,
            database: db,
            aiUsageRepository: GRDBAIUsageRepository(database: db),
            knowledgeBaseMetadataSnapshotCache: KnowledgeBaseMetadataSnapshotCache(),
            entitlementGate: gate,
            settings: settings
        )
        let writeFacade = StarcatMCPWriteFacade(
            repoRepository: repoRepository,
            metadataCapability: RepositoryMetadataCapabilityExecutor(
                source: DatabaseRepositoryMetadataCapabilitySource(
                    repoRepository: repoRepository,
                    repoNoteRepository: noteRepository
                )
            ),
            tagCapability: RepositoryTagCapabilityExecutor(
                source: DatabaseRepositoryTagCapabilitySource(
                    repoRepository: repoRepository,
                    tagRepository: GatedTagRepository(base: tagRepository, entitlementGate: gate),
                    repoTagRepository: repoTagRepository
                )
            ),
            settings: settings,
            entitlementGate: gate,
            auditLog: StarcatMCPAuditLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("starcat-mcp-runtime-\(UUID().uuidString).jsonl"))
        )
        let runtime = StarcatMCPRuntime(
            facade: facade,
            writeFacade: writeFacade,
            originValidator: originValidator
        )
        try await runtime.start()
        return runtime
    }

    private static func initializeParams() -> [String: Any] {
        [
            "protocolVersion": "2025-03-26",
            "capabilities": [:],
            "clientInfo": [
                "name": "StarcatRuntimeTests",
                "version": "1.0"
            ]
        ]
    }

    private static func request(
        id: Int,
        method: String,
        params: [String: Any]? = nil,
        host: String? = nil
    ) -> HTTPRequest {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            object["params"] = params
        }
        return httpRequest(object, host: host)
    }

    private static func notification(method: String, params: [String: Any]? = nil) -> HTTPRequest {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if let params {
            object["params"] = params
        }
        return httpRequest(object)
    }

    private static func httpRequest(_ object: [String: Any], host: String? = nil) -> HTTPRequest {
        let body = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var headers = [
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
            "MCP-Protocol-Version": "2025-03-26"
        ]
        if let host {
            headers["Host"] = host
        }
        return HTTPRequest(
            method: "POST",
            headers: headers,
            body: body,
            path: "/mcp"
        )
    }

    private static func jsonObject(from response: HTTPResponse) throws -> [String: Any] {
        #expect(response.statusCode == 200)
        let body = try #require(response.bodyData)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}

@MainActor
private final class MCPRuntimeTestEntitlementProvider: ProEntitlementProviding {
    let entitlement: ProEntitlement

    init(isPro: Bool) {
        self.entitlement = ProEntitlement(
            isActive: isPro,
            productID: isPro ? "test.pro" : nil,
            expirationDate: nil,
            verifiedAt: Date(),
            source: isPro ? .testEnvironment : .none
        )
    }
}
