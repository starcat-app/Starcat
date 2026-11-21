// 让输入校验、会话屏障和零结果都经过 MCP Registry，保留外部客户端依赖的错误码与字段名。
import MCP
import Testing
@testable import Starcat

@MainActor @Suite("标签图谱公共契约边界")
struct TagGraphPublicBoundaryTests {
    @Test("非法参数指出路径，空页、旧协议和重复 ID 保有各自语义")
    func argumentsAndPages() async throws {
        let fixture = try TagGraphFixture(userID: 1)
        try await fixture.seed()
        let reads = StarcatMCPPublicFacade(database: fixture.db, signedInUserID: { 1 })
        let runtime = try await TagGraphPublicReadTests.runtime(fixture, reads: reads)
        defer { Task { await runtime.shutdown() } }
        let invalid: [(String, [String: Any], String)] = [
            ("list_repos_by_tags", ["tag_ids": []], "arguments.tag_ids"),
            ("list_repos_by_tags", ["tag_ids": ["agent", 1]], "arguments.tag_ids[1]"),
            ("list_repos_by_tags", ["tag_ids": [""]], "arguments.tag_ids[0]"),
            ("get_tag_graph", ["min_shared_repos": 0], "unknown argument min_shared_repos"),
            ("get_tag_graph", ["offset": -1], "arguments.offset"),
            ("get_tag_graph", ["limit": 101], "arguments.limit"),
            ("list_repos_by_tags", ["tag_ids": ["rag"], "limit": 0], "arguments.limit")
        ]
        for (tool, arguments, diagnostic) in invalid {
            let result = try await TagGraphPublicReadTests.call(tool, arguments, on: runtime)
            #expect(result["code"] == .string("INVALID_ARGUMENTS"))
            #expect(result["message"]?.stringValue?.contains(diagnostic) == true, "\(tool): \(diagnostic)")
        }
        for (tool, arguments) in [("get_tag_graph", ["offset": Int.max] as [String: Any]),
                                  ("list_repos_by_tags", ["tag_ids": ["agent"], "offset": Int.max])] {
            let result = try await TagGraphPublicReadTests.call(tool, arguments, on: runtime)
            #expect(result["next_offset"] == .null && result["has_more"] == .bool(false))
            #expect(result["network_used"] == .bool(false))
            #expect((result["edges"] ?? result["items"]) == .array([]))
        }
        let legacy = try await TagGraphPublicReadTests.call("list_repos_by_tag", ["tag": "Agent", "limit": 1], on: runtime)
        #expect(legacy["tag"]?.objectValue?["name"] == .string("Agent"))
        #expect(legacy["repos"]?.arrayValue?.count == 1 && legacy["items"] == nil)
        try await fixture.tags.delete(id: "rag")
        let deleted = try await TagGraphPublicReadTests.call("list_repos_by_tags", ["tag_ids": ["agent", "rag"]], on: runtime)
        #expect(deleted["total"] == .int(0) && deleted["items"] == .array([]))
    }

    @Test("本地图谱可读，未解锁公共服务时不会开启监听")
    func serviceRequiresPro() async throws {
        let fixture = try TagGraphFixture(userID: 1)
        try await fixture.seed()
        let parts = try await StarcatMCPRuntimeTests.makeFacades(allowWrites: false, database: fixture.db,
            publicCapabilities: .init(database: fixture.db, signedInUserID: { 1 }), isPro: false)
        let service = StarcatMCPService(settings: parts.settings, entitlementGate: parts.gate,
            localAPIKeyStore: .init(keychain: parts.keychain), deviceStore: .init(keychain: parts.keychain),
            facade: parts.facade, writeFacade: parts.writeFacade)
        parts.settings.mcpServiceEnabled = true
        service.refreshForCurrentSettings()
        #expect(service.state == .failed(String.l10n("settings.mcp.status.requiresPro")))
        #expect(try await fixture.snapshot().edges.count == 7)
    }

    @Test("登出、切库屏障和从上一账户带来的 ID 不返回旧数据")
    func accountChanges() async throws {
        final class Identity { var id: Int64? = 1 }
        let identity = Identity(), fixture = try TagGraphFixture(userID: 1)
        try await fixture.seed()
        let reads = StarcatMCPPublicFacade(database: fixture.db, signedInUserID: { identity.id })
        let runtime = try await TagGraphPublicReadTests.runtime(fixture, reads: reads)
        defer { Task { await runtime.shutdown() } }
        identity.id = nil
        let logout = try await TagGraphPublicReadTests.call("get_tag_graph", [:], on: runtime)
        #expect(logout["code"] == .string("AUTH_REQUIRED") && logout["nodes"] == nil)
        identity.id = 2
        let mismatch = try await TagGraphPublicReadTests.call("get_tag_graph", [:], on: runtime)
        #expect(mismatch["code"] == .string("SESSION_CHANGING"))
        await reads.prepareForAccountChange()
        try await fixture.db.reopen(userId: 2)
        let changing = try await TagGraphPublicReadTests.call("list_repos_by_tags", ["tag_ids": ["rag"]], on: runtime)
        #expect(changing["code"] == .string("SESSION_CHANGING"))
        reads.finishAccountChange(succeeded: true)
        let crossAccount = try await TagGraphPublicReadTests.call("list_repos_by_tags", ["tag_ids": ["rag"]], on: runtime)
        #expect(crossAccount["total"] == .int(0) && crossAccount["network_used"] == .bool(false))
    }
}
