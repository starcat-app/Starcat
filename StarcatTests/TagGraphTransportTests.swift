// 用独立 CLI 进程和真正的 MCP loopback 服务核对固定样例。通用 CLI 和 stdio 都要自行发现/调用 App 契约。
import Foundation
import MCP
import Testing
@testable import Starcat

@MainActor @Suite("标签图谱跨进程读取")
struct TagGraphTransportTests {
    nonisolated static let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/tag-graph-cli-fixture")

    /// scripts/tests/test-tag-graph-cli.sh 预编译 Go 入口，普通 Swift 单测不要求安装配套 CLI 工具链。
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: binary.path)))
    func realCLIAndStdio() async throws {
        let fixture = try TagGraphFixture(userID: 1)
        try await fixture.seed()
        let reads = StarcatMCPPublicFacade(database: fixture.db, signedInUserID: { 1 })
        let runtime = try await TagGraphPublicReadTests.runtime(fixture, reads: reads)
        let token = UUID().uuidString
        let server = StarcatMCPLoopbackHTTPServer(port: 0, runtime: runtime) { request in
            request.path == "/mcp" && request.header("Authorization") == "Bearer \(token)" ? nil : .unauthorized
        }
        let port = try await server.startAndWaitUntilReady()
        defer { server.stop(); Task { await runtime.shutdown() } }
        let expected = try await fixture.snapshot()
        let nodes = try StarcatMCPJSON.value(expected.nodes)
        let edges = try StarcatMCPJSON.value(expected.edges)
        for stdio in [false, true] {
            var allEdges = [Value](), repoIDs = [Int]()
            for offset in 0...1 {
                let graph = try await Self.call("get_tag_graph", ["limit": 2, "offset": offset * 2], stdio: stdio, port: port, token: token)
                #expect(graph["nodes"] == nodes && graph["total_edges"] == .int(3) && graph["matching_edges"] == .int(3))
                #expect(graph["next_offset"] == (offset == 0 ? .int(2) : .null))
                allEdges += try #require(graph["edges"]?.arrayValue)
                let repos = try await Self.call("list_repos_by_tags", ["tag_ids": ["agent", "rag"], "limit": 1, "offset": offset], stdio: stdio, port: port, token: token)
                #expect(repos["total"] == .int(2) && repos["next_offset"] == (offset == 0 ? .int(1) : .null))
                repoIDs += try #require(repos["items"]?.arrayValue).compactMap { $0.objectValue?["id"]?.intValue }
            }
            #expect(.array(allEdges) == edges)
            let gui = try await fixture.db.writer.read { try RepoTagIntersection.page(in: $0, tagIDs: ["agent", "rag"], limit: 20, offset: 0) }
            #expect(repoIDs == gui.items.map { Int($0.id) })
        }
    }

    /// 将 stdin 送到子进程，在主线程外排空 stdout，使 NWListener 能继续处理来自 CLI 的回环请求。
    private static func call(_ name: String, _ arguments: [String: Any], stdio: Bool, port: Int, token: String) async throws -> [String: Value] {
        let name = "starcat." + name
        let input: Data
        if stdio {
            let messages: [[String: Any]] = [
                ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": StarcatMCPRuntimeTests.initializeParams()],
                ["jsonrpc": "2.0", "method": "notifications/initialized"],
                ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            ]
            input = try messages.reduce(into: Data()) { $0.append(try JSONSerialization.data(withJSONObject: $1)); $0.append(0x0a) }
        } else { input = try JSONSerialization.data(withJSONObject: arguments) }
        let executable = binary
        let output = try await Task.detached {
            let child = Process(), stdin = Pipe(), stdout = Pipe()
            child.executableURL = executable
            child.arguments = stdio ? ["mcp"] : ["tools", "call", name, "--input", "-"]
            child.environment = ["FIXTURE_ENDPOINT": "http://127.0.0.1:\(port)/mcp", "FIXTURE_TOKEN": token]
            child.standardInput = stdin
            child.standardOutput = stdout
            try child.run()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            try #require(child.terminationStatus == 0)
            return bytes
        }.value
        if stdio {
            let line = try #require(output.split(separator: 0x0a).last)
            let response = try JSONDecoder().decode(Value.self, from: Data(line))
            return try #require(response.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue)
        }
        return try JSONDecoder().decode([String: Value].self, from: output)
    }
}
