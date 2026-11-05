//
//  FollowGraphTests.swift
//  StarcatTests
//
//  覆盖有向图、刷新删除、账户隔离与迟到响应。测试根目录全部为临时目录，
//  不读取当前登录用户或 Keychain，不产生 GitHub 请求。
//

import Foundation
import Testing
@testable import Starcat

private func node(_ id: Int) -> FollowGraphNode {
    .init(id: String(id), login: "user\(id)", name: nil, avatarURL: nil)
}

private func page(_ source: Int, _ targets: [Int], next: String? = nil, remaining: Int = 5_000) -> FollowGraphPage {
    .init(source: node(source), nodes: targets.map(node), cursor: next, hasNextPage: next != nil,
          totalCount: targets.count, remaining: remaining,
          resetAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600)))
}

@Suite("FollowGraph graph semantics")
struct FollowGraphEngineTests {
    @Test("高出度缓存默认恢复两层样本，显式展开复用缓存且不修改原快照")
    func boundedPresentation() {
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2, 3]))
        graph.merge(page(2, Array(4...6_003)))
        graph.merge(page(3, [2, 6_004]))
        let displayed = graph.presentation()
        #expect(displayed.nodes.count == 24)
        #expect(displayed.edges.contains(.init(source: "3", target: "2")))
        #expect(displayed.progress["2"]?.complete == false)
        #expect(graph.nodes.count == 6_004)
        #expect(graph.progress["2"]?.complete == true)
        let expanded = graph.presentation(expanded: ["2": 70])
        #expect(expanded.nodes.count == 74)
        #expect(Set(displayed.nodes.keys).isSubset(of: Set(expanded.nodes.keys)))
        #expect(expanded.edges.allSatisfy { expanded.nodes[$0.source] != nil && expanded.nodes[$0.target] != nil })
        #expect(graph.presentation() == displayed)
    }

    @Test("二维视口保留平移缩放，拒绝三维相机、非有限值与越界缩放")
    func viewportValidation() throws {
        let viewport = try #require(FollowGraphViewport(values: [120, -80, 1.5]))
        #expect(viewport.values == [120, -80, 1.5])
        for values: [Double] in [
            [], [0, 0, 200, 0, 0, 0], [0, 0, 0], [0, 0, -1],
            [0, 0, 8.01], [0, 0, 0.049], [.nan, 0, 1], [0, .infinity, 1],
            [0, 0, .infinity], [1_000_000, 0, 1]
        ] {
            #expect(FollowGraphViewport(values: values) == nil)
        }
        #expect(FollowGraphViewport(values: [0, 0, 0.05]) != nil)
        #expect(FollowGraphViewport(values: [0, 0, 8]) != nil)
    }

    @Test("重复分页、反向边与环路保持有向身份")
    func deduplicationAndCycles() {
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [1, 2, 3]))
        graph.merge(page(1, [2, 3]))
        graph.merge(page(2, [1, 3]))
        graph.merge(page(3, [2]))
        #expect(graph.nodes.count == 3)
        #expect(graph.edges.count == 5)
        #expect(!graph.edges.contains(.init(source: "1", target: "1")))
        #expect(graph.path(to: "2") == ["1", "2"])
        #expect(graph.path(to: "404").isEmpty)
    }

    @Test("等长路径按数值 ID 稳定选择，新增关系可缩短层级")
    func stableShortestPath() {
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [10, 2]))
        graph.merge(page(10, [4]))
        graph.merge(page(2, [4]))
        #expect(graph.path(to: "4") == ["1", "2", "4"])
        graph.merge(page(1, [4]))
        #expect(graph.path(to: "4") == ["1", "4"])
        #expect(graph.path(to: "1") == ["1"])
    }

    @Test("末页替换后移除不可达节点，保留仍可达的交叉关系")
    func refreshPruning() {
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2, 3]))
        graph.merge(page(2, [4]))
        graph.merge(page(3, [4]))
        graph.merge(page(1, [3]), replacing: ["3"])
        graph.pruneUnreachable()
        #expect(graph.nodes["2"] == nil)
        #expect(graph.nodes["4"] != nil)
        #expect(graph.path(to: "4") == ["1", "3", "4"])
    }

    @Test("一万节点三万边的路径计算仍正确")
    func largeGraph() {
        var graph = FollowGraphSnapshot(root: node(1))
        for id in 2...10_000 {
            graph.nodes[String(id)] = node(id)
            graph.edges.insert(.init(source: String(id / 2), target: String(id)))
            if id > 3 {
                graph.edges.insert(.init(source: String(id), target: String(id - 1)))
                graph.edges.insert(.init(source: String(id - 2), target: String(id)))
            }
        }
        #expect(graph.nodes.count == 10_000)
        #expect(graph.edges.count < 30_000)
        let path = graph.path(to: "10000")
        #expect(path.first == "1")
        #expect(path.last == "10000")
        #expect(path.count < 16)
    }
}

/// 有序脚本可模拟成功首批后失败，验证不能把部分刷新当成完整结果。
private actor ScriptedFollowGraphProvider: FollowGraphProviding {
    var pages: [FollowGraphPage]
    var calls = 0
    var requestedCounts: [Int] = []
    init(_ pages: [FollowGraphPage]) { self.pages = pages }
    func page(login: String, cursor: String?, count: Int) async throws -> FollowGraphPage {
        calls += 1
        requestedCounts.append(count)
        guard !pages.isEmpty else { throw URLError(.notConnectedToInternet) }
        return pages.removeFirst()
    }
}

/// 故意忽略 Task 取消的网络替身，验证返回点的 generation 校验才是最终写入屏障。
private actor SuspendedFollowGraphProvider: FollowGraphProviding {
    private var response: CheckedContinuation<FollowGraphPage, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var requested = false
    func page(login: String, cursor: String?, count: Int) async throws -> FollowGraphPage {
        await withCheckedContinuation { continuation in
            response = continuation
            requested = true
            waiter?.resume()
            waiter = nil
        }
    }
    func waitForRequest() async {
        if requested { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release(_ page: FollowGraphPage) {
        response?.resume(returning: page)
        response = nil
    }
}

@Suite("FollowGraph store and cache")
struct FollowGraphStoreTests {
    private func temporaryCache() throws -> (URL, FollowGraphDiskCache) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, FollowGraphDiskCache(root: root))
    }

    @Test("原子快照可恢复，其他账号与不安全路径无法读取")
    func accountIsolation() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2]))
        try await cache.save(graph)
        #expect(await cache.load(account: "1") == graph)
        #expect(await cache.load(account: "2") == nil)
        #expect(await cache.load(account: "../1") == nil)
        #expect(await cache.load(account: "01") == nil)
        #expect(await cache.bytes(account: "1") > 0)
        try await cache.remove(account: "1")
        #expect(await cache.load(account: "1") == nil)
    }

    @Test("损坏和未知格式快照安全降级")
    func invalidCache() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        var graph = FollowGraphSnapshot(root: node(1))
        graph.formatVersion = 99
        try await cache.save(graph)
        #expect(await cache.load(account: "1") == nil)
        let url = root.appendingPathComponent("1/snapshot.json")
        try Data("broken".utf8).write(to: url)
        #expect(await cache.load(account: "1") == nil)
    }

    @Test("单页追加保持 cursor，末页才标记完整")
    func pagination() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFollowGraphProvider([page(1, [2], next: "cursor"), page(1, [3])])
        let store = FollowGraphStore(provider: provider, cache: cache)
        let session = UUID()
        await store.begin(.init(root: node(1)), session: session)
        let first = try await store.load(userID: "1", session: session)
        #expect(first.progress["1"]?.cursor == "cursor")
        #expect(first.progress["1"]?.complete == false)
        let last = try await store.load(userID: "1", session: session)
        #expect(last.progress["1"]?.complete == true)
        #expect(last.edges.count == 2)
    }

    @Test("样本刷新只请求展示预算，不追着高出度用户翻至末页且保留缓存")
    func boundedRefresh() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFollowGraphProvider([
            page(2, Array(4...23), next: "more"),
            page(2, Array(24...123), next: "still-more")
        ])
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2]))
        graph.merge(page(2, Array(4...6_003)))
        let store = FollowGraphStore(provider: provider, cache: cache)
        let session = UUID()
        await store.begin(graph, session: session)
        let refreshed = try await store.load(userID: "2", session: session, count: 100,
                                             refresh: true, refreshLimit: 20)
        #expect(await provider.calls == 1)
        #expect(await provider.requestedCounts == [20])
        #expect(refreshed.nodes.count == graph.nodes.count)
        #expect(refreshed.edges == graph.edges)
        #expect(refreshed.progress["2"]?.complete == false)
    }

    @Test("刷新中途失败不删除旧边，也不标记完整")
    func partialRefresh() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFollowGraphProvider([page(1, [3], next: "next")])
        let store = FollowGraphStore(provider: provider, cache: cache)
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2]))
        let session = UUID()
        await store.begin(graph, session: session)
        await #expect(throws: (any Error).self) {
            _ = try await store.load(userID: "1", session: session, refresh: true)
        }
        let value = await store.read(session: session)
        #expect(value?.edges.contains(.init(source: "1", target: "2")) == true)
        #expect(value?.edges.contains(.init(source: "1", target: "3")) == true)
        #expect(value?.progress["1"]?.complete == false)
    }

    @Test("完整刷新替换出边并清理不可达节点")
    func fullRefresh() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFollowGraphProvider([page(1, [3], next: "next"), page(1, [4])])
        let store = FollowGraphStore(provider: provider, cache: cache)
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2]))
        let session = UUID()
        await store.begin(graph, session: session)
        _ = try await store.load(userID: "1", session: session, refresh: true)
        let value = try await store.finishRefresh(session: session)
        #expect(value?.nodes["2"] == nil)
        #expect(value?.edges == [.init(source: "1", target: "3"), .init(source: "1", target: "4")])
        #expect(value?.progress["1"]?.complete == true)
    }

    @Test("低配额停止新请求，已经取得的结果仍被保存")
    func quotaProtection() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFollowGraphProvider([page(1, [2], remaining: 199)])
        let store = FollowGraphStore(provider: provider, cache: cache)
        let session = UUID()
        await store.begin(.init(root: node(1)), session: session)
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) { _ = try await store.load(userID: "1", session: session) }
        }
        #expect(await provider.calls == 1)
        #expect(await cache.load(account: "1")?.nodes["2"] != nil)
    }

    @Test("硬节点上限拒绝整页，不能保存无端点的边")
    func hardLimit() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFollowGraphProvider([page(1, [10_001])])
        let store = FollowGraphStore(provider: provider, cache: cache)
        var graph = FollowGraphSnapshot(root: node(1))
        for id in 2...10_000 { graph.nodes[String(id)] = node(id) }
        let session = UUID()
        await store.begin(graph, session: session)
        await #expect(throws: (any Error).self) { _ = try await store.load(userID: "1", session: session) }
        #expect(await provider.calls == 0)
    }

    @Test("切换会话后拒绝旧调用")
    func sessionIsolation() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFollowGraphProvider([page(1, [2])])
        let store = FollowGraphStore(provider: provider, cache: cache)
        let old = UUID()
        await store.begin(.init(root: node(1)), session: old)
        await store.begin(.init(root: node(3)), session: UUID())
        await #expect(throws: (any Error).self) { _ = try await store.load(userID: "1", session: old) }
        #expect(await provider.calls == 0)
        #expect(await store.read(session: old) == nil)
    }

    @Test("迟到网络响应不能跨账户写入，取消后也不能保存", arguments: [true, false])
    func lateResponse(changeAccount: Bool) async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = SuspendedFollowGraphProvider()
        let store = FollowGraphStore(provider: provider, cache: cache)
        let old = UUID()
        await store.begin(.init(root: node(1)), session: old)
        let request = Task { try await store.load(userID: "1", session: old) }
        await provider.waitForRequest()
        if changeAccount { await store.begin(.init(root: node(3)), session: UUID()) }
        else { request.cancel() }
        await provider.release(page(1, [2]))
        await #expect(throws: (any Error).self) { _ = try await request.value }
        #expect(await cache.load(account: "1") == nil)
        #expect(await cache.load(account: "3") == nil)
    }

    @Test("重复 cursor 不得导致分页循环")
    func repeatedCursor() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFollowGraphProvider([page(1, [3], next: "same")])
        let store = FollowGraphStore(provider: provider, cache: cache)
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2], next: "same"))
        let session = UUID()
        await store.begin(graph, session: session)
        await #expect(throws: (any Error).self) { _ = try await store.load(userID: "1", session: session) }
        #expect(await store.read(session: session)?.nodes["3"] == nil)
    }
}

@Suite("FollowGraph GraphQL mapping", .serialized)
struct FollowGraphAPITests {
    @Test("GraphQL 变量、头像和完整性映射遵循接口契约")
    func mapping() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let variables = json["variables"] as! [String: Any]
            #expect(request.url?.path == "/graphql")
            #expect(variables["login"] as? String == "user1")
            #expect(variables["after"] as? String == "previous")
            #expect(variables["first"] as? Int == 100)
            let body = """
            {"data":{"user":{"databaseId":1,"login":"user1","name":null,"avatarUrl":null,
            "following":{"totalCount":2,"pageInfo":{"endCursor":"next","hasNextPage":true},
            "nodes":[{"databaseId":2,"login":"user2","name":"Two","avatarUrl":"https://avatars.githubusercontent.com/u/2"}]}},
            "rateLimit":{"remaining":4000,"resetAt":"2026-11-05T12:00:00Z"}}}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let client = GitHubAPIClient(baseURL: URL(string: "https://api.test.invalid")!,
                                    session: URLProtocolStub.ephemeralSession(),
                                    tokenProvider: StubTokenProvider(token: "test"))
        let result = try await FollowGraphAPI(client: client).page(login: "user1", cursor: "previous", count: 200)
        #expect(result.source.id == "1")
        #expect(result.nodes.first?.name == "Two")
        #expect(result.cursor == "next")
        #expect(result.hasNextPage)
        #expect(result.remaining == 4_000)
    }
}
