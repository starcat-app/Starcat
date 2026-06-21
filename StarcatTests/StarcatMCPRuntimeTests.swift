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
        #expect(tools.count == 12)
        #expect(tools.contains { $0["name"] as? String == "starcat.search_repos" })
        let searchTool = try #require(tools.first { $0["name"] as? String == "starcat.search_repos" })
        let inputSchema = try #require(searchTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let querySchema = try #require(properties["query"] as? [String: Any])
        let limitSchema = try #require(properties["limit"] as? [String: Any])
        #expect(querySchema["type"] as? String == "string")
        #expect(limitSchema["type"] as? String == "integer")
        #expect(limitSchema["default"] as? Int == 20)

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
        #expect(tools.count == 12)
    }

    private static func makeRuntime() async throws -> StarcatMCPRuntime {
        let db = try InMemoryDatabaseManager()
        try await db.insertRepoFixture(id: 1, owner: "apple", name: "swift")

        let settings = AppSettings(defaults: UserDefaults(suiteName: "test.starcat.mcp.runtime.\(UUID().uuidString)")!)
        settings.mcpExposePrivateNotes = true
        settings.mcpAllowLocalWrites = true

        let gate = EntitlementGate(
            entitlementProvider: MCPRuntimeTestEntitlementProvider(isPro: true),
            userIDProvider: { 1 }
        )
        let repoRepository = GRDBRepoRepository(database: db)
        let tagRepository = GRDBTagRepository(database: db)
        let repoTagRepository = GRDBRepoTagRepository(database: db)
        let noteRepository = GRDBRepoNoteRepository(database: db)
        let readmeRepository = ReadmeRepository(database: db)
        let semanticSearch = SemanticSearchService(
            embeddingRepository: GRDBRepoEmbeddingRepository(database: db),
            settings: settings,
            readmeRepository: readmeRepository,
            noteRepository: noteRepository,
            summaryRepository: GRDBAISummaryRepository(database: db),
            entitlementGate: gate,
            keychain: InMemoryKeychain()
        )
        let facade = StarcatMCPFacade(
            repoRepository: repoRepository,
            readmeRepository: readmeRepository,
            tagRepository: tagRepository,
            repoTagRepository: repoTagRepository,
            repoNoteRepository: noteRepository,
            semanticSearchService: semanticSearch,
            settings: settings
        )
        let writeFacade = StarcatMCPWriteFacade(
            repoRepository: repoRepository,
            tagRepository: GatedTagRepository(base: tagRepository, entitlementGate: gate),
            repoTagRepository: repoTagRepository,
            repoNoteRepository: noteRepository,
            settings: settings,
            entitlementGate: gate,
            auditLog: StarcatMCPAuditLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("starcat-mcp-runtime-\(UUID().uuidString).jsonl")),
            refreshSemanticIndex: { _ in }
        )
        let runtime = StarcatMCPRuntime(facade: facade, writeFacade: writeFacade)
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

    private static func request(id: Int, method: String, params: [String: Any]? = nil) -> HTTPRequest {
        var object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            object["params"] = params
        }
        return httpRequest(object)
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

    private static func httpRequest(_ object: [String: Any]) -> HTTPRequest {
        let body = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return HTTPRequest(
            method: "POST",
            headers: [
                "Accept": "application/json, text/event-stream",
                "Content-Type": "application/json",
                "MCP-Protocol-Version": "2025-03-26"
            ],
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
