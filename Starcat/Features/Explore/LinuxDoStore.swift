//
//  LinuxDoStore.swift
//  Starcat
//
//  主窗口共享公共来源索引。列表行只做 O(1) ID 查询，绝不逐行联网或上传 Stars 清单。
//

import Foundation
import Observation

/// UI 只发布当前服务身份的数据；取消、断网、坏快照保留上次有效缓存。
@MainActor @Observable
final class LinuxDoStore {
    var selectedSource: DiscoverySource = .catalog
    /// 来源内的单选语言独立于普通 Discovery 和 toolbar 全局多语言筛选，不写用户数据。
    var selectedLanguage: String?
    private(set) var providerID = ""
    private(set) var catalog: LinuxDoCachedSnapshot?
    private(set) var provenance: LinuxDoCachedSnapshot?
    private(set) var topicSnapshots: [Int64: LinuxDoCachedSnapshot] = [:]
    private(set) var loading: Set<LinuxDoResource> = []
    private(set) var failed: Set<LinuxDoResource> = []
    private var origins: [Int64: LinuxDoOrigin] = [:]
    private var verifiedDates: [Int64: Date] = [:]
    private let repository: LinuxDoRepository

    init(repository: LinuxDoRepository) { self.repository = repository }

    var repositories: [DiscoveryRepoDTO] { catalog?.payload.repositories ?? [] }
    var isRefreshingCatalog: Bool { loading.contains(.catalog) }
    var languages: [DiscoveryLanguageDTO] { Self.languageAggregates(in: repositories) }

    /// 只聚合本来源快照；大小写与空白归一后计数，避免同一语言出现重复行。
    /// 保留未分类的零计数入口，与现有语言侧栏及离线空快照的展示规则一致。
    static func languageAggregates(in repositories: [DiscoveryRepoDTO]) -> [DiscoveryLanguageDTO] {
        let groups = Dictionary(grouping: repositories) { normalizedLanguage($0.language).lowercased() }
        var result = groups.map { key, repos in
            let language = normalizedLanguage(repos.first?.language)
            return DiscoveryLanguageDTO(
                key: key.isEmpty ? TrendingLanguage.uncategorizedKey : language,
                label: key.isEmpty ? TrendingLanguage.uncategorized.localizedDisplayName : language,
                count: repos.count
            )
        }
        if groups[""] == nil {
            result.append(DiscoveryLanguageDTO(key: TrendingLanguage.uncategorizedKey, label: TrendingLanguage.uncategorized.localizedDisplayName, count: 0))
        }
        return result.sorted { $0.key < $1.key }
    }

    /// 与聚合使用同一主语言口径；“其他”排除感兴趣语言，而不是排除当前全局筛选。
    static func matchesLanguage(_ language: String?, selection: String?, interestedLanguages: [String]) -> Bool {
        let language = normalizedLanguage(language)
        let selection = normalizedLanguage(selection)
        switch selection {
        case "": return true
        case TrendingLanguage.uncategorizedKey: return language.isEmpty
        case TrendingLanguage.otherRawValue:
            return !language.isEmpty && !interestedLanguages.contains {
                language.caseInsensitiveCompare(normalizedLanguage($0)) == .orderedSame
            }
        default: return language.caseInsensitiveCompare(selection) == .orderedSame
        }
    }

    private static func normalizedLanguage(_ language: String?) -> String {
        (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 超过七天未验证索引，或三十天未验证关系时，不把历史事实冒充当前来源。
    func origin(for repoID: Int64, now: Date = Date()) -> LinuxDoOrigin? {
        guard let provenance, now.timeIntervalSince(provenance.checkedAt) <= 7 * 86400,
              let verified = verifiedDates[repoID], now.timeIntervalSince(verified) <= 30 * 86400 else { return nil }
        return origins[repoID]
    }

    func refreshProvenance(force: Bool = false) async {
        await load(.provenance, force: force)
        if selectedSource == .linuxDo, let catalog, let provenance,
           catalog.payload.revision < provenance.payload.revision {
            await load(.catalog, force: true)
        }
    }

    /// 启动时只恢复目录缓存，不预先联网；进入分类可直接准备首屏，过期校验仍走原刷新入口。
    func restoreCatalog() async {
        let identity = await repository.providerIdentity()
        guard !Task.isCancelled else { return }
        adoptProvider(identity)
        if let cached = await repository.cached(.catalog, providerID: identity), providerID == identity {
            apply(cached, resource: .catalog)
        }
    }

    func refreshCatalog(force: Bool = false) async {
        async let index: Void = load(.provenance, force: force)
        await load(.catalog, force: force)
        await index
        // 两个端点独立缓存，但不能把已知较旧的目录/来源索引继续当作最新结果。
        if let catalog, let provenance {
            if catalog.payload.revision < provenance.payload.revision { await load(.catalog, force: true) }
            if provenance.payload.revision < catalog.payload.revision { await load(.provenance, force: true) }
        }
    }
    func refreshTopics(repoID: Int64, force: Bool = false) async { await load(.topics(repoID), force: force) }

    /// 详情点击优先使用缓存回链；无缓存才加载帖子，不让直接跳转变成每次强制联网。
    /// await 期间可能切换服务或撤回来源，因此加载后必须重新核对身份与有效来源。
    func discussionURL(for repoID: Int64) async -> URL? {
        let identity = await repository.providerIdentity()
        guard !Task.isCancelled else { return nil }
        adoptProvider(identity)
        guard origin(for: repoID) != nil else { return nil }
        if let url = latestDiscussionURL(for: repoID) { return url }
        await refreshTopics(repoID: repoID)
        guard !Task.isCancelled, providerID == identity, origin(for: repoID) != nil else { return nil }
        return latestDiscussionURL(for: repoID)
    }

    /// 不依赖接口数组顺序或日期字符串排序；同一发布时间用帖子 ID 稳定决胜。
    private func latestDiscussionURL(for repoID: Int64) -> URL? {
        topicSnapshots[repoID]?.payload.topics?
            .filter { $0.safeURL != nil }
            .max { lhs, rhs in
                let left = LinuxDoPayload.date(lhs.publishedAt) ?? .distantPast
                let right = LinuxDoPayload.date(rhs.publishedAt) ?? .distantPast
                return left == right ? lhs.id < rhs.id : left < right
            }?.safeURL
    }

    /// 设置页热切换立即清除 UI 旧身份，再加载新服务的磁盘缓存。旧请求仍由仓储合并收口。
    func providerDidChange() async {
        let identity = await repository.providerIdentity()
        adoptProvider(identity)
        await refreshProvenance()
    }

    private func adoptProvider(_ identity: String) {
        guard providerID != identity else { return }
        providerID = identity
        catalog = nil
        provenance = nil
        topicSnapshots = [:]
        origins = [:]
        verifiedDates = [:]
        loading = []
        failed = []
    }

    private func load(_ resource: LinuxDoResource, force: Bool) async {
        let identity = await repository.providerIdentity()
        guard !Task.isCancelled else { return }
        adoptProvider(identity)
        guard !loading.contains(resource) else { return }
        loading.insert(resource)
        defer { if providerID == identity { loading.remove(resource) } }
        var requiresRevalidation = force
        if let cached = await repository.cached(resource, providerID: identity), providerID == identity {
            if case .topics = resource, cached.payload.revision < (provenance?.payload.revision ?? -1) { requiresRevalidation = true }
            apply(cached, resource: resource)
        }
        do {
            let fresh = try await repository.refresh(resource, providerID: identity, force: requiresRevalidation)
            try Task.checkCancellation()
            guard providerID == identity else { return }
            if case .topics = resource, fresh.payload.revision < (provenance?.payload.revision ?? -1) { throw LinuxDoCacheError.obsoleteRevision }
            apply(fresh, resource: resource)
            failed.remove(resource)
        } catch {
            guard !Task.isCancelled, providerID == identity, !(error is CancellationError) else { return }
            failed.insert(resource)
        }
    }

    private func apply(_ snapshot: LinuxDoCachedSnapshot, resource: LinuxDoResource) {
        switch resource {
        case .catalog:
            guard snapshot.payload.revision >= (catalog?.payload.revision ?? -1) else { return }
            catalog = snapshot
        case .provenance:
            guard snapshot.payload.revision >= (provenance?.payload.revision ?? -1) else { return }
            provenance = snapshot
            origins = Dictionary(uniqueKeysWithValues: (snapshot.payload.origins ?? []).map { ($0.repoID, $0) })
            verifiedDates = origins.compactMapValues { LinuxDoPayload.date($0.verifiedAt) }
            // 已明确撤回的来源立即退出详情缓存，不等下一次点击刷新。
            topicSnapshots = topicSnapshots.filter { origins[$0.key] != nil && $0.value.payload.revision >= snapshot.payload.revision }
        case .topics(let id):
            guard snapshot.payload.revision >= max(topicSnapshots[id]?.payload.revision ?? -1, provenance?.payload.revision ?? -1) else { return }
            topicSnapshots[id] = snapshot
            if topicSnapshots.count > 64, let oldest = topicSnapshots.min(by: { $0.value.checkedAt < $1.value.checkedAt })?.key { topicSnapshots[oldest] = nil }
        }
    }
}

/// 窗口会话持有派生列表与筛选快照，分类回切不重复筛选排序；分页不与其他窗口共享。
@MainActor @Observable
final class LinuxDoListModel {
    private(set) var rows: [DiscoveryRepoDTO] = []
    private(set) var total = 0
    private(set) var identity = ""
    private(set) var presentationQuery: String?
    var libraryStates: [Int64: LibraryState] = [:]
    var wikiAvailability: [Int64: Bool] = [:]
    private var matching: [DiscoveryRepoDTO] = []
    var hasMore: Bool { rows.count < matching.count }

    /// 延迟求值跳过相同快照。查询不变时保留已加载范围，目录版本变化只更新当前结果。
    func reset(
        repositories: @autoclosure () -> [DiscoveryRepoDTO],
        promotionDates: [String: String],
        search: String,
        recentPromotionFirst: Bool,
        identity: String,
        presentationQuery: String? = nil
    ) {
        guard self.identity != identity else { return }
        let pageSize = ListPaginationPolicy.repoCardPageSize
        let limit = presentationQuery != nil && self.presentationQuery == presentationQuery
            ? max(pageSize, rows.count) : pageSize
        self.identity = identity
        self.presentationQuery = presentationQuery
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        matching = repositories().filter { term.isEmpty || $0.fullName.localizedCaseInsensitiveContains(term) || ($0.description?.localizedCaseInsensitiveContains(term) ?? false) }
        matching.sort { a, b in
            if recentPromotionFirst, promotionDates[String(a.repoID)] != promotionDates[String(b.repoID)] {
                return (promotionDates[String(a.repoID)] ?? "") > (promotionDates[String(b.repoID)] ?? "")
            }
            if a.stars != b.stars { return a.stars > b.stars }
            return a.repoID > b.repoID
        }
        total = matching.count
        rows = Array(matching.prefix(limit))
    }

    func loadMore() {
        guard hasMore else { return }
        rows.append(contentsOf: matching.dropFirst(rows.count).prefix(ListPaginationPolicy.repoCardPageSize))
    }
}
