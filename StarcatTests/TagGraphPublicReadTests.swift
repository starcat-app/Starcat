// 经 MCP 的真实 Registry 和执行器核对图谱，避免协议层的计数与原生图谱脱节。
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

    @Test("公共响应与画布及仓库检查器的同一固定样例逐项相符")
    func applicationParity() async throws {
        let fixture = try TagGraphFixture(userID: 1)
        try await fixture.seed()
        let reads = StarcatMCPPublicFacade(database: fixture.db, signedInUserID: { 1 })
        let runtime = try await Self.runtime(fixture, reads: reads)
        defer { Task { await runtime.shutdown() } }
        let expected = try await fixture.snapshot()
        let first = try await Self.call("get_tag_graph", ["limit": 1], on: runtime)
        let remainder = try await Self.call("get_tag_graph", ["offset": 1], on: runtime)
        let nodes = try StarcatMCPJSON.value(expected.nodes)
        #expect(first["nodes"] == nodes && remainder["nodes"] == nodes)
        #expect(first["total_edges"] == .int(3) && first["matching_edges"] == .int(3))
        #expect(first["next_offset"] == .int(1) && remainder["next_offset"] == .null)
        let combined = (first["edges"]?.arrayValue ?? []) + (remainder["edges"]?.arrayValue ?? [])
        #expect(try Value.array(combined) == StarcatMCPJSON.value(expected.edges))
        let filtered = try await Self.call("get_tag_graph", ["min_shared_repos": 2], on: runtime)
        #expect(filtered["nodes"] == nodes && filtered["matching_edges"] == .int(1) && filtered["total_edges"] == .int(3))
        for offset in 0...1 {
            let ids = ["rag", "agent", "rag"]
            let actual = try await Self.call("list_repos_by_tags", ["tag_ids": ids, "limit": 1, "offset": offset], on: runtime)
            let gui = try await fixture.db.writer.read { try RepoTagIntersection.page(in: $0, tagIDs: Set(ids), limit: 1, offset: offset) }
            #expect(actual["total"] == .int(gui.total))
            #expect(actual["items"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.intValue } == gui.items.map { Int($0.id) })
            #expect(actual["next_offset"] == (offset == 0 ? .int(1) : .null))
        }
    }
}
