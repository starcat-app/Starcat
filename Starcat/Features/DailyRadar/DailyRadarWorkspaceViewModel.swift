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
    /// 首页专题封面独立于日报日期筛选，不能拿当天的日报响应拼出周报叠卡。
    private(set) var weeklyTopicReports: [DailyRadarReport] = []
    private(set) var weeklyTopicIsLoading = false
    var category: String?
    private(set) var edition: String?
    var selectedEdition: String?
    private(set) var contentLanguage = "en"
    var scope = ""
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var detailGeneration: UInt64 = 0
    @ObservationIgnored private var catalogGeneration: UInt64 = 0
    @ObservationIgnored private var weeklyTopicGeneration: UInt64 = 0
    /// 最近一次 publish 所属的筛选身份；用于识别「当前数据属于旧分类/旧期次」。
    @ObservationIgnored private var publishedIdentity: String?
    @ObservationIgnored private var repository: DailyRadarRepository?
    private var weeklyCatalog: DailyRadarCatalog?
    private var eventsCatalog: DailyRadarCatalog?

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
        // 两份目录只更新元数据，已知分类按固定顺序展示，不能随当前阅读服务重排
        let remote = (weeklyCatalog?.categories ?? []) + (eventsCatalog?.categories ?? [])
        let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let known = Set(DailyRadarCatalog.fallbackCategories.map(\.id))
        let ordered = DailyRadarCatalog.fallbackCategories.map { byID[$0.id] ?? $0 }
        let additions = byID.values.filter { !known.contains($0.id) }.sorted { $0.id < $1.id }
        // 每周 AI 大事固定置首，其余分类和远端新增项保持原顺序，不随服务切换重排。
        return ordered.filter { $0.id == "ai-weekly-events" }
            + ordered.filter { $0.id != "ai-weekly-events" } + additions
    }
    /// 标题与侧栏共用分类本地化；目录尚未返回时也立即跟随当前选择，不显示旧分类名。
    var workspaceTitle: String {
        guard let category else { return String.l10n("dailyRadar.title") }
        return availableCategories.first(where: { $0.id == category })?.localizedTitle
            ?? DailyRadarCatalog.Category.localizedTitle(for: category)
    }
    /// 侧栏使用独立目录快照，进入文章前即可从缓存和服务恢复计数
    var categoryCounts: [String: Int] {
        let weekly = (weeklyCatalog?.categoryCounts ?? [:]).filter { $0.key != "ai-weekly-events" }
        let events = (eventsCatalog?.categoryCounts ?? [:]).filter { $0.key == "ai-weekly-events" }
        return weekly.merging(events) { _, latest in latest }
    }
    var totalCount: Int? {
        guard let total = weeklyCatalog?.totalCount else { return nil }
        return total - (weeklyCatalog?.categoryCounts?["ai-weekly-events"] ?? 0)
            + (eventsCatalog?.categoryCounts?["ai-weekly-events"] ?? 0)
    }
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
        // 简体、繁体及港台地区的中文界面统一读取已发布的中文报告，
        // zh-Hans 是内容版本标识，不要求再生成一份繁体文件或回退英语。
        let requestedLanguage = locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"
        guard self.scope != scope || self.contentLanguage != requestedLanguage else { return }
        generation &+= 1
        detailGeneration &+= 1
        catalogGeneration &+= 1
        weeklyTopicGeneration &+= 1
        self.scope = scope
        contentLanguage = requestedLanguage
        catalog = nil
        dates = []
        items = []
        detail = nil
        selection = nil
        weeklyTopicReports = []
        weeklyTopicIsLoading = false
        edition = nil
        selectedEdition = nil
        category = nil
        weeklyCatalog = nil
        eventsCatalog = nil
        nextCursor = nil
        failed = false
    }

    /// 请求与卡片使用同一个期数上限，避免接口取到六期后又被展示层截成四期。
    static let weeklyTopicLimit = 6

    /// 总分类专题只读取最近六期摘要，不拉正文，也不改变当前分类、日期或阅读修订。
    /// 请求代次和账户/语言身份独立于日报分页；晚到响应不能覆盖切换后的中文或英文封面。
    func reloadWeeklyTopic(force: Bool = false) async {
        guard let repository else { return }
        weeklyTopicGeneration &+= 1
        let token = weeklyTopicGeneration
        let expectedScope = scope
        let language = contentLanguage
        var request = DailyRadarQuery(category: "ai-weekly-events", period: "weekly", language: language, limit: Self.weeklyTopicLimit)
        let catalogPath = "\(Self.root)/catalog"
        let reportsPath = "\(Self.root)/reports"
        weeklyTopicIsLoading = true
        defer { if weeklyTopicGeneration == token { weeklyTopicIsLoading = false } }

        if let cachedCatalog = await repository.cached(DailyRadarCatalog.self, path: catalogPath, parameters: request.catalogParameters) {
            request.catalogRevision = cachedCatalog.value.catalogRevision
            if let cachedPage = await repository.cached(DailyRadarPage.self, path: reportsPath, parameters: request.parameters),
               weeklyTopicGeneration == token, scope == expectedScope, contentLanguage == language,
               cachedPage.value.catalogRevision == cachedCatalog.value.catalogRevision {
                publishWeeklyTopic(cachedPage.value, language: language)
            }
        }
        for attempt in 0...1 {
            do {
                let catalog = try await repository.fetch(DailyRadarCatalog.self, path: catalogPath,
                                                         parameters: request.catalogParameters, force: force || attempt > 0)
                guard weeklyTopicGeneration == token, scope == expectedScope,
                      contentLanguage == language, !Task.isCancelled else { return }
                request.catalogRevision = catalog.value.catalogRevision
                let page = try await repository.fetch(DailyRadarPage.self, path: reportsPath,
                                                      parameters: request.parameters, force: force || attempt > 0)
                guard weeklyTopicGeneration == token, scope == expectedScope,
                      contentLanguage == language, !Task.isCancelled else { return }
                guard page.value.catalogRevision == catalog.value.catalogRevision else {
                    throw DailyRadarError.server(code: "CATALOG_CHANGED")
                }
                publishWeeklyTopic(page.value, language: language)
                return
            } catch {
                guard weeklyTopicGeneration == token, !Task.isCancelled else { return }
                if (error as? DailyRadarError)?.catalogChanged == true, attempt == 0 { continue }
                // 专题封面获取失败不影响日报阅读或分类导航，已有摘要继续可用。
                return
            }
        }
    }

    /// 每期最多一张封面；严格保留请求语言，不能把其他栏目或英语兜底混进中文叠卡。
    private func publishWeeklyTopic(_ page: DailyRadarPage, language: String) {
        var dates = Set<String>()
        weeklyTopicReports = Array(page.items
            .filter { $0.category == "ai-weekly-events" && $0.contentLanguage == language }
            .sorted { $0.editionDate > $1.editionDate }
            .filter { dates.insert($0.editionDate).inserted }
            .prefix(Self.weeklyTopicLimit))
    }

    /// 探索侧栏出现即加载两份轻量目录，与文章首页和当前分类解耦
    /// 子任务分别恢复缓存和重验证，一方失败仍保留另一方的成功计数
    func reloadSidebarCatalogs(force: Bool = false) async {
        guard let repository else { return }
        catalogGeneration &+= 1
        let token = catalogGeneration
        let language = contentLanguage
        await withTaskGroup(of: Void.self) { group in
            let categories: [String?] = [nil, "ai-weekly-events"]
            for category in categories {
                let query = DailyRadarQuery(category: category, language: language)
                group.addTask {
                    await self.reloadSidebarCatalog(repository: repository, query: query, token: token, force: force)
                }
            }
        }
    }

    /// 只发布目录元数据，不能改变正在阅读的版本、日期、筛选或列表加载代次
    private func reloadSidebarCatalog(repository: DailyRadarRepository, query: DailyRadarQuery,
                                      token: UInt64, force: Bool) async {
        let path = "\(Self.root)/catalog"
        if let cached = await repository.cached(DailyRadarCatalog.self, path: path, parameters: query.catalogParameters) {
            guard catalogGeneration == token, !Task.isCancelled else { return }
            applyCatalog(cached.value, events: query.category == "ai-weekly-events")
        }
        do {
            let loaded = try await repository.fetch(DailyRadarCatalog.self, path: path,
                                                    parameters: query.catalogParameters, force: force)
            guard catalogGeneration == token, !Task.isCancelled else { return }
            applyCatalog(loaded.value, events: query.category == "ai-weekly-events")
        } catch {
            // 目录的网络失败不清除成功缓存，也不改变正文自己的加载状态
        }
    }

    private func applyCatalog(_ catalog: DailyRadarCatalog, events: Bool) {
        if events { eventsCatalog = catalog }
        else { weeklyCatalog = catalog }
    }

    /// SWR 时序：身份变化先读磁盘快照，命中即无缝替换（不闪骨架、保留旧内容
    /// 到新内容就位）；未命中才清空进入骨架态。同身份刷新跳过快照直接网络重验证。
    /// CATALOG_CHANGED 只有限重试一次。
    func reload(force: Bool = false) async {
        guard repository != nil else { return }
        let diagnostic = DiagnosticOperation(category: "dailyRadar", name: "reload",
                                             fields: ["force": .boolean(force)])
        await DiagnosticContext.$current.withValue(diagnostic) {
            await reload(force: force, diagnostic: diagnostic)
        }
    }

    /// 目录变化重试和有效快照回退均在根操作内完成，避免把首次请求失败独立落盘。
    private func reload(force: Bool, diagnostic: DiagnosticOperation) async {
        guard let repository else { return }
        var diagnosticOutcome: DiagnosticEvent.Outcome = .cancelled
        defer {
            diagnostic.finish(Task.isCancelled ? .cancelled : diagnosticOutcome,
                fields: ["displayedCount": .integer(items.count), "totalCount": .integer(total),
                         "hasCursor": .boolean(nextCursor != nil), "cacheFallback": .boolean(isShowingCachedContent)])
        }
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
                diagnostic.event(phase: "cachedSnapshot")
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
                diagnosticOutcome = .succeeded
                return
            } catch {
                diagnostic.event(phase: "fetchFailed", fields: ["attempt": .integer(attempt + 1)])
                diagnosticOutcome = DiagnosticFailure.isCancellation(error) ? .cancelled : .failed
                guard generation == token else { return }
                if (error as? DailyRadarError)?.catalogChanged == true, attempt == 0 { continue }
                let outputAvailable = publishedIdentity == expectedIdentity
                UserFacingError.map(error, operation: "dailyRadar.reload", service: "DailyRadar",
                    impact: outputAvailable ? .none : .blocked, summary: .contentUnavailable)
                    .record(category: "dailyRadar", operation: "reload",
                        fields: ["attempt": .integer(attempt + 1), "outputAvailable": .boolean(outputAvailable)])
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
        // 来源由当前请求身份确定，不能用空目录或分类交集猜测服务归属
        applyCatalog(catalog, events: category == "ai-weekly-events")
        self.dates = dates.dates
        self.items = page.items
        self.total = page.total
        self.nextCursor = page.nextCursor
        self.featuredID = page.featuredID
        self.edition = edition
        publishedIdentity = identity
    }
}
