//
//  LinuxDoStore.swift
//  Starcat
//
//  将当前服务的目录摘要、分页结果和跨分类来源证明分别发布给界面。
//

import Foundation
import Observation

struct LinuxDoProvenanceKey: Hashable {
    let providerID: String
    let revision: Int64
    let checkedAt: Date
}

/// 目录恢复与刷新不依赖来源名单。来源名单只服务其他分类，帖子在点击详情徽章时按需读取。
@MainActor @Observable
final class LinuxDoStore {
    var selectedSource: DiscoverySource = .catalog
    var selectedLanguage: String?
    private(set) var providerID = ""
    private(set) var catalog: LinuxDoCatalogSummary?
    private(set) var provenanceKey: LinuxDoProvenanceKey?
    private(set) var isRefreshingCatalog = false
    private(set) var catalogFailed = false
    private let repository: LinuxDoRepository

    init(repository: LinuxDoRepository) { self.repository = repository }

    var total: Int { catalog?.total ?? 0 }
    var languages: [DiscoveryLanguageDTO] { catalog?.languages ?? [] }
    var catalogKey: LinuxDoCatalogKey? {
        catalog.map { LinuxDoCatalogKey(providerID: providerID, revision: $0.metadata.revision) }
    }

    /// 启动与回切优先恢复摘要。已读摘要由窗口复用，不再次读取目录行。
    func restoreCatalog() async {
        let provider = await repository.providerIdentity()
        guard !Task.isCancelled else { return }
        adoptProvider(provider)
        guard catalog == nil else { return }
        await readCatalogSummary(provider: provider)
    }

    func refreshCatalog(force: Bool = false) async {
        await restoreCatalog()
        guard !Task.isCancelled, !isRefreshingCatalog else { return }
        let provider = providerID
        isRefreshingCatalog = true
        defer { if providerID == provider { isRefreshingCatalog = false } }
        do {
            let updated = try await repository.refresh(.catalog, providerID: provider, force: force)
            guard providerID == provider else { return }
            if catalog?.metadata.revision == updated.revision {
                if catalog?.metadata != updated { catalog?.metadata = updated }
            } else {
                await readCatalogSummary(provider: provider)
            }
            if providerID == provider { catalogFailed = false }
        } catch {
            guard providerID == provider, !(error is CancellationError) else { return }
            catalogFailed = true
        }
    }

    func page(
        key: LinuxDoCatalogKey, query: LinuxDoCatalogQuery, memberships: [LinuxDoRepoMembership],
        limit: Int, offset: Int = 0, knownTotal: Int? = nil
    ) async throws -> LinuxDoCatalogPage? {
        guard catalogKey == key else { return nil }
        let result = try await repository.page(key: key, query: query, memberships: memberships, limit: limit, offset: offset, knownTotal: knownTotal)
        return catalogKey == key ? result : nil
    }

    func signalCandidates(key: LinuxDoCatalogKey, query: LinuxDoCatalogQuery) async throws -> [WikiAvailabilityRequest] {
        try await repository.signalCandidates(key: key, query: query)
    }

    /// 侧栏统一触发低频条件刷新。只发布版本和校验时间，列表任务用它失效自己的批次。
    func refreshProvenance() async {
        let provider = await repository.providerIdentity()
        guard !Task.isCancelled else { return }
        adoptProvider(provider)
        if let cached = try? await repository.cached(.provenance, providerID: provider), providerID == provider, !Task.isCancelled {
            applyProvenance(cached, provider: provider)
        }
        guard providerID == provider, !Task.isCancelled else { return }
        if let fresh = try? await repository.refresh(.provenance, providerID: provider), providerID == provider, !Task.isCancelled {
            applyProvenance(fresh, provider: provider)
        }
    }

    func verifiedIDs(_ ids: [Int64], key: LinuxDoProvenanceKey) async -> Set<Int64> {
        guard provenanceKey == key, !Task.isCancelled else { return [] }
        let verified = (try? await repository.verifiedIDs(ids, providerID: key.providerID)) ?? []
        return provenanceKey == key && !Task.isCancelled ? verified : []
    }

    /// 详情点击优先使用可用的本地回链。目录内用目录成员关系，其他分类使用已核验来源。
    func discussionURL(for repoID: Int64, fromCatalog: Bool = false) async -> URL? {
        let provider = await repository.providerIdentity()
        guard !Task.isCancelled, provider == providerID else { return nil }
        let requiredRevision: Int64
        if fromCatalog {
            guard let key = catalogKey, (try? await repository.contains(repoID: repoID, providerID: provider)) == true,
                  catalogKey == key else { return nil }
            requiredRevision = key.revision
        } else {
            guard let key = provenanceKey, await verifiedIDs([repoID], key: key).contains(repoID) else { return nil }
            requiredRevision = key.revision
        }

        var url = try? await repository.discussionURL(repoID: repoID, providerID: provider, minimumRevision: requiredRevision)
        guard providerID == provider, !Task.isCancelled else { return nil }
        if url == nil {
            let resource = LinuxDoResource.topics(repoID)
            let cached = try? await repository.cached(resource, providerID: provider)
            guard providerID == provider, !Task.isCancelled else { return nil }
            let fresh = try? await repository.refresh(resource, providerID: provider, force: (cached?.revision ?? requiredRevision) < requiredRevision)
            if let fresh, fresh.revision >= requiredRevision {
                url = try? await repository.discussionURL(repoID: repoID, providerID: provider, minimumRevision: requiredRevision)
            }
        }
        guard let url, !Task.isCancelled, providerID == provider,
              await repository.providerIdentity() == provider else { return nil }
        if fromCatalog {
            guard catalogKey?.revision == requiredRevision else { return nil }
        } else {
            guard provenanceKey?.revision == requiredRevision else { return nil }
        }
        return url
    }

    /// 设置热切换时立即抛弃旧服务的展示摘要，等新服务恢复自己的离线缓存。
    func providerDidChange() async { await restoreCatalog() }

    private func adoptProvider(_ provider: String) {
        guard providerID != provider else { return }
        providerID = provider
        catalog = nil
        provenanceKey = nil
        isRefreshingCatalog = false
        catalogFailed = false
    }

    private func readCatalogSummary(provider: String) async {
        let summary = try? await repository.catalogSummary(providerID: provider)
        guard providerID == provider, let summary else { return }
        if let catalog, summary.metadata.revision < catalog.metadata.revision ||
            (summary.metadata.revision == catalog.metadata.revision && summary.metadata.checkedAt <= catalog.metadata.checkedAt) { return }
        catalog = summary
    }

    private func applyProvenance(_ meta: LinuxDoCacheMetadata, provider: String) {
        if Date().timeIntervalSince(meta.checkedAt) > 7 * 86400 {
            if let current = provenanceKey, meta.revision >= current.revision,
               meta.checkedAt >= current.checkedAt { provenanceKey = nil }
            return
        }
        let key = LinuxDoProvenanceKey(providerID: provider, revision: meta.revision, checkedAt: meta.checkedAt)
        if let previous = provenanceKey, previous.revision > key.revision ||
            (previous.revision == key.revision && previous.checkedAt >= key.checkedAt) { return }
        provenanceKey = key
    }
}

struct LinuxDoListQuery: Hashable {
    let base: LinuxDoCatalogQuery
    var star: RepoStarFilter = .all
    var library: RepoLibraryFilter = .all
    var wiki: RepoSignalAvailabilityFilter = .unknown
    var health: RepoSignalAvailabilityFilter = .unknown
    var openSSF: RepoSignalAvailabilityFilter = .unknown
    var databaseScope: UInt64 = 0

    var needsSignalCandidates: Bool {
        library != .all || wiki != .unknown || health != .unknown || openSSF != .unknown
    }
}

struct LinuxDoListRequest: Hashable {
    let key: LinuxDoCatalogKey
    let query: LinuxDoListQuery
    var filterRevision = 0

    /// 条件决定动画和滚动身份。服务器版本和信号变化仅重新查询已加载范围。
    var presentationID: Int { [key.providerID.hashValue, query.hashValue].hashValue }
}

/// 窗口持有当前查询和已读页。新条件从第一页开始，刷新保留已读范围，旧查询不可追加到新查询。
@MainActor @Observable
final class LinuxDoListModel {
    static let badgeSource = LinuxDoBadgeSource.catalog

    private(set) var rows: [DiscoveryRepoDTO] = []
    private(set) var total = 0
    private(set) var request: LinuxDoListRequest?
    private(set) var failedRequest: LinuxDoListRequest?
    private(set) var isLoading = false
    private(set) var isAppending = false
    private(set) var libraryRevision = 0
    private(set) var libraryStates: [Int64: LibraryState] = [:]
    var recentPromotionFirst = true
    @ObservationIgnored private var memberships: [LinuxDoRepoMembership] = []
    @ObservationIgnored private var pendingRequest: LinuxDoListRequest?
    @ObservationIgnored private var loadedSignalIDs: Set<Int64> = []
    @ObservationIgnored var scrollAnchor: Int64?

    var hasMore: Bool { rows.count < total }

    /// 同一条件回切直接使用已有结果。翻页缓存筛选交集，避免每次滚动重新遍历外部信号。
    func update(
        _ requested: LinuxDoListRequest, store: LinuxDoStore,
        prepareMemberships: () async throws -> [LinuxDoRepoMembership] = { [] }
    ) async {
        guard request != requested || failedRequest == requested else { return }
        guard pendingRequest != requested else { return }
        pendingRequest = requested
        isLoading = true
        failedRequest = nil
        defer {
            if pendingRequest == requested {
                pendingRequest = nil
                isLoading = false
            }
        }
        do {
            let filters = try await prepareMemberships()
            try Task.checkCancellation()
            let samePresentation = request?.presentationID == requested.presentationID
            let limit = max(ListPaginationPolicy.repoCardPageSize, samePresentation ? rows.count : 0)
            let page = try await store.page(key: requested.key, query: requested.query.base, memberships: filters, limit: limit)
            guard !Task.isCancelled, pendingRequest == requested, let page else { return }
            if !samePresentation { scrollAnchor = nil }
            if request?.query.databaseScope != requested.query.databaseScope {
                libraryStates = [:]
                loadedSignalIDs.removeAll()
            }
            rows = page.rows
            total = page.total
            memberships = filters
            request = requested
        } catch {
            if !Task.isCancelled, pendingRequest == requested { failedRequest = requested }
        }
    }

    func loadMore(requested: LinuxDoListRequest, store: LinuxDoStore) async {
        guard request == requested, !isLoading, !isAppending, hasMore else { return }
        isAppending = true
        defer { isAppending = false }
        do {
            let offset = rows.count
            let page = try await store.page(key: requested.key, query: requested.query.base, memberships: memberships,
                                            limit: ListPaginationPolicy.repoCardPageSize, offset: offset, knownTotal: total)
            guard !Task.isCancelled, request == requested, !isLoading, rows.count == offset, let page else { return }
            rows.append(contentsOf: page.rows)
        } catch {
            if request == requested, !isLoading, !Task.isCancelled { failedRequest = requested }
        }
    }

    func invalidateLibrary() {
        loadedSignalIDs.removeAll()
        libraryRevision &+= 1
    }

    func pendingSignalIDs() -> [Int64] {
        rows.lazy.map(\.repoID).filter { !self.loadedSignalIDs.contains($0) }
    }

    func setLibraryStates(_ states: [Int64: LibraryState], for ids: [Int64]) {
        var updated = libraryStates
        for id in ids { updated[id] = states[id] }
        if updated != libraryStates { libraryStates = updated }
        loadedSignalIDs.formUnion(ids)
    }
}
