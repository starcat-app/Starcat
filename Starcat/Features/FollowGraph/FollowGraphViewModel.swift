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
    private(set) var snapshot: FollowGraphSnapshot? {
        didSet {
            if oldValue?.relation != snapshot?.relation || oldValue?.edges != snapshot?.edges {
                cachedRelationCounts = relationCounts(in: snapshot)
            }
        }
    }
    private(set) var displayedSnapshot: FollowGraphSnapshot?
    private var expandedSources: [String: Int] = [:]
    private(set) var renderedCounts: (nodes: Int, edges: Int)?
    private(set) var renderedSelectedCount: Int?
    private(set) var selectionRevision = 0
    private(set) var isLoading = false
    private(set) var isPreparing = false
    private(set) var statusKey = "followGraph.status.ready"
    private(set) var errorText: String?
    var toastMessage: String?
    private(set) var toastIsError = false
    private(set) var revision = 0
    private(set) var avatarUpdate: (revision: Int, id: String, source: String)?
    private var avatarRevision = 0
    private(set) var followState = FollowGraphFollowState()
    var selectedID: String? {
        didSet {
            // 成功通知只在本次选中内去重；切走再回来仍需让卡片唤醒节点的缓存探测。
            if oldValue != selectedID {
                avatarUpdate = nil
                renderedSelectedCount = nil
                selectionRevision += 1
                rebuildSelectedPath()
            }
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
        didSet {
            rendererPresented = false
            renderedCounts = nil
            renderedSelectedCount = nil
        }
    }
    private let cache: FollowGraphDiskCache
    private var store: FollowGraphStore?
    private var stores: [FollowGraphRelation: FollowGraphStore] = [:]
    private var task: Task<Void, Never>?
    // 串行衔接范围写入；关闭后立即重开也必须先等最后一次预算保存完成。
    private var rangeSaveTask: Task<Void, Never>?
    private var generation = UUID()
    // Index lifetimes follow graph topology, not 30Hz rendered-count observations.
    // Published path content remains observable; index internals need not invalidate views.
    @ObservationIgnored private var cachedRelationCounts: [String: Int] = [:]
    @ObservationIgnored private var displayedRelationCounts: [String: Int] = [:]
    @ObservationIgnored private var pathParents: [String: String] = [:]
    private var selectedPath: [String] = []

    /// 测试可注入独立目录，不接触真实登录账户的图谱缓存。
    init(cache: FollowGraphDiskCache = .shared) {
        self.cache = cache
    }

    var selected: FollowGraphNode? { selectedID.flatMap { displayedSnapshot?.nodes[$0] } }
    var path: [String] { selectedPath }
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
        expandedSources = [:]
        resetCanvas()
        // 同账户重开沿用 Store，卡片关闭后仍在进行的关注确认可以写回同一份关系。
        if store == nil {
            store = FollowGraphStore(provider: FollowGraphAPI(client: client, relation: relation), cache: cache)
            stores[relation] = store
        }
        isLoading = true
        isPreparing = true
        errorText = nil
        statusKey = "followGraph.status.loading"
        task = Task {
            await rangeSaveTask?.value
            guard !Task.isCancelled, generation == session else { return }
            let cached = await cache.load(account: root.id, relation: relation)
            let savedRange = await cache.loadRange(account: root.id, relation: relation)
            guard !Task.isCancelled, generation == session else { return }
            if let cached, cached.savedAt > (snapshot?.savedAt ?? .distantPast) ||
                (snapshot?.nodes.count ?? 0) <= 1 { snapshot = cached }
            guard let store, let snapshot else { return }
            let current = await store.begin(snapshot, session: session)
            guard !Task.isCancelled, generation == session else { return }
            // 只恢复已缓存图中的预算；账户切换、缓存清理后的孤立范围不能触发隐式网络展开。
            if let savedRange {
                expandedSources = savedRange.expandedSources.filter { current.nodes[$0.key] != nil }
            }
            publish(current, session: session)
            isPreparing = false
            // Followers 旧快照可能只有本人首层，只补缺少的默认样本；满足预算后重开纯读缓存。
            if current.progress.isEmpty || (savedRange == nil && relation == .followers && current.needsDefaultExpansion) {
                await explore(session: session, store: store)
            }
            else {
                isLoading = false
                statusKey = "followGraph.status.ready"
            }
        }
    }

    /// 重建临时画布以重播入场；展示预算与视角生命周期分离，重开不再丢失手动展开。
    func resetCanvas() {
        toastMessage = nil
        avatarUpdate = nil
        selectedID = nil
        viewport = nil
        focusID = nil
        search = ""
        rendererError = false
        rendererRevision += 1
        rebuildPresentation()
    }

    /// 只能由二次确认入口调用。丢弃当前方向的展示预算，保留完整关系与头像缓存；
    /// rendererRevision 使新 WebView 从本人重播，不能复用旧 reveal 队列。
    func initialize() {
        guard !isPreparing, let snapshot else { return }
        stop()
        expandedSources = [:]
        errorText = nil
        statusKey = "followGraph.status.ready"
        resetCanvas()
        saveRange()
        if snapshot.progress.isEmpty || snapshot.needsDefaultExpansion {
            run { session, store in await self.explore(session: session, store: store) }
        }
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
        saveRange()
        toastMessage = nil
        generation = UUID()
        task?.cancel()
        task = nil
        isLoading = false
        isPreparing = false
        statusKey = "followGraph.status.stopped"
    }

    /// 捕获当前账户与方向再异步写入，不能让切换后的身份污染上一方向的预算。
    private func saveRange() {
        guard let snapshot, !snapshot.progress.isEmpty else { return }
        let range = FollowGraphSavedRange(expandedSources: expandedSources)
        let accountID = snapshot.accountID
        let relation = snapshot.relation
        let previous = rangeSaveTask
        let cache = cache
        rangeSaveTask = Task {
            await previous?.value
            do { try await cache.saveRange(range, account: accountID, relation: relation) }
            catch {
                // 缓存写入失败不能打断关闭或网络操作，但须留下可诊断证据。
                NSLog("FollowGraph range cache write failed: %@", error.localizedDescription)
            }
        }
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

    /// 两种方向的节点选择都只更新资料卡和路径；展开预算只能由“加载更多”修改。
    func select(_ id: String?) {
        guard id == nil || snapshot?.nodes[id!] != nil else { return }
        selectedID = id
        if let id { recordDiagnosticState(id, stage: "selection") }
    }

    func focus(_ id: String?) {
        focusID = id
        // 定位/重置覆盖旧视口，重开图谱时不能再恢复上一次手势的位置。
        viewport = nil
        viewportRevision += 1
    }

    /// 缓存先展开，再以接口的末页标记决定是否继续请求；交叉边和变化中的总数
    /// 不能代替 hasNextPage，否则人数碰巧达到总数时会提前丢失分页入口。
    func canLoadMore(_ id: String, fallbackTotal: Int? = nil) -> Bool {
        guard let snapshot, let displayedSnapshot, displayedSnapshot.nodes[id] != nil else { return false }
        let visible = displayedRelationCounts[id] ?? 0
        if (cachedRelationCounts[id] ?? 0) > visible { return true }
        if let progress = snapshot.progress[id] { return !progress.complete }
        return fallbackTotal.map { visible < $0 } ?? true
    }

    /// 卡片人数来自 Canvas。末页已到但头像仍在入场时保留禁用入口，
    /// 避免出现“78 / 87”且按钮已经消失；可请求性仍由 canLoadMore 独立决定。
    func showsLoadMore(_ id: String, fallbackTotal: Int? = nil) -> Bool {
        canLoadMore(id, fallbackTotal: fallbackTotal) || isRevealingRelations(for: id)
    }

    /// 末页仅表示游标用尽，不保证去重后的关系数等于接口总数。
    /// 保留真实总数并允许显式重读，不能伪造人数或反复请求已结束的游标。
    func needsRelationReload(_ id: String) -> Bool {
        guard let progress = snapshot?.progress[id], progress.complete else { return false }
        return (cachedRelationCounts[id] ?? 0) < progress.totalCount
    }

    /// 本批正在逐个入场时不叠加下一批，避免连续点击一次排入数百个头像。
    func isRevealingRelations(for id: String) -> Bool {
        selectedID == id && renderedRelationCount(for: id) < (displayedRelationCounts[id] ?? 0)
    }

    /// 单页手动加载不会继续递归；优先展示缓存，完成或无效动作不再重复读取第一页。
    func loadMore(_ id: String, fallbackTotal: Int? = nil) {
        guard !isLoading, let snapshot, displayedSnapshot?.nodes[id] != nil else { return }
        recordDiagnosticState(id, stage: "loadRequested", fallbackTotal: fallbackTotal)
        toastMessage = nil
        guard canLoadMore(id, fallbackTotal: fallbackTotal) else {
            showToast("followGraph.toast.complete")
            return
        }
        let before = displayedSnapshot
        let visibleCount = displayedSnapshot?.relationCount(for: id) ?? 0
        let cachedCount = snapshot.relationCount(for: id)
        // 每次点击只加一页预算；不再有全局容量上限，最终受 API 配额与本机性能约束。
        expandedSources[id] = max(expandedSources[id] ?? snapshot.defaultExpansionBudgets[id] ?? 0, visibleCount) + 50
        saveRange()
        if cachedCount > visibleCount {
            rebuildPresentation()
            reportLoadResult(id, before: before)
            return
        }
        run { session, store in
            do {
                let result = try await store.load(userID: id, session: session)
                guard self.generation == session, !Task.isCancelled else { return }
                self.publish(result, session: session)
                self.reportLoadResult(id, before: before)
            }
            catch { await self.handle(error, session: session, store: store) }
        }
    }

    /// 只重读选中用户的关系，沿用手动展开预算和 Store 的分页、配额及会话保护；
    /// 不把一次纠错刷新扩大为整个图谱的递归采集。
    func reloadRelations(_ id: String) {
        guard !isLoading, needsRelationReload(id), let snapshot,
              displayedSnapshot?.nodes[id] != nil else { return }
        let before = displayedSnapshot
        let budget = max(expandedSources[id] ?? snapshot.defaultExpansionBudgets[id] ?? 0,
                         displayedRelationCounts[id] ?? 0) + 50
        expandedSources[id] = budget
        saveRange()
        run { session, store in
            do {
                let result = try await store.load(userID: id, session: session, count: 100,
                                                  refresh: true, refreshLimit: budget)
                guard self.generation == session, !Task.isCancelled else { return }
                self.publish(result, session: session)
                self.reportLoadResult(id, before: before)
            } catch { await self.handle(error, session: session, store: store) }
        }
    }

    /// 正常新增由节点与动态数字表达；仅无新增头像时解释结果，避免每页成功都弹提示。
    private func reportLoadResult(_ id: String, before: FollowGraphSnapshot?) {
        guard let displayedSnapshot else { return }
        recordDiagnosticState(id, stage: "pageMerged")
        if needsRelationReload(id) {
            showToast("followGraph.status.countMismatch", isError: true)
            return
        }
        if displayedSnapshot.nodes.keys.contains(where: { before?.nodes[$0] == nil }) { return }
        if displayedSnapshot.relationCount(for: id) > (before?.relationCount(for: id) ?? 0) {
            showToast("followGraph.toast.relationshipsAdded")
        } else if !canLoadMore(id) {
            showToast("followGraph.toast.complete")
        } else {
            showToast("followGraph.toast.alreadyVisible")
        }
    }

    /// 复用底部 Toast；同一时刻只有一条，生命周期与自动关闭由现有组件管理。
    private func showToast(_ key: String, isError: Bool = false) {
        toastIsError = isError
        toastMessage = key
    }

    func refresh() {
        run { session, store in
            guard let displayed = self.displayedSnapshot else { return }
            // 独立继续按钮已移除。首次采集在第一页前停止或失败时，也必须能由刷新恢复。
            guard displayed.progress[displayed.rootID] != nil else {
                await self.explore(session: session, store: store)
                self.reportRefreshResult(before: displayed, session: session)
                return
            }
            let budgets = self.snapshot?.defaultExpansionBudgets ?? [:]
            let ids = displayed.progress.keys.filter {
                displayed.relation == .following || $0 == displayed.rootID ||
                    (budgets[$0] ?? 0) > 0 || self.expandedSources[$0] != nil
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
                            max(1, min(counts[id] ?? budgets[id] ?? 0,
                                       self.expandedSources[id] ?? budgets[id] ?? 0))
                    ), session: session)
                }
                catch {
                    allSucceeded = false
                    await self.handle(error, session: session, store: store)
                    if error is FollowGraphStoreError { break }
                }
            }
            guard allSucceeded, self.generation == session, !Task.isCancelled else { return }
            do {
                guard let value = try await store.finishRefresh(session: session),
                      self.generation == session, !Task.isCancelled else { return }
                self.publish(value, session: session)
                if let selectedID = self.selectedID, value.nodes[selectedID] == nil { self.selectedID = nil }
                if value.relation == .followers, value.needsDefaultExpansion {
                    await self.explore(session: session, store: store)
                }
                self.reportRefreshResult(before: displayed, session: session)
            } catch { await self.handle(error, session: session, store: store) }
        }
    }

    /// 只比较刷新前后展示图的净变化；分页重复、隐藏缓存及资料更新不冒充新增用户。
    /// 失败或取消后的迟到收尾不能覆盖错误 Toast，也不能污染已重开的图谱。
    private func reportRefreshResult(before: FollowGraphSnapshot, session: UUID) {
        guard generation == session, !Task.isCancelled, errorText == nil,
              statusKey == "followGraph.status.loading" || statusKey == "followGraph.status.ready",
              let after = displayedSnapshot, before.accountID == after.accountID,
              before.relation == after.relation else { return }
        let previousUsers = Set(before.nodes.keys), currentUsers = Set(after.nodes.keys)
        let addedUsers = currentUsers.subtracting(previousUsers).count
        let removedUsers = previousUsers.subtracting(currentUsers).count
        let addedEdges = after.edges.subtracting(before.edges).count
        let removedEdges = before.edges.subtracting(after.edges).count
        if addedUsers + removedUsers + addedEdges + removedEdges == 0 {
            showToast("followGraph.toast.refreshUnchanged")
        } else {
            showToast(String(format: String.l10n("followGraph.toast.refreshed"),
                             locale: LocaleStore.shared.selection.effectiveLocale,
                             Int64(addedUsers), Int64(removedUsers), Int64(addedEdges), Int64(removedEdges)))
        }
    }

    private func run(_ operation: @escaping @MainActor (UUID, FollowGraphStore) async -> Void) {
        guard !isLoading, let store, let snapshot else { return }
        task?.cancel()
        generation = UUID()
        let session = generation
        isLoading = true
        toastMessage = nil
        errorText = nil
        statusKey = "followGraph.status.loading"
        task = Task {
            let diagnostic = DiagnosticOperation(category: "followGraph", name: "expandOrRefresh")
            defer {
                diagnostic.finish(Task.isCancelled ? .cancelled : errorText != nil ? .partial : .succeeded)
            }
            let current = await store.begin(snapshot, session: session)
            guard !Task.isCancelled, generation == session else { return }
            publish(current, session: session)
            await DiagnosticContext.$current.withValue(diagnostic) { await operation(session, store) }
            guard generation == session else { return }
            isLoading = false
            if errorText == nil && statusKey == "followGraph.status.loading" {
                statusKey = "followGraph.status.ready"
            }
        }
    }

    /// 根分页优先，再按方向预算采集第三层；每批四个，避免请求风暴。
    private func explore(session: UUID, store: FollowGraphStore) async {
        guard generation == session, let rootID = snapshot?.rootID else { return }
        isLoading = true
        statusKey = "followGraph.status.loading"
        defer { if generation == session { isLoading = false } }
        do {
            while snapshot?.progress[rootID]?.complete != true {
                publish(try await store.load(userID: rootID, session: session, count: 100), session: session)
            }
            guard let current = snapshot else { return }
            let counts = Dictionary(grouping: current.edges, by: { $0[keyPath: current.relation.ownerKey] })
                .mapValues(\.count)
            let budgets = current.defaultExpansionBudgets
            let firstLevel = budgets.keys.filter {
                (budgets[$0] ?? 0) > (counts[$0] ?? 0) && current.progress[$0]?.complete != true
            }.sorted()
            for start in stride(from: 0, to: firstLevel.count, by: 4) {
                try Task.checkCancellation()
                if (snapshot?.nodes.count ?? 0) >= 5_000 {
                    statusKey = "followGraph.status.limit"
                    // 自动探索软停是正常设计，不是错误；用户仍可通过选中节点继续展开。
                    showToast(statusKey)
                    return
                }
                let batch = Array(firstLevel[start..<min(start + 4, firstLevel.count)])
                let errors = await withTaskGroup(of: String?.self, returning: [String].self) { group in
                    for id in batch {
                        let count = (budgets[id] ?? 0) - (counts[id] ?? 0)
                        group.addTask {
                            do { _ = try await store.load(userID: id, session: session, count: count); return nil }
                            catch is CancellationError { return nil }
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
                    if reason == "followGraph.status.quota" {
                        await showQuotaToast(store: store)
                    } else {
                        statusKey = reason
                        showToast(reason, isError: true)
                    }
                    return
                }
                if !errors.isEmpty {
                    statusKey = "followGraph.status.partial"
                    showToast("followGraph.toast.loadFailed", isError: true)
                }
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
        let previous = displayedSnapshot
        let next = snapshot?.presentation(expanded: expandedSources, selectedID: selectedID)
        // fetchedAt / cursor / totalCount 仍实时更新卡片，但不属于 Canvas 的图数据。
        // 否则刷新每个源都会发送整图并重启力导向，产生没有新增节点的抖动。
        let graphChanged = previous?.rootID != next?.rootID || previous?.relation != next?.relation ||
            previous?.nodes != next?.nodes || previous?.edges != next?.edges
        displayedSnapshot = next
        if previous?.rootID != next?.rootID || previous?.relation != next?.relation || previous?.edges != next?.edges {
            displayedRelationCounts = relationCounts(in: next)
            pathParents = next?.paths() ?? [:]
        }
        if let selectedID, displayedSnapshot?.nodes[selectedID] == nil { self.selectedID = nil }
        rebuildSelectedPath()
        if graphChanged {
            revision += 1
            renderedCounts = nil
        }
    }

    /// Build one direction-aware index rather than filtering all edges for every card label.
    private func relationCounts(in graph: FollowGraphSnapshot?) -> [String: Int] {
        guard let graph else { return [:] }
        return graph.edges.reduce(into: [:]) { counts, edge in
            counts[edge[keyPath: graph.relation.ownerKey], default: 0] += 1
        }
    }

    /// The BFS tree changes only with topology. Selection reconstruction is O(path length),
    /// and reading `path` during count animations does no graph traversal or sorting.
    private func rebuildSelectedPath() {
        guard let id = selectedID, let graph = displayedSnapshot, graph.nodes[id] != nil else {
            selectedPath = []
            return
        }
        guard id == graph.rootID || pathParents[id] != nil else {
            selectedPath = []
            return
        }
        var path = [id]
        while let parent = pathParents[path.last!] { path.append(parent) }
        let next = graph.relation == .following ? Array(path.reversed()) : path
        if selectedPath != next { selectedPath = next }
    }

    /// 新分页尚在逐个入场时继续保留已绘制人数，不提前跳到整页数量。
    func renderedRelationCount(for id: String) -> Int {
        guard selectedID == id else { return 0 }
        return min(renderedSelectedCount ?? 0, displayedRelationCounts[id] ?? 0)
    }

    /// 图版本、画布身份与选择版本各自校验；仅比较用户 ID 无法拒绝 A → B → A 的旧消息。
    /// 更新人数不改变图 revision，避免 SwiftUI 更新反向重发整图或重启入场动画。
    func reportRenderedCounts(nodes: Int, edges: Int, revision: Int, renderer: Int,
                              selectedID: String?, selectionRevision: Int, selectedCount: Int) {
        guard renderer == rendererRevision, revision == self.revision, let displayedSnapshot,
              (0...displayedSnapshot.nodes.count).contains(nodes),
              (0...displayedSnapshot.edges.count).contains(edges) else { return }
        if renderedCounts?.nodes != nodes || renderedCounts?.edges != edges {
            renderedCounts = (nodes, edges)
        }
        guard selectedID == self.selectedID, selectionRevision == self.selectionRevision,
              let selectedID, (0...min(edges, displayedRelationCounts[selectedID] ?? 0)).contains(selectedCount)
        else { return }
        if renderedSelectedCount != selectedCount { renderedSelectedCount = selectedCount }
        if selectedCount == (displayedRelationCounts[selectedID] ?? 0) {
            recordDiagnosticState(selectedID, stage: "renderConfirmed")
        }
    }

    /// 人数差异只保留观测值及按钮判定；账号、用户节点以会话内匿名引用关联。
    private func recordDiagnosticState(_ id: String, stage: String, fallbackTotal: Int? = nil) {
        guard let snapshot else { return }
        let progress = snapshot.progress[id]
        var fields: [String: DiagnosticValue] = [
            "stage": .string(stage),
            "relation": .string(snapshot.relation.rawValue),
            "cachedCount": .integer(cachedRelationCounts[id] ?? 0),
            "displayedCount": .integer(displayedRelationCounts[id] ?? 0),
            "renderedCount": .integer(renderedRelationCount(for: id)),
            "hasProgress": .boolean(progress != nil),
            "complete": .boolean(progress?.complete == true),
            "canLoadMore": .boolean(canLoadMore(id, fallbackTotal: fallbackTotal)),
            "budget": .integer(expandedSources[id] ?? snapshot.defaultExpansionBudgets[id] ?? 0),
            "snapshotVersion": .integer(revision),
            "rendererVersion": .integer(rendererRevision),
            "selectionVersion": .integer(selectionRevision),
            "nodeCount": .integer(displayedSnapshot?.nodes.count ?? 0),
            "edgeCount": .integer(displayedSnapshot?.edges.count ?? 0)
        ]
        if let total = progress?.totalCount ?? fallbackTotal { fields["totalCount"] = .integer(total) }
        DiagnosticContext.current?.capture(DiagnosticEvent(
            level: .info, category: "followGraph", operation: "presentation",
            message: "Graph relation evidence", context: ["user": id], phase: stage, fields: fields
        ))
    }

    private func handle(_ error: Error, session: UUID, store: FollowGraphStore) async {
        guard generation == session, !Task.isCancelled else { return }
        if let value = await store.read(session: session) { publish(value, session: session) }
        // actor 读取期间可能关闭或切换图谱，旧错误也不能在新窗口弹出 Toast。
        guard generation == session, !Task.isCancelled else { return }
        switch error {
        case FollowGraphStoreError.quota(let resetAt):
            showQuotaToast(resetAt: resetAt)
        case FollowGraphStoreError.authentication:
            statusKey = "network.error.unauthorized"
            showToast(statusKey, isError: true)
        case FollowGraphStoreError.staleSession, is CancellationError: return
        default:
            statusKey = "followGraph.status.partial"
            errorText = error.localizedDescription
            showToast("followGraph.toast.loadFailed", isError: true)
        }
    }

    /// 探索路径的批量错误把配额错误折叠成状态键，这里再补一次真实恢复时间。
    private func showQuotaToast(store: FollowGraphStore) async {
        let resetAt = await store.quotaResetAt
        showQuotaToast(resetAt: resetAt?.ISO8601Format() ?? "")
    }

    /// 配额停止必须展示真实恢复时间；解析失败时保留原文，不能伪造时间误导用户。
    private func showQuotaToast(resetAt: String) {
        statusKey = "followGraph.status.quota"
        let locale = LocaleStore.shared.selection.effectiveLocale
        let date = ISO8601DateFormatter().date(from: resetAt)
        let time: String
        if let date {
            let formatter = DateFormatter()
            formatter.locale = locale
            // medium 在所有支持语言里都带完整年份，用户能直接看懂恢复时间。
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            time = formatter.string(from: date)
        } else {
            time = resetAt
        }
        showToast(String(format: String.l10n("followGraph.toast.quotaReset"), locale: locale, time), isError: true)
    }
}
