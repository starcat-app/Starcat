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
    private(set) var sources: [AwesomeSource] = []
    private(set) var repositories: [AwesomeRepositoryItem] = []
    private(set) var totalAvailableRepositoryCount = 0
    private(set) var hasCompletedSourceSetup = false
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var sourceRefreshErrors: [String: String] = [:]

    var selectedSourceID: String?
    var selectedRepositoryID: Int64?
    var isSourceManagerPresented = false

    private let repository: any AwesomeRepositoryProtocol
    private let customSourceService: AwesomeCustomSourceService
    private var loadTask: Task<Void, Never>?
    private var selectionLoadTask: Task<Void, Never>?

    init(
        repository: any AwesomeRepositoryProtocol,
        customSourceService: AwesomeCustomSourceService
    ) {
        self.repository = repository
        self.customSourceService = customSourceService
    }

    var enabledSources: [AwesomeSource] { sources.filter(\.isEnabled) }
    var selectedRepository: AwesomeRepositoryItem? {
        guard let selectedRepositoryID else { return nil }
        return repositories.first { $0.id == selectedRepositoryID }
    }
    var totalRepositoryCount: Int { totalAvailableRepositoryCount }

    func enterAwesome() async {
        loadTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            self.isLoading = self.sources.isEmpty
            await self.loadCachedState()
            guard !Task.isCancelled else { return }
            if !self.hasCompletedSourceSetup {
                self.isSourceManagerPresented = true
            }
            await self.refreshCatalogAndEntries()
            self.isLoading = false
        }
        loadTask = task
        await task.value
    }

    func presentSourceManager() async {
        await loadCachedState()
        isSourceManagerPresented = true
        do {
            sources = try await repository.refreshCatalog()
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

    func previewCustomSource(input: String) async throws -> AwesomeCustomSourcePreview {
        try await customSourceService.preview(input: input)
    }

    func addCustomSource(_ preview: AwesomeCustomSourcePreview) async throws {
        try await customSourceService.save(preview)
        sources = await repository.sources()
        await reloadRepositories()
    }

    func removeCustomSource(id: String) async throws {
        try await customSourceService.remove(sourceID: id)
        if selectedSourceID == id { selectedSourceID = nil }
        sources = await repository.sources()
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

    func refresh() async {
        await refreshCatalogAndEntries(policy: .force)
    }

    /// 当前账户数据库是 Awesome 订阅和自定义来源的隔离边界。切库时必须先清掉旧快照，
    /// 不能等下一次进入页面再覆盖，否则新账户可能短暂看到上一账户的来源名称。
    func resetForAccountChange() {
        loadTask?.cancel()
        loadTask = nil
        selectionLoadTask?.cancel()
        selectionLoadTask = nil
        sources = []
        repositories = []
        totalAvailableRepositoryCount = 0
        hasCompletedSourceSetup = false
        isLoading = false
        isRefreshing = false
        errorMessage = nil
        sourceRefreshErrors = [:]
        selectedSourceID = nil
        selectedRepositoryID = nil
        isSourceManagerPresented = false
    }

    private func loadCachedState() async {
        async let cachedSources = repository.sources()
        async let completed = repository.hasCompletedSourceSetup()
        sources = await cachedSources
        hasCompletedSourceSetup = await completed
        await reloadRepositories()
    }

    private func refreshCatalogAndEntries(policy: AwesomeRefreshPolicy = .ifStale) async {
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            sources = try await repository.refreshCatalog(policy: policy)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        sourceRefreshErrors = await repository.refreshEnabledEntries(policy: policy)
        guard !Task.isCancelled else { return }
        sources = await repository.sources()
        await reloadRepositories()
    }

    private func reloadAfterSubscriptionChange() async {
        sources = await repository.sources()
        sourceRefreshErrors = await repository.refreshEnabledEntries()
        sources = await repository.sources()
        await reloadRepositories()
    }

    private func reloadRepositories() async {
        let requestedSourceID = selectedSourceID
        async let visibleRepositories = repository.repositories(sourceID: requestedSourceID)
        async let allRepositories = repository.repositories(sourceID: nil)
        let (visible, all) = await (visibleRepositories, allRepositories)
        // GRDB/测试替身不保证响应取消；旧选择即使晚返回，也不能覆盖当前来源。
        guard !Task.isCancelled, selectedSourceID == requestedSourceID else { return }
        repositories = visible
        totalAvailableRepositoryCount = all.count
        if let selectedRepositoryID,
           !repositories.contains(where: { $0.id == selectedRepositoryID }) {
            self.selectedRepositoryID = nil
        }
    }
}
