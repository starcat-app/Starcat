//
//  AwesomeStore.swift
//  Starcat
//
//  探索 → Awesome 的会话级状态容器，供左栏、中栏、右栏和来源管理 Sheet 共享。
//
//  Store 只协调 cached-first 展示与刷新，不复制 Repository 的持久化规则。首次设置状态只有
//  `completeSourceSelection` 会写入；Sheet 关闭只改变展示状态，保证下次进入仍会自动弹出。
//

import Foundation
import Observation

@MainActor
@Observable
final class AwesomeStore {
    /// 与主 Repo List 保持一致，首屏只读取 40 条；距离页尾 10 行时预取下一页。
    static let repositoryPageSize = 40

    private(set) var sources: [AwesomeSource] = []
    private(set) var repositories: [AwesomeRepositoryItem] = []
    private(set) var resources: [AwesomeResourceItem] = []
    private(set) var repositorySections: [String] = []
    private(set) var repositoryTotalCount = 0
    private(set) var hasMoreRepositories = false
    private(set) var isLoadingMoreRepositories = false
    private(set) var hasCompletedSourceSetup = false
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var isCatalogRefreshing = false
    /// 仅用户点刷新后递增，卡片据此清掉上一次真失败标记再试缓存；不当 KFImage 的 identity。
    private(set) var ogPrefetchGeneration = 0
    private(set) var errorMessage: String?
    private(set) var sourceRefreshErrors: [String: String] = [:]
    private(set) var customSourceParseStates: [String: AwesomeCustomSourceParseState] = [:]

    var selectedSourceID: String?
    var selectedRepositoryID: Int64?
    var isSourceManagerPresented = false
    /// 每次弹出 Sheet 递增；卡片用来重放入场「模糊→清晰」，避免 macOS 复用 Sheet 内容时跳过动画。
    private(set) var sourceManagerPresentationGeneration = 0

    private let repository: any AwesomeRepositoryProtocol
    private let customSourceService: AwesomeCustomSourceService
    private var loadTask: Task<Void, Never>?
    private var selectionLoadTask: Task<Void, Never>?
    private var customSourceParseTasks: [String: Task<Void, Never>] = [:]

    init(
        repository: any AwesomeRepositoryProtocol,
        customSourceService: AwesomeCustomSourceService
    ) {
        self.repository = repository
        self.customSourceService = customSourceService
    }

    /// 侧栏和“全部 Awesome”只消费当前仍可用的已启用来源。
    /// 远端下架的 managed 行仍保留在数据库和设置面板中，但不能继续占据导航入口。
    var enabledSources: [AwesomeSource] {
        sources.filter { $0.isEnabled && $0.isAvailable }
    }
    var selectedRepository: AwesomeRepositoryItem? {
        guard let selectedRepositoryID else { return nil }
        return repositories.first { $0.id == selectedRepositoryID }
    }
    /// “Awesome”主分类和“全部 Awesome”表达所有已启用来源的条目总和。
    /// 产品口径不做跨来源去重，也不随当前来源选择变化。
    var allRepositoryCount: Int {
        enabledSources.reduce(0) { $0 + $1.totalEntryCount }
    }
    /// 当前来源的总数必须来自该来源自己的目录元数据，不能误用全部来源条目总和。
    /// 后者只适用于“全部 Awesome”；混用会把 awesome-react 显示成 `2 / 267`。
    var currentRepositoryCount: Int {
        guard let selectedSourceID,
              let source = enabledSources.first(where: { $0.id == selectedSourceID })
        else { return allRepositoryCount }
        return source.totalEntryCount
    }

    /// 只恢复侧边栏计数依赖的本地来源摘要，不触发目录或条目网络刷新。
    ///
    /// Awesome 来源和启用状态按账户数据库隔离；登录完成后先恢复这份轻量快照，
    /// 用户无需进入 Awesome 页面也能看到正确数量。二次判空用于避免并发的完整加载
    /// 已经写入新来源后，又被较早发起的缓存读取覆盖。
    func restoreCachedSidebarSources() async {
        guard sources.isEmpty else { return }
        let cachedSources = await repository.sources()
        guard sources.isEmpty else { return }
        applySourceSnapshot(cachedSources)
    }

    /// 加载 Awesome 本地快照并按缓存策略刷新，不触发任何页面展示副作用。
    ///
    /// SwiftUI 的 `.task`、账户数据库切换和导航恢复都会调用这个入口；这些生命周期
    /// 事件不等同于用户点击 Awesome 分类，因此不能擅自打开来源选择 Sheet。
    func loadAwesome() async {
        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            self.isLoading = self.sources.isEmpty
            await self.loadCachedState()
            guard !Task.isCancelled else { return }
            await self.refreshCatalogAndEntries()
            self.isLoading = false
        }
        loadTask = task
        await task.value
    }

    /// 响应用户明确点击 Awesome 分类；首次配置尚未完成时自动打开来源选择 Sheet。
    ///
    /// 首次状态判断刻意放在可取消的后台刷新任务之外。分类点击与 `AwesomeView.task`
    /// 可能同时发生，后者可以取消重复刷新，但不能吞掉已经发生的用户展示意图。
    func enterAwesomeFromUserSelection() async {
        await loadCachedState()
        if !hasCompletedSourceSetup {
            showSourceManager()
        }
        await loadAwesome()
    }

    func presentSourceManager() async {
        await loadCachedState()
        showSourceManager()
        do {
            let selectionInvalidated = applySourceSnapshot(try await repository.refreshCatalog())
            if selectionInvalidated {
                await reloadRepositories()
            }
            errorMessage = nil
        } catch {
            // 已有缓存卡片继续展示；错误由 Sheet 作为非阻断提示呈现。
            errorMessage = error.localizedDescription
        }
    }

    func dismissSourceManager() {
        isSourceManagerPresented = false
    }

    func completeSourceSelection(_ enabledIDs: Set<String>) async throws {
        try await repository.completeSourceSetup(enabledSourceIDs: enabledIDs)
        hasCompletedSourceSetup = true
        isSourceManagerPresented = false
        await reloadAfterSubscriptionChange()
    }

    func updateSourceSelection(_ enabledIDs: Set<String>) async throws {
        try await repository.updateSubscriptions(enabledSourceIDs: enabledIDs)
        isSourceManagerPresented = false
        await reloadAfterSubscriptionChange()
    }

    /// 快速核验来源仓库后立即返回，让 Sheet 当场显示卡片；README 解析由独立任务继续，
    /// 不再把输入框的 loading 状态绑定到几百个 GitHub 请求。
    func addCustomSource(input: String) async throws -> AwesomeSource {
        let creation = try await customSourceService.create(input: input)
        applySourceSnapshot(await repository.sources())
        customSourceParseStates[creation.source.id] = AwesomeCustomSourceParseState(
            sourceID: creation.source.id,
            phase: .queued,
            processedCount: 0,
            totalCount: nil,
            errorMessage: nil,
            updatedAt: creation.source.updatedAt
        )
        startCustomSourceParsing(creation.source, defaultBranch: creation.defaultBranch)
        return creation.source
    }

    func retryCustomSourceParsing(sourceID: String) {
        guard let source = sources.first(where: { $0.id == sourceID && $0.kind == .custom }) else { return }
        startCustomSourceParsing(source, force: true)
    }

    func removeCustomSource(id: String) async throws {
        customSourceParseTasks[id]?.cancel()
        customSourceParseTasks[id] = nil
        try await customSourceService.remove(sourceID: id)
        customSourceParseStates[id] = nil
        if selectedSourceID == id { selectedSourceID = nil }
        applySourceSnapshot(await repository.sources())
        await reloadRepositories()
    }

    /// 选中态必须在 List binding 的 setter 中同步落地，否则 SwiftUI 下一次读取 binding 时
    /// 会看到旧 sourceID 并把高亮弹回旧行。数据读取独立异步执行，并取消上一轮选择任务。
    func selectSource(_ sourceID: String?) {
        selectionLoadTask?.cancel()
        selectedSourceID = sourceID
        selectedRepositoryID = nil
        selectionLoadTask = Task { [weak self] in
            await self?.reloadRepositories()
        }
    }

    /// List 行进入预取区时追加下一页。使用 Repo ID 而不是数组 index，避免排序后的 UI
    /// 把瞬时 index 传回 Store 后又因新页插入而失效。
    func loadMoreRepositoriesIfNeeded(currentRepositoryID: Int64) async {
        guard hasMoreRepositories,
              !isLoadingMoreRepositories,
              let index = repositories.firstIndex(where: { $0.id == currentRepositoryID }),
              ListPaginationPolicy.shouldPrefetch(
                  appearingIndex: index,
                  itemCount: repositories.count,
                  hasMore: hasMoreRepositories
              )
        else { return }
        await loadRepositoryPage(append: true)
    }

    /// 搜索、非原始排序和需要全局事实的筛选必须在完整结果集上执行，不能把当前 40 条
    /// 当成全部数据。该入口只在用户真的启用这些能力时补齐剩余本地页，不发远端请求。
    func loadAllRepositoryPages() async {
        while hasMoreRepositories, !Task.isCancelled {
            // 用户开始搜索时，列表末尾可能恰好正在预取。等待该页回写后再继续，
            // 否则一次性的搜索 task 会提前返回，并把已加载前缀误当成完整结果。
            if isLoadingMoreRepositories {
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            await loadRepositoryPage(append: true)
        }
    }

    func refresh() async {
        await refreshCatalogAndEntries(policy: .force)
    }

    /// 来源管理 Sheet 打开时预拉全部 OG：Kingfisher 有缓存就跳过网络。
    /// 预拉成功不 bump generation，避免把已经显示的 KFImage 卸掉重挂。
    func prefetchOpenGraphImages() async {
        await AwesomeSourceOpenGraph.prefetch(urls: AwesomeSourceOpenGraph.imageURLs(for: sources))
    }

    /// 来源管理 Sheet 的刷新：Discovery 目录 与 OG 预拉并行。
    /// OG 仍走缓存优先，不 forceRefresh；小时键没变就不会打 GitHub CDN。
    /// 不连带刷新所有已订阅 README 条目。
    func refreshSourceCatalog() async {
        guard !isCatalogRefreshing else { return }
        isCatalogRefreshing = true
        defer { isCatalogRefreshing = false }

        let urlsBeforeRefresh = AwesomeSourceOpenGraph.imageURLs(for: sources)
        async let ogWarmup: Void = AwesomeSourceOpenGraph.prefetch(urls: urlsBeforeRefresh)
        do {
            let selectionInvalidated = applySourceSnapshot(
                try await repository.refreshCatalog(policy: .force)
            )
            if selectionInvalidated {
                await reloadRepositories()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await ogWarmup
        await AwesomeSourceOpenGraph.prefetch(urls: AwesomeSourceOpenGraph.imageURLs(for: sources))
        ogPrefetchGeneration += 1
    }

    /// 当前账户数据库是 Awesome 订阅和自定义来源的隔离边界。切库时必须先清掉旧快照，
    /// 不能等下一次进入页面再覆盖，否则新账户可能短暂看到上一账户的来源名称。
    func resetForAccountChange() {
        loadTask?.cancel()
        loadTask = nil
        selectionLoadTask?.cancel()
        selectionLoadTask = nil
        customSourceParseTasks.values.forEach { $0.cancel() }
        customSourceParseTasks = [:]
        sources = []
        repositories = []
        resources = []
        repositorySections = []
        repositoryTotalCount = 0
        hasMoreRepositories = false
        isLoadingMoreRepositories = false
        hasCompletedSourceSetup = false
        isLoading = false
        isRefreshing = false
        isCatalogRefreshing = false
        ogPrefetchGeneration = 0
        sourceManagerPresentationGeneration = 0
        errorMessage = nil
        sourceRefreshErrors = [:]
        customSourceParseStates = [:]
        selectedSourceID = nil
        selectedRepositoryID = nil
        isSourceManagerPresented = false
    }

    private func loadCachedState() async {
        async let cachedSources = repository.sources()
        async let completed = repository.hasCompletedSourceSetup()
        async let cachedParseStates = repository.customSourceParseStates()
        applySourceSnapshot(await cachedSources)
        hasCompletedSourceSetup = await completed
        let parseStates = await cachedParseStates
        customSourceParseStates = Dictionary(
            uniqueKeysWithValues: parseStates.map { ($0.sourceID, $0) }
        )
        await reloadRepositories()
        resumeActiveCustomSourceParses()
    }

    /// 来源快照更新时同步校正导航选择。下架、取消订阅或删除来源后，旧 sourceID
    /// 不能继续驱动中栏查询，否则侧栏虽已隐藏，列表仍会停留在一个空的失效来源上。
    @discardableResult
    private func applySourceSnapshot(_ snapshot: [AwesomeSource]) -> Bool {
        sources = snapshot
        guard let selectedSourceID,
              !enabledSources.contains(where: { $0.id == selectedSourceID })
        else { return false }

        selectionLoadTask?.cancel()
        selectionLoadTask = nil
        self.selectedSourceID = nil
        selectedRepositoryID = nil
        return true
    }

    /// 从关闭到打开才换 generation，避免 Sheet 已打开时 refreshCatalog 把入场动画重放一遍。
    private func showSourceManager() {
        if !isSourceManagerPresented {
            sourceManagerPresentationGeneration += 1
        }
        isSourceManagerPresented = true
    }

    private func refreshCatalogAndEntries(policy: AwesomeRefreshPolicy = .ifStale) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            applySourceSnapshot(try await repository.refreshCatalog(policy: policy))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        sourceRefreshErrors = await repository.refreshEnabledEntries(policy: policy)
        guard !Task.isCancelled else { return }
        applySourceSnapshot(await repository.sources())
        await reloadRepositories()
    }

    private func reloadAfterSubscriptionChange() async {
        applySourceSnapshot(await repository.sources())
        sourceRefreshErrors = await repository.refreshEnabledEntries()
        applySourceSnapshot(await repository.sources())
        await reloadRepositories()
    }

    private func reloadRepositories() async {
        isLoadingMoreRepositories = false
        await loadRepositoryPage(append: false)
    }

    private func loadRepositoryPage(append: Bool) async {
        if append, isLoadingMoreRepositories { return }
        let requestedSourceID = selectedSourceID
        let offset = append ? repositories.count : 0
        if append { isLoadingMoreRepositories = true }
        defer {
            if append { isLoadingMoreRepositories = false }
        }

        let page: AwesomeRepositoryPage
        let resourceItems: [AwesomeResourceItem]
        let sections: [String]
        if append {
            page = await repository.repositoryPage(
                sourceID: requestedSourceID,
                limit: Self.repositoryPageSize,
                offset: offset
            )
            resourceItems = resources
            sections = repositorySections
        } else {
            async let visiblePage = repository.repositoryPage(
                sourceID: requestedSourceID,
                limit: Self.repositoryPageSize,
                offset: offset
            )
            async let visibleResources = repository.resources(sourceID: requestedSourceID)
            async let visibleSections = repository.repositorySections(sourceID: requestedSourceID)
            (page, resourceItems, sections) = await (visiblePage, visibleResources, visibleSections)
        }
        // GRDB/测试替身不保证响应取消；旧选择即使晚返回，也不能覆盖当前来源。
        guard !Task.isCancelled, selectedSourceID == requestedSourceID else { return }
        if append {
            let existingIDs = Set(repositories.map(\.id))
            repositories.append(contentsOf: page.repositories.filter { !existingIDs.contains($0.id) })
        } else {
            repositories = page.repositories
            resources = resourceItems
            repositorySections = sections
        }
        repositoryTotalCount = page.totalCount
        hasMoreRepositories = page.hasMore
        if let selectedRepositoryID,
           !repositories.contains(where: { $0.id == selectedRepositoryID }) {
            self.selectedRepositoryID = nil
        }
    }

    private func resumeActiveCustomSourceParses() {
        for source in sources where source.kind == .custom {
            guard customSourceParseStates[source.id]?.isActive == true else { continue }
            startCustomSourceParsing(source)
        }
    }

    private func startCustomSourceParsing(
        _ source: AwesomeSource,
        defaultBranch: String? = nil,
        force: Bool = false
    ) {
        guard customSourceParseTasks[source.id] == nil else { return }
        if !force, customSourceParseStates[source.id]?.isActive != true { return }

        let sourceID = source.id
        customSourceParseTasks[sourceID] = Task { [weak self] in
            guard let self else { return }
            do {
                try await customSourceService.parse(
                    source: source,
                    defaultBranch: defaultBranch
                ) { [weak self] state in
                    await self?.applyCustomSourceParseState(state)
                }
            } catch is CancellationError {
                // 删除来源、切换账户或 Store 销毁时只停止任务；不把用户主动取消标成失败。
            } catch {
                AppLog.network.warning(
                    "Awesome custom source parsing failed for \(sourceID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
            customSourceParseTasks[sourceID] = nil
        }
    }

    private func applyCustomSourceParseState(_ state: AwesomeCustomSourceParseState) async {
        customSourceParseStates[state.sourceID] = state
        switch state.phase {
        case .enrichingRepositories, .completed:
            // Repository 每批会更新条目数；同步重读即可让卡片计数与中栏部分结果逐步增长。
            applySourceSnapshot(await repository.sources())
            await reloadRepositories()
        case .queued, .readingReadme, .failed:
            break
        }
    }
}
