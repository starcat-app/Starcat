// 经 MCP 的真实 Registry 和执行器核对图谱，避免协议层的节点与原生图谱脱节。
import Foundation
import MCP
import Testing
@testable import Starcat

@MainActor @Suite("标签图谱公共读取")
struct TagGraphPublicReadTests {
    static let names: Set<String> = ["starcat.get_tag_graph", "starcat.list_repos_by_tags", "starcat.list_repos_by_tag"]

    /// 初始化标准会话，使测试经过同一套工具发现、权限和 Schema 校验。
    static func runtime(_ fixture: TagGraphFixture, reads: StarcatMCPPublicFacade) async throws -> StarcatMCPRuntime {
        let runtime = try await StarcatMCPRuntimeTests.makeRuntime(allowedToolNames: names, allowWrites: false,
            database: fixture.db, publicCapabilities: reads)
        _ = await runtime.handle(StarcatMCPRuntimeTests.request(id: 1, method: "initialize", params: StarcatMCPRuntimeTests.initializeParams()))
        _ = await runtime.handle(StarcatMCPRuntimeTests.notification(method: "notifications/initialized"))
        return runtime
    }

    /// 同时读取成功和业务错误的结构化结果，便于核对错误码与参数路径。
    static func call(_ name: String, _ arguments: [String: Any], on runtime: StarcatMCPRuntime) async throws -> [String: Value] {
        let response = await runtime.handle(StarcatMCPRuntimeTests.request(id: 2, method: "tools/call",
            params: ["name": "starcat." + name, "arguments": arguments]))
        let json = try JSONDecoder().decode(Value.self, from: #require(response.bodyData))
        return try #require(json.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue)
    }

    @Test("公共响应按边分页携带仓库节点，标签节点始终完整")
    func applicationParity() async throws {
        let fixture = try TagGraphFixture(userID: 1)
        try await fixture.seed()
        let reads = StarcatMCPPublicFacade(database: fixture.db, signedInUserID: { 1 })
        let runtime = try await Self.runtime(fixture, reads: reads)
        defer { Task { await runtime.shutdown() } }
        let expected = try await fixture.snapshot()
        var combinedEdges = [Value]()
        for (offset, edgeCount) in [(0, 3), (3, 3), (6, 1)] {
            let actual = try await Self.call("get_tag_graph", ["limit": 3, "offset": offset], on: runtime)
            let pageEdges = Array(expected.edges[offset..<(offset + edgeCount)])
            let pageRepoIDs = Set(pageEdges.map(\.target))
            let pageNodes = expected.nodes.filter { $0.kind == .tag || pageRepoIDs.contains($0.id) }
            #expect(try actual["nodes"] == StarcatMCPJSON.value(pageNodes))
            #expect(try actual["edges"] == StarcatMCPJSON.value(pageEdges))
            #expect(actual["total_nodes"] == .int(expected.nodes.count))
            #expect(actual["total_edges"] == .int(expected.edges.count))
            #expect(actual["matching_edges"] == nil)
            #expect(actual["next_offset"] == (offset == 6 ? .null : .int(offset + 3)))
            combinedEdges += try #require(actual["edges"]?.arrayValue)
        }
        #expect(try Value.array(combinedEdges) == StarcatMCPJSON.value(expected.edges))

        for offset in 0...1 {
            let ids = ["rag", "agent", "rag"]
            let actual = try await Self.call("list_repos_by_tags", ["tag_ids": ids, "limit": 1, "offset": offset], on: runtime)
            #expect(actual["total"] == .int(2))
            #expect(actual["items"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.intValue } == [offset + 1])
            #expect(actual["next_offset"] == (offset == 0 ? .int(1) : .null))
        }
    }
}
