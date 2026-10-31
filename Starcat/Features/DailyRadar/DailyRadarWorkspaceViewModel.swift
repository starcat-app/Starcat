//
//  DailyRadarWorkspaceViewModel.swift
//  Starcat
//
//  首页筛选与阅读会话状态。目录切换先准备完整首屏，再原子发布；
//  后台新版不得改变当前文章 revision，晚到请求不得跨筛选/账户覆盖。
//

import Foundation
import Observation

@MainActor
@Observable
final class DailyRadarWorkspaceViewModel {
    static let root = "/api/v1/daily-radar"
    private(set) var catalog: DailyRadarCatalog?
    private(set) var dates: [DailyRadarDates.Edition] = []
    private(set) var items: [DailyRadarReport] = []
    private(set) var total = 0
    private(set) var nextCursor: String?
    private(set) var featuredID: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var failed = false
    private(set) var detailFailed = false
    private(set) var detail: DailyRadarReport?
    private(set) var selection: DailyRadarReport?
    var category: String?
    private(set) var edition: String?
    var selectedEdition: String?
    var contentLanguage = "en"
    var allowsFallback = true
    var scope = ""
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var detailGeneration: UInt64 = 0
    @ObservationIgnored private var repository: DailyRadarRepository?

    var categoryPeriod: String { catalog?.categories.first(where: { $0.id == category })?.period ?? "daily" }
    var identity: String { "\(scope)|\(category ?? "")|\(selectedEdition ?? "latest")|\(contentLanguage)|\(allowsFallback)" }
    var featured: DailyRadarReport? { items.first(where: { $0.id == featuredID }) ?? items.first }
    var stories: [DailyRadarReport] { items.filter { $0.editionDate == edition } }
    var olderStories: [DailyRadarReport] { items.filter { $0.editionDate != edition } }
    var availableCategories: [DailyRadarCatalog.Category] { catalog?.categories ?? [] }
    /// 目录日期已按业务日期排序；查找相邻期次必须跳过断更，而不是简单加减一天。
    /// 日期切换会先更新 selectedEdition、再由身份驱动异步 reload，因此这里必须
    /// 优先使用用户刚选择的日期，否则连续点击会按旧 edition 计算出错误目标。
    var previousEdition: String? {
        guard let currentEdition = selectedEdition ?? edition else { return nil }
        return dates.first(where: { $0.date < currentEdition })?.date
    }
    var nextEdition: String? {
        guard let currentEdition = selectedEdition ?? edition else { return nil }
        return dates.last(where: { $0.date > currentEdition })?.date
    }
    var availableDates: Set<String> { Set(dates.map(\.date)) }
    private var query: DailyRadarQuery {
        .init(category: category, period: categoryPeriod, language: contentLanguage, fallback: allowsFallback, dateTo: selectedEdition)
    }

    /// 账户/服务身份不同先清理可观察状态，避免新请求开始前露出上一会话内容。
    func configure(repository: DailyRadarRepository, scope: String, locale: Locale) {
        self.repository = repository
        guard self.scope != scope else { return }
        generation &+= 1
        detailGeneration &+= 1
        self.scope = scope
        contentLanguage = locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
        catalog = nil
        dates = []
        items = []
        detail = nil
        selection = nil
        edition = nil
        selectedEdition = nil
        category = nil
        nextCursor = nil
        failed = false
    }

    /// 首次先显示磁盘，随后条件重验证；CATALOG_CHANGED 只有限重试一次。
    func reload(force: Bool = false) async {
        guard let repository else { return }
        generation &+= 1
        let token = generation
        let expectedIdentity = identity
        isLoading = true
        isLoadingMore = false
        failed = false
        defer { if generation == token { isLoading = false } }
        var base = query
        let catalogParameters = [
            URLQueryItem(name: "language", value: contentLanguage),
            URLQueryItem(name: "fallback", value: allowsFallback ? "true" : "false")
        ]
        if items.isEmpty,
           let cached = await repository.cached(DailyRadarCatalog.self, path: "\(Self.root)/catalog", parameters: catalogParameters) {
            guard generation == token, identity == expectedIdentity else { return }
            catalog = cached.value
            base.catalogRevision = cached.value.catalogRevision
            base.dateTo = nil
            if let cachedDates = await repository.cached(DailyRadarDates.self, path: "\(Self.root)/dates", parameters: base.parameters),
               generation == token, identity == expectedIdentity {
                base.dateTo = selectedEdition ?? cachedDates.value.latestAvailableDate
                if
               let page = await repository.cached(DailyRadarPage.self, path: "\(Self.root)/reports", parameters: base.parameters),
               cachedDates.value.catalogRevision == page.value.catalogRevision,
               generation == token, identity == expectedIdentity {
                publish(catalog: cached.value, dates: cachedDates.value, page: page.value, edition: base.dateTo)
                }
            }
        }
        for attempt in 0...1 {
            do {
                let loadedCatalog = try await repository.fetch(DailyRadarCatalog.self, path: "\(Self.root)/catalog", parameters: catalogParameters, force: force || attempt > 0)
                var request = query
                request.catalogRevision = loadedCatalog.value.catalogRevision
                request.dateTo = nil
                let loadedDates = try await repository.fetch(DailyRadarDates.self, path: "\(Self.root)/dates", parameters: request.parameters, force: force || attempt > 0)
                // 每个主题使用自己的最近出刊日，不拿全站最新日期制造周报空态。
                request.dateTo = selectedEdition ?? loadedDates.value.latestAvailableDate
                let page = try await repository.fetch(DailyRadarPage.self, path: "\(Self.root)/reports", parameters: request.parameters, force: force || attempt > 0)
                guard generation == token, identity == expectedIdentity else { return }
                guard loadedDates.value.catalogRevision == page.value.catalogRevision else { throw DailyRadarError.server(code: "CATALOG_CHANGED") }
                publish(catalog: loadedCatalog.value, dates: loadedDates.value, page: page.value, edition: request.dateTo)
                return
            } catch {
                guard generation == token else { return }
                if (error as? DailyRadarError)?.catalogChanged == true, attempt == 0 { continue }
                if !(error is CancellationError) { failed = true }
                return
            }
        }
    }

    /// 翻页绑定已发布目录版本；目录变化仅替换新首屏，不把旧游标接到新集合。
    func loadMore() async {
        guard let repository, let nextCursor, !isLoading, !isLoadingMore, !failed else { return }
        let token = generation
        let expectedIdentity = identity
        var request = query
        request.dateTo = edition
        request.catalogRevision = catalog?.catalogRevision
        request.cursor = nextCursor
        isLoadingMore = true
        defer { if generation == token { isLoadingMore = false } }
        do {
            let page = try await repository.fetch(DailyRadarPage.self, path: "\(Self.root)/reports", parameters: request.parameters)
            guard generation == token, identity == expectedIdentity else { return }
            guard page.value.catalogRevision == catalog?.catalogRevision else { throw DailyRadarError.server(code: "CATALOG_CHANGED") }
            let existing = Set(items.map(\.id))
            items.append(contentsOf: page.value.items.filter { !existing.contains($0.id) })
            self.nextCursor = page.value.nextCursor
            total = page.value.total
        } catch {
            guard generation == token else { return }
            if (error as? DailyRadarError)?.catalogChanged == true { await reload(force: true) }
            else if !(error is CancellationError) { failed = true }
        }
    }

    func selectCategory(_ id: String?) {
        category = id
        edition = nil
        selectedEdition = nil
    }

    func selectEarlierEdition() {
        // 直接从当前选择计算目标，避免在同一个调用里依赖可观察计算属性，
        // 保证用户在异步 reload 完成前连续点击也始终只前进一期。
        let currentEdition = selectedEdition ?? edition
        guard let target = dates.first(where: { $0.date < (currentEdition ?? "") })?.date else { return }
        selectedEdition = target
    }

    func selectLaterEdition() {
        let currentEdition = selectedEdition ?? edition
        guard let target = dates.last(where: { $0.date > (currentEdition ?? "") })?.date else { return }
        selectedEdition = target
    }

    /// 打开时捕获摘要修订，不从 latest 指针追随后台更新。
    func open(_ report: DailyRadarReport) async {
        guard let repository else { return }
        detailGeneration &+= 1
        let token = detailGeneration
        let currentScope = scope
        selection = report
        detail = nil
        detailFailed = false
        let path = "\(Self.root)/reports/\(report.id)"
        let parameters = [
            URLQueryItem(name: "language", value: report.contentLanguage),
            URLQueryItem(name: "fallback", value: "false"),
            URLQueryItem(name: "revision", value: report.revision)
        ]
        if let cached = await repository.cached(DailyRadarReport.self, path: path, parameters: parameters),
           token == detailGeneration, scope == currentScope {
            detail = cached.value
        }
        do {
            let loaded = try await repository.fetch(DailyRadarReport.self, path: path, parameters: parameters, ttl: 86400)
            guard token == detailGeneration, scope == currentScope else { return }
            guard loaded.value.contentIdentity == report.contentIdentity, loaded.value.markdown != nil else { throw DailyRadarError.invalidResponse }
            detail = loaded.value
        } catch {
            guard token == detailGeneration, scope == currentScope else { return }
            if !(error is CancellationError) { detailFailed = true }
        }
    }

    func close() {
        detailGeneration &+= 1
        selection = nil
        detail = nil
        detailFailed = false
    }

    private func publish(catalog: DailyRadarCatalog, dates: DailyRadarDates, page: DailyRadarPage, edition: String?) {
        self.catalog = catalog
        self.dates = dates.dates
        self.items = page.items
        self.total = page.total
        self.nextCursor = page.nextCursor
        self.featuredID = page.featuredID
        self.edition = edition
    }
}
