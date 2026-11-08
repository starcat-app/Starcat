//
//  FollowGraphViewModel.swift
//  Starcat
//
//  主线程只拥有展示状态和任务入口；网络、磁盘及合并在 Store actor。
//  关闭 / 换账号后先废弃 generation，再取消任务，迟到 UI 回调不能复活旧画面。
//

import Foundation
import Observation

/// 每个主窗口持有自己的模型；不与推荐、每日热点或 Pro 权益共享状态。
@MainActor @Observable
final class FollowGraphViewModel {
    private(set) var snapshot: FollowGraphSnapshot?
    private(set) var displayedSnapshot: FollowGraphSnapshot?
    private var expandedSources: [String: Int] = [:]
    private(set) var renderedCounts: (nodes: Int, edges: Int)?
    private(set) var isLoading = false
    private(set) var statusKey = "followGraph.status.ready"
    private(set) var errorText: String?
    private(set) var revision = 0
    private(set) var avatarUpdate: (revision: Int, id: String, source: String)?
    private var avatarRevision = 0
    private(set) var followState = FollowGraphFollowState()
    var selectedID: String? {
        didSet {
            // 成功通知只在本次选中内去重；切走再回来仍需让卡片唤醒节点的缓存探测。
            if oldValue != selectedID { avatarUpdate = nil }
        }
    }
    var search = ""
    var viewport: FollowGraphViewport?
    var focusID: String?
    var viewportRevision = 0
    var rendererError = false
    var rendererPresented = false
    // 无论重开还是手动重载，都必须等新 WebView 的首帧；旧画面的可见状态不能复用。
    var rendererRevision = 0 {
        didSet { rendererPresented = false }
    }
    private let cache: FollowGraphDiskCache
    private var store: FollowGraphStore?
    private var stores: [FollowGraphRelation: FollowGraphStore] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()

    /// 测试可注入独立目录，不接触真实登录账户的图谱缓存。
    init(cache: FollowGraphDiskCache = .shared) {
        self.cache = cache
    }

    var selected: FollowGraphNode? { selectedID.flatMap { displayedSnapshot?.nodes[$0] } }
    var path: [String] { selectedID.flatMap { displayedSnapshot?.path(to: $0) } ?? [] }
    var results: [FollowGraphNode] {
        guard !search.isEmpty, let snapshot = displayedSnapshot else { return [] }
        return Array(snapshot.nodes.values.filter {
            $0.login.localizedCaseInsensitiveContains(search) ||
            ($0.name?.localizedCaseInsensitiveContains(search) ?? false)
        }.sorted { $0.login.localizedStandardCompare($1.login) == .orderedAscending }.prefix(50))
    }

    /// API 复用依赖装配中的真实 client，保留应用统一的授权失效回调。
    func open(user: GitHubUserDTO, client: GitHubAPIClient, relation: FollowGraphRelation = .following) {
        stop()
        let session = generation
        let root = FollowGraphNode(id: String(user.id), login: user.login, name: user.name, avatarURL: user.avatarUrl)
        if snapshot?.accountID != root.id {
            stores = [:]
            snapshot = nil
            followState = FollowGraphFollowState()
            store = nil
        }
        if snapshot?.relation != relation {
            snapshot = .init(root: root, relation: relation)
            // 空壳不能凭创建时间覆盖该方向 Store 中尚未落盘的有效快照。
            snapshot?.savedAt = .distantPast
        }
        store = stores[relation]
        resetCanvas()
        // 同账户重开沿用 Store，卡片关闭后仍在进行的关注确认可以写回同一份关系。
        if store == nil {
            store = FollowGraphStore(provider: FollowGraphAPI(client: client, relation: relation), cache: cache)
            stores[relation] = store
        }
        isLoading = true
        errorText = nil
        statusKey = "followGraph.status.loading"
        task = Task {
            let cached = await cache.load(account: root.id, relation: relation)
            guard !Task.isCancelled, generation == session else { return }
            if let cached, cached.savedAt > (snapshot?.savedAt ?? .distantPast) ||
                (snapshot?.nodes.count ?? 0) <= 1 { snapshot = cached }
            guard let store, let snapshot else { return }
            let current = await store.begin(snapshot, session: session)
            guard !Task.isCancelled, generation == session else { return }
            publish(current, session: session)
            // 已有快照先离线展示，由用户主动继续或刷新，避免每次重开消耗配额。
            if current.progress.isEmpty { await explore(session: session, store: store) }
            else {
                isLoading = false
                statusKey = "followGraph.status.ready"
            }
        }
    }

    /// 每次进入重新展示默认图谱；账户缓存和在途关注写入仍属于原来的 Store。
    func resetCanvas() {
        avatarUpdate = nil
        expandedSources = [:]
        selectedID = nil
        viewport = nil
        focusID = nil
        search = ""
        rendererError = false
        rendererRevision += 1
        rebuildPresentation()
    }

    /// 只刷新当前画布的当前选中用户；旧卡片的异步成功不能复活已关闭或换人的节点。
    func avatarDidLoad(nodeID: String, source: String, renderer: Int) {
        guard renderer == rendererRevision, selectedID == nodeID else { return }
        let local = FollowGraphAvatarURL.source(source)
        guard !local.isEmpty, avatarUpdate?.id != nodeID || avatarUpdate?.source != local else { return }
        avatarRevision += 1
        avatarUpdate = (avatarRevision, nodeID, local)
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        statusKey = "followGraph.status.stopped"
    }

    func clearAccount() {
        stop()
        avatarUpdate = nil
        snapshot = nil
        displayedSnapshot = nil
        renderedCounts = nil
        expandedSources = [:]
        store = nil
        stores = [:]
        selectedID = nil
        viewport = nil
        focusID = nil
        search = ""
        followState = FollowGraphFollowState()
    }

    /// 写请求由账户会话持有，切换节点不会重发；退出账户后不再写入原图谱。
    func toggleFollow(_ node: FollowGraphNode, service: OwnerFollowService) {
        guard let accountID = snapshot?.accountID, store != nil, node.id != accountID else { return }
        let state = followState
        Task {
            await state.toggle(node, service: service) { following in
                guard self.followState === state, self.snapshot?.accountID == accountID else { return }
                // 两方向保存同一条真实出边，分页状态仍各自独立。磁盘失败不能
                // 阻止内存确认；逐个 Store 的 revision 保护正在执行的旧分页响应。
                var failure: Error?
                do { try await self.cache.setFollowing(following, node: node, accountID: accountID) }
                catch { failure = error }
                for relation in FollowGraphRelation.allCases {
                    guard self.followState === state else { return }
                    guard let target = self.stores[relation],
                          await target.read(accountID: accountID) != nil else { continue }
                    do {
                        let value = try await target.setFollowing(following, node: node, accountID: accountID)
                        guard self.followState === state else { return }
                        if self.store === target { self.publish(value, session: self.generation) }
                    } catch {
                        failure = error
                        if let value = await target.read(accountID: accountID),
                           self.followState === state, self.store === target {
                            self.publish(value, session: self.generation)
                        }
                    }
                }
                guard self.followState === state else { return }
                if let failure { self.errorText = failure.localizedDescription }
            }
        }
    }

    func select(_ id: String?, expand: Bool) {
        guard id == nil || snapshot?.nodes[id!] != nil else { return }
        selectedID = id
        if expand, snapshot?.relation == .following, let id, snapshot?.progress[id] == nil, !isLoading { loadMore(id) }
    }

    func focus(_ id: String?) {
        focusID = id
        // 定位/重置覆盖旧视口，重开图谱时不能再恢复上一次手势的位置。
        viewport = nil
        viewportRevision += 1
    }

    /// 单页手动加载不会继续递归，也不会因为查找定位而触发。
    func loadMore(_ id: String) {
        guard !isLoading, let snapshot else { return }
        let visibleCount = displayedSnapshot?.relationCount(for: id) ?? 0
        let cachedCount = snapshot.relationCount(for: id)
        expandedSources[id] = max(expandedSources[id] ?? snapshot.relation.defaultSampleCount, visibleCount) + 50
        if cachedCount > visibleCount {
            rebuildPresentation()
            return
        }
        run { session, store in
            do { self.publish(try await store.load(userID: id, session: session), session: session) }
            catch { await self.handle(error, session: session, store: store) }
        }
    }

    func refresh() {
        run { session, store in
            guard let displayed = self.displayedSnapshot else { return }
            // 独立继续按钮已移除。首次采集在第一页前停止或失败时，也必须能由刷新恢复。
            guard displayed.progress[displayed.rootID] != nil else {
                await self.explore(session: session, store: store)
                return
            }
            let ids = displayed.progress.keys.filter {
                displayed.relation == .following || $0 == displayed.rootID || self.expandedSources[$0] != nil
            }.sorted()
            let counts = Dictionary(grouping: displayed.edges, by: { $0[keyPath: displayed.relation.ownerKey] }).mapValues(\.count)
            var allSucceeded = true
            // 刷新只覆盖当前展示预算，不能把二层样本翻页成数千个关注对象。
            for id in ids {
                guard !Task.isCancelled else { return }
                do {
                    self.publish(try await store.load(
                        userID: id, session: session, count: 100, refresh: true,
                        // 两种图谱均完整加载本人首层；停止后的刷新不能只重复已取得的半页。
                        refreshLimit: id == displayed.rootID ? nil :
                            max(1, min(counts[id] ?? displayed.relation.defaultSampleCount,
                                       self.expandedSources[id] ?? displayed.relation.defaultSampleCount))
                    ), session: session)
                }
                catch {
                    allSucceeded = false
                    await self.handle(error, session: session, store: store)
                    if error is FollowGraphStoreError { break }
                }
            }
            if allSucceeded, let value = try? await store.finishRefresh(session: session) {
                self.publish(value, session: session)
                if let selectedID = self.selectedID, value.nodes[selectedID] == nil { self.selectedID = nil }
            }
        }
    }

    private func run(_ operation: @escaping @MainActor (UUID, FollowGraphStore) async -> Void) {
        guard !isLoading, let store, let snapshot else { return }
        task?.cancel()
        generation = UUID()
        let session = generation
        isLoading = true
        errorText = nil
        statusKey = "followGraph.status.loading"
        task = Task {
            let current = await store.begin(snapshot, session: session)
            guard !Task.isCancelled, generation == session else { return }
            publish(current, session: session)
            await operation(session, store)
            guard generation == session else { return }
            isLoading = false
            if errorText == nil && statusKey == "followGraph.status.loading" {
                statusKey = "followGraph.status.ready"
            }
        }
    }

    /// 根分页优先，然后每位一级用户最多首批 20 条；每批四个，避免请求风暴。
    private func explore(session: UUID, store: FollowGraphStore) async {
        guard generation == session, let rootID = snapshot?.rootID else { return }
        isLoading = true
        statusKey = "followGraph.status.loading"
        defer { if generation == session { isLoading = false } }
        do {
            while snapshot?.progress[rootID]?.complete != true {
                publish(try await store.load(userID: rootID, session: session, count: 100), session: session)
            }
            // Followers 默认只完整分页本人首层，二层必须由资料卡显式展开。
            if snapshot?.relation == .followers {
                statusKey = "followGraph.status.ready"
                return
            }
            let firstLevel = Set(snapshot?.edges.filter { $0.source == rootID }.map(\.target) ?? [])
                .filter { snapshot?.progress[$0] == nil }.sorted()
            for start in stride(from: 0, to: firstLevel.count, by: 4) {
                try Task.checkCancellation()
                if (snapshot?.nodes.count ?? 0) >= 5_000 {
                    statusKey = "followGraph.status.limit"
                    return
                }
                let batch = Array(firstLevel[start..<min(start + 4, firstLevel.count)])
                let errors = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                    for id in batch {
                        group.addTask {
                            do { _ = try await store.load(userID: id, session: session, count: 20); return nil }
                            catch is CancellationError { return nil }
                            catch FollowGraphStoreError.budget { return "followGraph.status.limit" }
                            catch FollowGraphStoreError.quota { return "followGraph.status.quota" }
                            catch FollowGraphStoreError.authentication { return "network.error.unauthorized" }
                            catch { return "followGraph.status.partial" }
                        }
                    }
                    var values: [String] = []
                    for await result in group { if let result { values.append(result) } }
                    return values
                }
                guard generation == session, !Task.isCancelled else { return }
                if let value = await store.read(session: session) { publish(value, session: session) }
                if let reason = errors.first(where: { $0 != "followGraph.status.partial" }) {
                    statusKey = reason
                    return
                }
                if !errors.isEmpty { statusKey = "followGraph.status.partial" }
            }
            if statusKey == "followGraph.status.loading" { statusKey = "followGraph.status.ready" }
        } catch { await handle(error, session: session, store: store) }
    }

    private func publish(_ value: FollowGraphSnapshot, session: UUID) {
        guard generation == session, !Task.isCancelled,
              value.accountID == snapshot?.accountID, value.relation == snapshot?.relation,
              value.savedAt >= (snapshot?.savedAt ?? .distantPast) else { return }
        snapshot = value
        rebuildPresentation()
    }

    /// 只在图数据变化、关注确认或显式展开时更新展示快照。
    private func rebuildPresentation() {
        displayedSnapshot = snapshot?.presentation(expanded: expandedSources, selectedID: selectedID)
        if let selectedID, displayedSnapshot?.nodes[selectedID] == nil { self.selectedID = nil }
        revision += 1
        renderedCounts = nil
    }

    /// 只接受当前展示批次的真实绘制数量，迟到消息不能让顶部计数回退或越界。
    func reportRenderedCounts(nodes: Int, edges: Int, revision: Int) {
        guard revision == self.revision, let displayedSnapshot,
              (0...displayedSnapshot.nodes.count).contains(nodes),
              (0...displayedSnapshot.edges.count).contains(edges) else { return }
        if renderedCounts?.nodes != nodes || renderedCounts?.edges != edges {
            renderedCounts = (nodes, edges)
        }
    }

    private func handle(_ error: Error, session: UUID, store: FollowGraphStore) async {
        guard generation == session, !Task.isCancelled else { return }
        if let value = await store.read(session: session) { publish(value, session: session) }
        switch error {
        case FollowGraphStoreError.budget: statusKey = "followGraph.status.limit"
        case FollowGraphStoreError.quota: statusKey = "followGraph.status.quota"
        case FollowGraphStoreError.authentication: statusKey = "network.error.unauthorized"
        case FollowGraphStoreError.staleSession, is CancellationError: return
        default:
            statusKey = "followGraph.status.partial"
            errorText = error.localizedDescription
        }
    }
}
