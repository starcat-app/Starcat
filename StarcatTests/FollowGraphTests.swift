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
    @Test("加载数量只统计当前投影的对应方向，关系总数优先于资料卡", arguments: FollowGraphRelation.allCases)
    func relationLoadCounts(relation: FollowGraphRelation) {
        var graph = FollowGraphSnapshot(root: node(1), relation: relation)
        graph.merge(page(1, [2]))
        graph.merge(page(2, Array(3...27)))
        let initial = graph.presentation()
        let counts = initial.relationLoadCounts(for: "2", fallbackTotal: 99)
        #expect(counts.loaded == relation.defaultSampleCount)
        #expect(counts.total == 25)
        #expect(graph.relationLoadCounts(for: "2").loaded == 25)
        let expanded = graph.presentation(expanded: ["2": 1])
        #expect(expanded.relationLoadCounts(for: "2").loaded == 1)
        #expect(expanded.relationLoadCounts(for: "2").total == 25)
        #expect(expanded.progress["2"]?.complete == false)
    }

    @Test("未知总数用资料卡回退，真实零值不能被旧资料覆盖")
    func relationLoadCountFallback() {
        var graph = FollowGraphSnapshot(root: node(1))
        #expect(graph.relationLoadCounts(for: "1").total == nil)
        #expect(graph.relationLoadCounts(for: "1", fallbackTotal: 76).total == 76)
        #expect(graph.relationLoadCounts(for: "1", fallbackTotal: 0).total == 0)
        graph.merge(page(1, []))
        #expect(graph.relationLoadCounts(for: "1", fallbackTotal: 76).total == 0)
        #expect(graph.relationLoadCounts(for: "1").loaded == 0)
    }

    @Test("加载人数等于总人数也不能代替分页完整状态")
    func relationLoadCountDoesNotComplete() {
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2], next: "more"))
        let counts = graph.relationLoadCounts(for: "1")
        #expect(counts.loaded == counts.total)
        #expect(graph.progress["1"]?.complete == false)
    }

    @Test("Followers 沿入边默认展示三层，第四层只按需展开")
    func followersProjection() {
        var graph = FollowGraphSnapshot(root: node(1), relation: .followers)
        graph.merge(page(1, [2, 10]))
        graph.merge(page(2, [3, 4]))
        graph.merge(page(10, [4]))
        graph.merge(page(4, [2, 5]))
        #expect(graph.path(to: "4") == ["4", "2", "1"])
        #expect(graph.edges.contains(.init(source: "2", target: "1")))
        #expect(!graph.edges.contains(.init(source: "1", target: "2")))
        #expect(Set(graph.presentation().nodes.keys) == ["1", "2", "3", "4", "10"])
        #expect(graph.presentation().nodes["5"] == nil)
        #expect(graph.presentation().progress["2"]?.complete == true)
        #expect(graph.presentation(expanded: ["4": 50]).path(to: "5") == ["5", "4", "2", "1"])
        #expect(graph.presentation(expanded: ["2": 50]).path(to: "3") == ["3", "2", "1"])
        #expect(graph.presentation(selectedID: "4").path(to: "4") == ["4", "2", "1"])
    }

    @Test("55 位关注者均分第三层预算，缓存和网络共享上限且不改变真实方向")
    func followersDefaultBudget() {
        var graph = FollowGraphSnapshot(root: node(1), relation: .followers)
        graph.merge(page(1, Array(2...56)))
        for owner in 2...56 { graph.merge(page(owner, Array((owner * 100)...(owner * 100 + 29)))) }
        let budgets = graph.defaultExpansionBudgets
        #expect(budgets.count == 55)
        #expect(budgets.values.reduce(0, +) == 1_000)
        #expect(budgets.values.allSatisfy { (18...19).contains($0) })
        let displayed = graph.presentation()
        #expect(displayed.nodes.count == 1_056)
        #expect(displayed.edges.allSatisfy { $0.target == "1" || budgets[$0.target] != nil })
        #expect(!graph.needsDefaultExpansion)
        #expect(graph.presentation().nodes == displayed.nodes)
    }

    @Test("超多关注者的默认第三层预算仍不超过一千，未完成样本可补齐")
    func followersSparseBudget() {
        var graph = FollowGraphSnapshot(root: node(1), relation: .followers)
        graph.merge(page(1, Array(2...1_101)))
        #expect(graph.defaultExpansionBudgets.values.reduce(0, +) == 1_000)
        #expect(graph.defaultExpansionBudgets.values.allSatisfy { (0...1).contains($0) })
        #expect(graph.needsDefaultExpansion)
        graph.merge(page(2, [2_000], next: "next"))
        #expect(graph.defaultExpansionBudgets["2"] == 1)
        #expect(graph.presentation().nodes["2000"] != nil)
    }

    @Test("Followers 回关和取消回关保留粉丝边及本人入边计数")
    func followersFollowAction() {
        var graph = FollowGraphSnapshot(root: node(1), relation: .followers)
        graph.merge(page(1, [2]))
        graph.merge(page(2, [3]))
        graph.setFollowing(true, node: node(2))
        #expect(graph.edges.contains(.init(source: "1", target: "2")))
        #expect(graph.progress["1"]?.totalCount == 1)
        #expect(graph.progress["2"]?.totalCount == 2)
        graph.setFollowing(false, node: node(2))
        #expect(graph.path(to: "3") == ["3", "2", "1"])
        #expect(graph.edges.contains(.init(source: "2", target: "1")))
        #expect(graph.progress["1"]?.totalCount == 1)
        #expect(graph.progress["2"]?.totalCount == 1)
        graph.setFollowing(true, node: node(99))
        #expect(graph.nodes["99"] == nil)
    }

    @Test("Followers 完整刷新替换入边，不误删本人已确认的出边")
    func followersRefresh() {
        var graph = FollowGraphSnapshot(root: node(1), relation: .followers)
        graph.merge(page(1, [2, 3]))
        graph.merge(page(3, [2]))
        graph.setFollowing(true, node: node(2))
        graph.merge(page(1, [3]), replacing: ["3"])
        graph.pruneUnreachable()
        #expect(!graph.edges.contains(.init(source: "2", target: "1")))
        #expect(graph.edges.contains(.init(source: "1", target: "2")))
        #expect(graph.path(to: "2") == ["2", "3", "1"])
    }

    @Test("缺少方向字段的旧 JSON 只能解码为 following")
    func legacySnapshot() throws {
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2]))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(graph)) as! [String: Any]
        json.removeValue(forKey: "relation")
        let restored = try JSONDecoder().decode(FollowGraphSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.relation == .following)
        #expect(restored.path(to: "2") == ["1", "2"])
    }

    @Test("关注缩短路径，取消后保留间接可达用户并清理失联分量")
    func confirmedFollowChanges() {
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2, 3]))
        graph.merge(page(2, [4, 5]))
        graph.merge(page(3, [4]))
        graph.setFollowing(true, node: node(4))
        graph.setFollowing(true, node: node(4))
        #expect(graph.path(to: "4") == ["1", "4"])
        #expect(graph.progress["1"]?.totalCount == 3)
        graph.setFollowing(false, node: node(4))
        #expect(graph.path(to: "4") == ["1", "2", "4"])
        graph.setFollowing(false, node: node(2))
        #expect(graph.nodes["2"] == nil)
        #expect(graph.nodes["5"] == nil)
        #expect(graph.path(to: "4") == ["1", "3", "4"])
        #expect(graph.progress["1"]?.totalCount == 1)
        let before = graph
        graph.setFollowing(true, node: node(1))
        #expect(graph == before)
    }

    @Test("取消直接关注后，选中用户仍沿已知间接路径展示，不受二层样本截断")
    func selectionSurvivesUnfollow() {
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2, 100]))
        graph.merge(page(2, Array(3...100)))
        graph.setFollowing(false, node: node(100))
        #expect(graph.presentation().nodes["100"] == nil)
        let displayed = graph.presentation(selectedID: "100")
        #expect(displayed.path(to: "100") == ["1", "2", "100"])
        #expect(!displayed.edges.contains(.init(source: "1", target: "100")))
    }

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

    @Test("大图的手动名额用于所选分支，不被其他默认分支抢占")
    func manualExpansionReservesCapacity() {
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, Array(2...301)))
        for owner in 2...301 {
            graph.merge(page(owner, Array((owner * 100)...(owner * 100 + 19))))
        }
        let before = graph.presentation()
        #expect(before.nodes.count == 5_000)
        #expect(before.relationCount(for: "301") == 0)
        let after = graph.presentation(expanded: ["301": 70])
        #expect(after.relationCount(for: "301") == 20)
        #expect(Set(before.nodes.keys).isSubset(of: Set(after.nodes.keys)))
        #expect(after.nodes.count == 5_020)
        // 第三层节点的展开也使用新增容量，不被排在它前面的默认分支占满。
        let source = 20_000
        graph.merge(page(200, [source]))
        graph.merge(page(source, Array(40_000...40_049)))
        let nested = graph.presentation(expanded: ["20000": 50], selectedID: "20000")
        #expect(nested.relationCount(for: "20000") == 50)
        #expect(nested.path(to: "40000") == ["1", "200", "20000", "40000"])
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
        requested = false
        response?.resume(returning: page)
        response = nil
    }
}

@Suite("FollowGraph store and cache")
struct FollowGraphStoreTests {
    @Test("已完成分页不再从空 cursor 重读第一页，显式刷新仍请求远端")
    func completedPaginationDoesNotRequest() async throws {
        let (folder, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2]))
        let provider = ScriptedFollowGraphProvider([page(1, [3])])
        let store = FollowGraphStore(provider: provider, cache: cache)
        let session = UUID()
        await store.begin(graph, session: session)
        #expect(try await store.load(userID: "1", session: session) == graph)
        #expect(await provider.calls == 0)
        let refreshed = try await store.load(userID: "1", session: session, refresh: true)
        #expect(await provider.calls == 1)
        #expect(refreshed.edges == [.init(source: "1", target: "3")])
    }

    @Test("配额冷却期间仍能读取已经完整的缓存")
    func completedCacheDuringQuotaCooldown() async throws {
        let (folder, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = ScriptedFollowGraphProvider([page(1, [2], remaining: 100)])
        let store = FollowGraphStore(provider: provider, cache: cache)
        let session = UUID()
        await store.begin(.init(root: node(1)), session: session)
        await #expect(throws: FollowGraphStoreError.self) { try await store.load(userID: "1", session: session) }
        let cached = try await store.load(userID: "1", session: session)
        #expect(cached.progress["1"]?.complete == true)
        #expect(await provider.calls == 1)
    }

    private func temporaryCache() throws -> (URL, FollowGraphDiskCache) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, FollowGraphDiskCache(root: root))
    }

    @Test("双方向缓存共存，关注确认同步出边，恢复出厂也删除仅 followers 的目录")
    func relationCacheIsolation() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        var following = FollowGraphSnapshot(root: node(1))
        following.merge(page(1, [9]))
        var followers = FollowGraphSnapshot(root: node(1), relation: .followers)
        followers.merge(page(1, [2]))
        try await cache.save(following)
        try await cache.save(followers)
        #expect(await cache.load(account: "1") == following)
        #expect(await cache.load(account: "1", relation: .followers) == followers)
        try await cache.setFollowing(true, node: node(2), accountID: "1")
        #expect(await cache.load(account: "1")?.path(to: "2") == ["1", "2"])
        #expect(await cache.load(account: "1", relation: .followers)?.path(to: "2") == ["2", "1"])
        try await cache.setFollowing(false, node: node(2), accountID: "1")
        #expect(await cache.load(account: "1", relation: .followers)?.edges.contains(.init(source: "2", target: "1")) == true)
        try FileManager.default.removeItem(at: root.appendingPathComponent("1/snapshot.json"))
        #expect(await cache.bytes(account: "1", relation: .followers) > 0)
        try await cache.remove(account: "1")
        #expect(await cache.load(account: "1", relation: .followers) == nil)
    }

    @Test("Followers 分页只创建入边，完整刷新清理已离开的关注者")
    func followersPagination() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = ScriptedFollowGraphProvider([page(1, [2], next: "next"), page(1, [3]), page(1, [3])])
        let store = FollowGraphStore(provider: provider, cache: cache)
        let session = UUID()
        await store.begin(.init(root: node(1), relation: .followers), session: session)
        _ = try await store.load(userID: "1", session: session)
        let value = try await store.load(userID: "1", session: session)
        #expect(value.edges == [.init(source: "2", target: "1"), .init(source: "3", target: "1")])
        _ = try await store.load(userID: "1", session: session, refresh: true)
        let refreshed = try await store.finishRefresh(session: session)
        #expect(refreshed?.nodes["2"] == nil)
        #expect(refreshed?.path(to: "3") == ["3", "1"])
    }

    @Test("切换方向后的旧分页响应不能污染新快照")
    func lateResponseAcrossRelation() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = SuspendedFollowGraphProvider()
        let store = FollowGraphStore(provider: provider, cache: cache)
        let first = UUID()
        await store.begin(.init(root: node(1)), session: first)
        let loading = Task { try await store.load(userID: "1", session: first) }
        await provider.waitForRequest()
        let second = UUID()
        await store.begin(.init(root: node(1), relation: .followers), session: second)
        await provider.release(page(1, [2]))
        await #expect(throws: FollowGraphStoreError.self) { try await loading.value }
        #expect(await store.read(session: second)?.edges.isEmpty == true)
        #expect(await store.read(session: second)?.relation == .followers)
    }

    @Test("已确认关注同步缓存，其他账户无法写入")
    func followingPersistence() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FollowGraphStore(provider: ScriptedFollowGraphProvider([]), cache: cache)
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2]))
        graph.merge(page(2, [3]))
        await store.begin(graph, session: UUID())
        let followed = try await store.setFollowing(true, node: node(3), accountID: "1")
        #expect(followed.path(to: "3") == ["1", "3"])
        #expect(await cache.load(account: "1") == followed)
        let unfollowed = try await store.setFollowing(false, node: node(3), accountID: "1")
        #expect(unfollowed.path(to: "3") == ["1", "2", "3"])
        #expect(await cache.load(account: "1") == unfollowed)
        await #expect(throws: FollowGraphStoreError.self) {
            _ = try await store.setFollowing(true, node: node(4), accountID: "99")
        }
        #expect(await store.read(accountID: "1") == unfollowed)
        #expect(await cache.load(account: "99") == nil)
    }

    @Test("重开画布时较旧缓存不能覆盖已确认的关注关系")
    func reopenDuringFollow() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FollowGraphStore(provider: ScriptedFollowGraphProvider([]), cache: cache)
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2]))
        graph.savedAt = .distantPast
        await store.begin(graph, session: UUID())
        let confirmed = try await store.setFollowing(true, node: node(3), accountID: "1")
        let current = await store.begin(graph, session: UUID())
        #expect(current == confirmed)
        #expect(current.path(to: "3") == ["1", "3"])
    }

    @Test("变更前已开始的刷新不能恢复取消的边或删除刚关注的边", arguments: [true, false])
    func followDuringRefresh(following: Bool) async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = SuspendedFollowGraphProvider()
        let store = FollowGraphStore(provider: provider, cache: cache)
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, following ? [2] : [2, 3]))
        graph.merge(page(2, [3]))
        let session = UUID()
        await store.begin(graph, session: session)
        let request = Task { try await store.load(userID: "1", session: session, refresh: true) }
        await provider.waitForRequest()
        _ = try await store.setFollowing(following, node: node(3), accountID: "1")
        await provider.release(page(1, following ? [2] : [2, 3]))
        let value = try await request.value
        #expect(value.edges.contains(.init(source: "1", target: "3")) == following)
        #expect(value.path(to: "3") == (following ? ["1", "3"] : ["1", "2", "3"]))
        #expect(await cache.load(account: "1") == value)
    }

    @Test("写操作之后新发起的刷新仍可反映 GitHub 的后续变化")
    func laterRefreshIsAuthoritative() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FollowGraphStore(provider: ScriptedFollowGraphProvider([page(1, [2])]), cache: cache)
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2]))
        graph.merge(page(2, [3]))
        let session = UUID()
        await store.begin(graph, session: session)
        _ = try await store.setFollowing(true, node: node(3), accountID: "1")
        let value = try await store.load(userID: "1", session: session, refresh: true)
        #expect(!value.edges.contains(.init(source: "1", target: "3")))
        #expect(value.path(to: "3") == ["1", "2", "3"])
    }

    @Test("跨页刷新完成时不恢复前一页已取消的关系，且保留中途新增关注")
    func followDuringMultipageRefresh() async throws {
        let (root, cache) = try temporaryCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = SuspendedFollowGraphProvider()
        let store = FollowGraphStore(provider: provider, cache: cache)
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2, 4]))
        graph.merge(page(4, [2, 3]))
        let session = UUID()
        await store.begin(graph, session: session)
        let request = Task { try await store.load(userID: "1", session: session, refresh: true) }
        await provider.waitForRequest()
        await provider.release(page(1, [2], next: "cursor"))
        await provider.waitForRequest()
        _ = try await store.setFollowing(false, node: node(2), accountID: "1")
        _ = try await store.setFollowing(true, node: node(3), accountID: "1")
        await provider.release(page(1, [4]))
        let value = try await request.value
        #expect(!value.edges.contains(.init(source: "1", target: "2")))
        #expect(value.path(to: "2") == ["1", "4", "2"])
        #expect(value.path(to: "3") == ["1", "3"])
        #expect(await cache.load(account: "1") == value)
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
        let provider = ScriptedFollowGraphProvider([page(1, [2], next: "more", remaining: 199)])
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
    @MainActor
    @Test("旧首层缓存自动补齐55个分支的一千条样本，重开不再次请求或递归")
    func followersUpgradesFirstLevelCache() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = FollowGraphDiskCache(root: folder)
        var graph = FollowGraphSnapshot(root: node(1), relation: .followers)
        graph.merge(page(1, Array(2...56)))
        try await cache.save(graph)
        URLProtocolStub.requestHandler = { request in
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let variables = json["variables"] as! [String: Any]
            let login = variables["login"] as! String
            let owner = Int(login.dropFirst(4))!
            let count = variables["first"] as! Int
            #expect((2...56).contains(owner))
            #expect((18...19).contains(count))
            let users = (0..<count).map { offset in
                ["databaseId": owner * 100 + offset, "login": "user\(owner * 100 + offset)"] as [String: Any]
            }
            let body: [String: Any] = ["data": [
                "user": ["databaseId": owner, "login": login,
                         "followers": ["totalCount": 100, "pageInfo": ["endCursor": "next", "hasNextPage": true],
                                       "nodes": users]],
                "rateLimit": ["remaining": 4_000, "resetAt": "2099-11-05T12:00:00Z"]
            ]]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try JSONSerialization.data(withJSONObject: body))
        }
        let client = GitHubAPIClient(baseURL: URL(string: "https://api.test.invalid")!,
                                    session: URLProtocolStub.ephemeralSession(), tokenProvider: StubTokenProvider(token: "test"))
        let model = FollowGraphViewModel(cache: cache)
        defer { model.stop() }
        let user = GitHubUserDTO(id: 1, login: "user1", name: nil, avatarUrl: nil)
        func settle() async throws {
            let deadline = Date().addingTimeInterval(5)
            while model.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.isLoading)
            #expect(model.errorText == nil)
        }
        model.open(user: user, client: client, relation: .followers)
        try await settle()
        #expect(model.snapshot?.progress.count == 56)
        #expect(model.displayedSnapshot?.nodes.count == 1_056)
        #expect(model.snapshot?.needsDefaultExpansion == false)
        URLProtocolStub.requestHandler = { _ in
            Issue.record("默认样本已满足预算时重开不能重复请求")
            throw URLError(.notConnectedToInternet)
        }
        model.open(user: user, client: client, relation: .followers)
        try await settle()
        #expect(model.displayedSnapshot?.nodes.count == 1_056)
    }

    @MainActor
    @Test("缓存先展开，数量已满隐藏按钮但不伪造分页完整", arguments: FollowGraphRelation.allCases, [false, true])
    func loadMoreAvailability(relation: FollowGraphRelation, complete: Bool) async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = FollowGraphDiskCache(root: folder)
        var graph = FollowGraphSnapshot(root: node(1), relation: relation)
        graph.merge(page(1, [2, 3]))
        graph.merge(page(2, Array(3...52), next: complete ? nil : "more"))
        graph.merge(page(3, []))
        try await cache.save(graph)
        URLProtocolStub.requestHandler = { _ in
            Issue.record("已有足够缓存或人数已满时不应发送分页请求")
            throw URLError(.notConnectedToInternet)
        }
        let client = GitHubAPIClient(baseURL: URL(string: "https://api.test.invalid")!,
                                    session: URLProtocolStub.ephemeralSession(), tokenProvider: StubTokenProvider(token: "test"))
        let model = FollowGraphViewModel(cache: cache)
        defer { model.stop() }
        model.open(user: .init(id: 1, login: "user1", name: nil, avatarUrl: nil), client: client, relation: relation)
        let deadline = Date().addingTimeInterval(5)
        while model.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoading)
        #expect(model.canLoadMore("2"))
        #expect(!model.canLoadMore("3", fallbackTotal: 100))
        model.select("2", expand: false)
        #expect(model.isRevealingRelations(for: "2"))
        model.loadMore("2")
        #expect(!model.isLoading)
        #expect(model.displayedSnapshot?.relationCount(for: "2") == 50)
        #expect(model.toastMessage == nil)
        #expect(!model.canLoadMore("2"))
        #expect(model.snapshot?.progress["2"]?.complete == complete)
        model.loadMore("2")
        #expect(model.toastMessage == "followGraph.toast.complete")
        model.reportRenderedCounts(nodes: 52, edges: 52, revision: model.revision, renderer: model.rendererRevision,
                                   selectedID: "2", selectionRevision: model.selectionRevision, selectedCount: 50)
        #expect(!model.isRevealingRelations(for: "2"))
        #expect(model.renderedRelationCount(for: "2") == 50)
        model.select("4", expand: false)
        #expect(!model.canLoadMore("4", fallbackTotal: 0))
        #expect(model.canLoadMore("4"))
        model.resetCanvas()
        #expect(model.toastMessage == nil)
    }

    @MainActor
    @Test("分页只补充关系、重复用户、完成和失败都有明确 Toast")
    func loadMoreFeedback() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = FollowGraphDiskCache(root: folder)
        var graph = FollowGraphSnapshot(root: node(1))
        graph.merge(page(1, [2, 3, 4]))
        graph.merge(page(2, [3], next: "first"))
        graph.progress["2"]?.totalCount = 10
        try await cache.save(graph)
        let client = GitHubAPIClient(baseURL: URL(string: "https://api.test.invalid")!,
                                    session: URLProtocolStub.ephemeralSession(), tokenProvider: StubTokenProvider(token: "test"))
        let model = FollowGraphViewModel(cache: cache)
        defer { model.stop() }
        func settle() async throws {
            let deadline = Date().addingTimeInterval(5)
            while model.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.isLoading)
        }
        model.open(user: .init(id: 1, login: "user1", name: nil, avatarUrl: nil), client: client)
        try await settle()
        model.select("2", expand: false)
        for (cursor, hasNext, expected) in [
            ("second", true, "followGraph.toast.relationshipsAdded"),
            ("third", true, "followGraph.toast.alreadyVisible"),
            ("last", false, "followGraph.toast.complete")
        ] {
            URLProtocolStub.requestHandler = { request in
                let body = """
                {"data":{"user":{"databaseId":2,"login":"user2","name":null,"avatarUrl":null,
                "following":{"totalCount":10,"pageInfo":{"endCursor":"\(cursor)","hasNextPage":\(hasNext)},
                "nodes":[{"databaseId":4,"login":"user4","name":null,"avatarUrl":null}]}},
                "rateLimit":{"remaining":4000,"resetAt":"2099-11-05T12:00:00Z"}}}
                """
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            model.loadMore("2")
            try await settle()
            #expect(model.toastMessage == expected)
            #expect(!model.toastIsError)
            #expect(model.displayedSnapshot?.nodes.count == 4)
        }
        URLProtocolStub.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        model.select("3", expand: false)
        model.loadMore("3")
        try await settle()
        #expect(model.toastMessage == "followGraph.toast.loadFailed")
        #expect(model.toastIsError)
        #expect(model.canLoadMore("3"))
        URLProtocolStub.requestHandler = { request in
            let body = """
            {"data":{"user":{"databaseId":3,"login":"user3","name":null,"avatarUrl":null,
            "following":{"totalCount":10,"pageInfo":{"endCursor":"more","hasNextPage":true},
            "nodes":[{"databaseId":4,"login":"user4","name":null,"avatarUrl":null}]}},
            "rateLimit":{"remaining":199,"resetAt":"2099-11-05T12:00:00Z"}}}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        model.loadMore("3")
        try await settle()
        #expect(model.toastMessage == "followGraph.status.quota")
        #expect(model.toastIsError)
        #expect(model.snapshot?.edges.contains(.init(source: "3", target: "4")) == true)
        model.stop()
        #expect(model.toastMessage == nil)
    }

    @MainActor
    @Test("画布实际人数逐步增加，拒绝旧批次、旧画布和切回同一用户的旧选择", arguments: FollowGraphRelation.allCases)
    func renderedSelectionCounts(relation: FollowGraphRelation) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = FollowGraphDiskCache(root: folder)
        var graph = FollowGraphSnapshot(root: node(1), relation: relation)
        graph.merge(page(1, [2]))
        graph.merge(page(2, Array(3...52)))
        try await cache.save(graph)
        let client = GitHubAPIClient(baseURL: URL(string: "https://api.test.invalid")!,
                                    session: URLProtocolStub.ephemeralSession(), tokenProvider: StubTokenProvider(token: "test"))
        let model = FollowGraphViewModel(cache: cache)
        defer { model.stop() }
        model.open(user: .init(id: 1, login: "user1", name: nil, avatarUrl: nil), client: client, relation: relation)
        let deadline = Date().addingTimeInterval(5)
        while model.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.isLoading)
        model.select("2", expand: false)
        let selection = model.selectionRevision, revision = model.revision, renderer = model.rendererRevision
        #expect(model.renderedRelationCount(for: "2") == 0)
        func report(_ count: Int, version: Int? = nil, frame: Int? = nil, graph: Int? = nil) {
            model.reportRenderedCounts(nodes: 10, edges: 9, revision: graph ?? revision,
                                       renderer: frame ?? renderer, selectedID: "2",
                                       selectionRevision: version ?? selection, selectedCount: count)
        }
        report(2)
        #expect(model.renderedRelationCount(for: "2") == 2)
        report(4)
        #expect(model.renderedRelationCount(for: "2") == 4)
        report(8, graph: revision - 1)
        report(8, frame: renderer - 1)
        report(-1)
        report(99)
        #expect(model.renderedRelationCount(for: "2") == 4)
        model.select("1", expand: false)
        model.select("2", expand: false)
        report(9)
        #expect(model.renderedRelationCount(for: "2") == 0)
        report(3, version: model.selectionRevision)
        #expect(model.renderedRelationCount(for: "2") == 3)
        #expect(model.revision == revision)
        model.resetCanvas()
        model.select("2", expand: false)
        report(9, version: model.selectionRevision, graph: model.revision)
        #expect(model.renderedRelationCount(for: "2") == 0)
    }

    @MainActor
    @Test("刷新会完成中断的本人首层，而不是仅重复已有样本", arguments: FollowGraphRelation.allCases)
    func refreshCompletesPartialRoot(relation: FollowGraphRelation) async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = FollowGraphDiskCache(root: folder)
        var cached = FollowGraphSnapshot(root: node(1), relation: relation)
        cached.merge(page(1, [2], next: "old"))
        try await cache.save(cached)
        URLProtocolStub.requestHandler = { request in
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let variables = json["variables"] as! [String: Any]
            let owner = variables["login"] as! String
            if owner != "user1" {
                let id = Int(owner.dropFirst(4))!
                let body = """
                {"data":{"user":{"databaseId":\(id),"login":"\(owner)","name":null,"avatarUrl":null,
                "\(relation.rawValue)":{"totalCount":0,"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}},
                "rateLimit":{"remaining":4000,"resetAt":"2099-11-05T12:00:00Z"}}}
                """
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            let lastPage = variables["after"] as? String == "next"
            let id = lastPage ? 3 : 2
            let body = """
            {"data":{"user":{"databaseId":1,"login":"user1","name":null,"avatarUrl":null,
            "\(relation.rawValue)":{"totalCount":2,
            "pageInfo":{"endCursor":\(lastPage ? "null" : "\"next\""),"hasNextPage":\(lastPage ? "false" : "true")},
            "nodes":[{"databaseId":\(id),"login":"user\(id)","name":null,"avatarUrl":null}]}},
            "rateLimit":{"remaining":4000,"resetAt":"2099-11-05T12:00:00Z"}}}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = GitHubAPIClient(baseURL: URL(string: "https://api.test.invalid")!,
                                    session: URLProtocolStub.ephemeralSession(), tokenProvider: StubTokenProvider(token: "test"))
        let model = FollowGraphViewModel(cache: cache)
        defer { model.stop() }
        func settle() async throws {
            let deadline = Date().addingTimeInterval(5)
            while model.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.isLoading)
            #expect(model.errorText == nil)
        }
        model.open(user: .init(id: 1, login: "user1", name: nil, avatarUrl: nil), client: client, relation: relation)
        try await settle()
        #expect(model.snapshot?.progress["1"]?.complete == (relation == .followers))
        model.refresh()
        try await settle()
        #expect(model.snapshot?.progress["1"]?.complete == true)
        #expect(model.displayedSnapshot?.relationLoadCounts(for: "1").loaded == 2)
    }

    @MainActor
    @Test("移除继续按钮后，首次加载失败仍可由刷新重新开始", arguments: FollowGraphRelation.allCases)
    func refreshRestartsMissingRoot(relation: FollowGraphRelation) async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = GitHubAPIClient(baseURL: URL(string: "https://api.test.invalid")!,
                                    session: URLProtocolStub.ephemeralSession(), tokenProvider: StubTokenProvider(token: "test"))
        let model = FollowGraphViewModel(cache: FollowGraphDiskCache(root: folder))
        defer { model.stop() }
        func settle() async throws {
            let deadline = Date().addingTimeInterval(5)
            while model.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.isLoading)
        }
        URLProtocolStub.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        model.open(user: .init(id: 1, login: "user1", name: nil, avatarUrl: nil), client: client, relation: relation)
        try await settle()
        #expect(model.snapshot?.progress["1"] == nil)
        #expect(model.errorText != nil)
        URLProtocolStub.requestHandler = { request in
            let body = """
            {"data":{"user":{"databaseId":1,"login":"user1","name":null,"avatarUrl":null,
            "\(relation.rawValue)":{"totalCount":0,"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}},
            "rateLimit":{"remaining":4000,"resetAt":"2099-11-05T12:00:00Z"}}}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        model.refresh()
        try await settle()
        #expect(model.errorText == nil)
        #expect(model.snapshot?.progress["1"]?.complete == true)
        #expect(model.snapshot?.progress["1"]?.totalCount == 0)
    }

    @MainActor
    @Test("Followers 默认采集三层，第四层按需展开，重开缓存方向隔离")
    func followersLifecycle() async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = FollowGraphDiskCache(root: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        URLProtocolStub.requestHandler = { request in
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let variables = json["variables"] as! [String: Any]
            let owner = variables["login"] as! String
            let source = Int(owner.dropFirst(4))!
            let body = """
            {"data":{"user":{"databaseId":\(source),"login":"\(owner)","name":null,"avatarUrl":null,
            "followers":{"totalCount":1,"pageInfo":{"endCursor":null,"hasNextPage":false},
            "nodes":[{"databaseId":\(source + 1),"login":"user\(source + 1)","name":null,"avatarUrl":null}]}},
            "rateLimit":{"remaining":4000,"resetAt":"2099-11-05T12:00:00Z"}}}
            """
            #expect((json["query"] as? String)?.contains("followers(first:") == true)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = GitHubAPIClient(baseURL: URL(string: "https://api.test.invalid")!,
                                    session: URLProtocolStub.ephemeralSession(), tokenProvider: StubTokenProvider(token: "test"))
        let user = GitHubUserDTO(id: 1, login: "user1", name: nil, avatarUrl: nil)
        let model = FollowGraphViewModel(cache: cache)
        defer { model.stop() }
        func settle() async throws {
            let deadline = Date().addingTimeInterval(5)
            while model.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!model.isLoading)
            #expect(model.errorText == nil)
        }
        model.open(user: user, client: client, relation: .followers)
        try await settle()
        #expect(model.snapshot?.nodes.count == 3)
        #expect(model.snapshot?.progress.count == 2)
        model.select("2", expand: true)
        #expect(!model.isLoading)
        #expect(model.path == ["2", "1"])
        #expect(model.displayedSnapshot?.nodes["3"] != nil)
        model.select("3", expand: true)
        #expect(model.path == ["3", "2", "1"])
        #expect(!model.isLoading)
        model.loadMore("3")
        try await settle()
        #expect(model.displayedSnapshot?.path(to: "4") == ["4", "3", "2", "1"])
        // 重开复用默认三层样本，手动展开的第四层仍留缓存，但不自动显示。
        URLProtocolStub.requestHandler = { _ in
            Issue.record("缓存重开不应采集网络")
            throw URLError(.notConnectedToInternet)
        }
        model.open(user: user, client: client, relation: .followers)
        try await settle()
        #expect(model.displayedSnapshot?.nodes.count == 3)
        #expect(model.displayedSnapshot?.nodes["4"] == nil)
        #expect(model.selectedID == nil)
        var following = FollowGraphSnapshot(root: node(1))
        following.merge(page(1, [9]))
        following.merge(page(9, []))
        try await cache.save(following)
        model.open(user: user, client: client, relation: .following)
        try await settle()
        #expect(model.snapshot?.path(to: "9") == ["1", "9"])
        #expect(model.snapshot?.nodes["2"] == nil)
        model.open(user: user, client: client, relation: .followers)
        try await settle()
        #expect(model.snapshot?.path(to: "3") == ["3", "2", "1"])
        #expect(model.snapshot?.nodes["9"] == nil)
    }

    @Test("GraphQL 双方向变量、头像和完整性映射遵循接口契约", arguments: FollowGraphRelation.allCases)
    func mapping(relation: FollowGraphRelation) async throws {
        URLProtocolStub.reset()
        defer { URLProtocolStub.reset() }
        URLProtocolStub.requestHandler = { request in
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let variables = json["variables"] as! [String: Any]
            #expect(request.url?.path == "/graphql")
            #expect(variables["login"] as? String == "user1")
            #expect(variables["after"] as? String == "previous")
            #expect(variables["first"] as? Int == 100)
            #expect((json["query"] as? String)?.contains("\(relation.rawValue)(first:") == true)
            let body = """
            {"data":{"user":{"databaseId":1,"login":"user1","name":null,"avatarUrl":null,
            "\(relation.rawValue)":{"totalCount":2,"pageInfo":{"endCursor":"next","hasNextPage":true},
            "nodes":[{"databaseId":2,"login":"user2","name":"Two","avatarUrl":"https://avatars.githubusercontent.com/u/2"}]}},
            "rateLimit":{"remaining":4000,"resetAt":"2026-11-05T12:00:00Z"}}}
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
        let client = GitHubAPIClient(baseURL: URL(string: "https://api.test.invalid")!,
                                    session: URLProtocolStub.ephemeralSession(),
                                    tokenProvider: StubTokenProvider(token: "test"))
        let result = try await FollowGraphAPI(client: client, relation: relation).page(login: "user1", cursor: "previous", count: 200)
        #expect(result.source.id == "1")
        #expect(result.nodes.first?.name == "Two")
        #expect(result.cursor == "next")
        #expect(result.hasNextPage)
        #expect(result.remaining == 4_000)
    }
}
