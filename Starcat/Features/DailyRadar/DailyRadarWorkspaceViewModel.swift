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
    private(set) var contentLanguage = "en"
    var scope = ""
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var detailGeneration: UInt64 = 0
    /// 最近一次 publish 所属的筛选身份；用于识别「当前数据属于旧分类/旧期次」。
    @ObservationIgnored private var publishedIdentity: String?
    @ObservationIgnored private var repository: DailyRadarRepository?
    private var weeklyCategoryCounts: [String: Int] = [:]
    private var eventsCategoryCounts: [String: Int] = [:]
    private var weeklyTotalCount: Int?

    var categoryPeriod: String { availableCategories.first(where: { $0.id == category })?.period ?? "daily" }
    var identity: String { "\(scope)|\(category ?? "")|\(selectedEdition ?? "latest")|\(contentLanguage)" }
    var featured: DailyRadarReport? { items.first(where: { $0.id == featuredID }) ?? items.first }
    /// 当前筛选期次必须严格按日期判断。选择历史日期时接口返回的首页可能就是
    /// 该日期前最近一期；不能用 `!=` 判断“往期”，否则会把同一期前的内容误当作当前期。
    var stories: [DailyRadarReport] {
        guard let edition else { return [] }
        return items.filter { $0.editionDate == edition }
    }
    var olderStories: [DailyRadarReport] {
        guard let edition else { return [] }
        return items.filter { $0.editionDate < edition }
    }
    var availableCategories: [DailyRadarCatalog.Category] {
        // 两个服务分别返回自身目录，导航始终保留完整入口；一方故障不隐藏另一方栏目
        let remote = catalog?.categories ?? []
        let known = Set(remote.map(\.id))
        return remote + DailyRadarCatalog.fallbackCategories.filter { !known.contains($0.id) }
    }
    /// 标题与侧栏共用分类本地化；目录尚未返回时也立即跟随当前选择，不显示旧分类名。
    var workspaceTitle: String {
        guard let category else { return String.l10n("dailyRadar.title") }
        return availableCategories.first(where: { $0.id == category })?.localizedTitle
            ?? DailyRadarCatalog.Category.localizedTitle(for: category)
    }
    /// 侧边栏计数徽标数据源：catalog 未加载或旧后端无计数字段时为空，徽标隐藏。
    var categoryCounts: [String: Int] { weeklyCategoryCounts.merging(eventsCategoryCounts) { _, events in events } }
    var totalCount: Int? { weeklyTotalCount.map { $0 + (eventsCategoryCounts["ai-weekly-events"] ?? 0) } }
    /// 失败只是重验证未完成；已有成功内容继续可读，界面明确标注缓存状态
    var isShowingCachedContent: Bool { failed && publishedIdentity == identity && !items.isEmpty }
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
        .init(category: category, period: categoryPeriod, language: contentLanguage, fallback: false, dateTo: selectedEdition)
    }

    /// 账户/服务身份不同先清理可观察状态，避免新请求开始前露出上一会话内容。
    func configure(repository: DailyRadarRepository, scope: String, locale: Locale) {
        self.repository = repository
        let requestedLanguage = locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
        guard self.scope != scope || self.contentLanguage != requestedLanguage else { return }
        generation &+= 1
        detailGeneration &+= 1
        self.scope = scope
        contentLanguage = requestedLanguage
        catalog = nil
        dates = []
        items = []
        detail = nil
        selection = nil
        edition = nil
        selectedEdition = nil
        category = nil
        weeklyCategoryCounts = [:]
        eventsCategoryCounts = [:]
        weeklyTotalCount = nil
        nextCursor = nil
        failed = false
    }

    /// SWR 时序：身份变化先读磁盘快照，命中即无缝替换（不闪骨架、保留旧内容
    /// 到新内容就位）；未命中才清空进入骨架态。同身份刷新跳过快照直接网络重验证。
    /// CATALOG_CHANGED 只有限重试一次。
    func reload(force: Bool = false) async {
        guard let repository else { return }
        generation &+= 1
        let token = generation
        let expectedIdentity = identity
        let isStaleContent = publishedIdentity != expectedIdentity
        isLoading = true
        isLoadingMore = false
        failed = false
        defer { if generation == token { isLoading = false } }
        let snapshotQuery = query
        let catalogParameters = query.catalogParameters
        // 磁盘快照优先：首次加载与身份切换都尝试命中；同身份手动刷新内容已在屏，
        // 跳过快照避免无意义的重复解码。
        if !force || isStaleContent {
            if let home = await repository.restoreHome(query: snapshotQuery) {
                guard generation == token, identity == expectedIdentity else { return }
                publish(catalog: home.catalog, dates: home.dates, page: home.page, edition: home.edition)
            } else if let cached = await repository.cached(DailyRadarCatalog.self, path: "\(Self.root)/catalog", parameters: catalogParameters) {
                guard generation == token, identity == expectedIdentity else { return }
                catalog = cached.value
                // 首次升级尚无完整快照时仍可恢复既有接口缓存；先恢复目录再计算周期
                var base = query
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
        }
        // 快照未命中且内容仍属于旧身份：此刻才清空进入骨架态。快照命中时
        // publish 已无缝替换，不能再清；首次加载本就无内容，清理只是兜底。
        if publishedIdentity != expectedIdentity {
            items = []
            total = 0
            nextCursor = nil
            featuredID = nil
            edition = nil
        }
        for attempt in 0...1 {
            do {
                let loadedCatalog = try await repository.fetch(DailyRadarCatalog.self, path: "\(Self.root)/catalog", parameters: catalogParameters, force: force || attempt > 0)
                var request = requestWithCurrentPeriod(query, catalog: loadedCatalog.value)
                request.catalogRevision = loadedCatalog.value.catalogRevision
                request.dateTo = nil
                let loadedDates = try await repository.fetch(DailyRadarDates.self, path: "\(Self.root)/dates", parameters: request.parameters, force: force || attempt > 0)
                // 每个主题使用自己的最近出刊日，不拿全站最新日期制造周报空态。
                request.dateTo = selectedEdition ?? loadedDates.value.latestAvailableDate
                let page = try await repository.fetch(DailyRadarPage.self, path: "\(Self.root)/reports", parameters: request.parameters, force: force || attempt > 0)
                guard generation == token, identity == expectedIdentity else { return }
                guard loadedCatalog.value.catalogRevision == page.value.catalogRevision,
                      loadedDates.value.catalogRevision == page.value.catalogRevision else { throw DailyRadarError.server(code: "CATALOG_CHANGED") }
                await repository.saveHome(query: requestWithCurrentPeriod(snapshotQuery, catalog: loadedCatalog.value),
                                          catalogRevision: loadedCatalog.value.catalogRevision, edition: request.dateTo)
                guard generation == token, identity == expectedIdentity else { return }
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

    /// 查询周期以本次成功目录为准，避免冷启动周刊沿用空目录的 daily 默认值
    private func requestWithCurrentPeriod(_ query: DailyRadarQuery, catalog: DailyRadarCatalog) -> DailyRadarQuery {
        var result = query
        result.period = catalog.categories.first(where: { $0.id == query.category })?.period ?? "daily"
        return result
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
        selectedEdition = nil
        // 切换分类即离开当前阅读会话：详情面板必须随列表一起重置，
        // 避免新分类首页之上还浮着旧报告详情。close 内部递增 detailGeneration，
        // 与在途详情拉取天然互斥，晚到响应不会污染新状态。
        close()
        // edition 有意保留旧值：reload 会先读新分类磁盘缓存，命中即无缝替换
        // （不闪骨架）；此时旧当期内容继续展示属于 SWR 语义，加载指示由
        // 刷新按钮承担。缓存未命中时才由 reload 清空进入骨架态。
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
        // 独立服务的单分类计数不能覆盖父级日报总数，两份目录分别保留最近成功值
        if catalog.categories.allSatisfy({ $0.id == "ai-weekly-events" }) {
            eventsCategoryCounts = ["ai-weekly-events": catalog.categoryCounts?["ai-weekly-events"] ?? 0]
        } else {
            weeklyCategoryCounts = (catalog.categoryCounts ?? [:]).filter { $0.key != "ai-weekly-events" }
            weeklyTotalCount = catalog.totalCount.map { $0 - (catalog.categoryCounts?["ai-weekly-events"] ?? 0) }
        }
        self.dates = dates.dates
        self.items = page.items
        self.total = page.total
        self.nextCursor = page.nextCursor
        self.featuredID = page.featuredID
        self.edition = edition
        publishedIdentity = identity
    }
}
