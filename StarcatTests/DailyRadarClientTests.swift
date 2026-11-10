//
//  DailyRadarClientTests.swift
//  StarcatTests
//
//  日报网络/缓存/阅读安全离线回归。每个测试使用独立 host 与 Session，
//  不共享 URLProtocolStub 全局处理器，也不连接生产服务。
//

import Foundation
import Testing
@testable import Starcat

struct DailyRadarClientTests {
    /// 新栏目独立路由与凭据，不能借 Weekly 的 key 或当前选中分类读取正文
    @Test func eventsRequestsUseIndependentServiceAndCredential() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        await fixture.api.updateEvents(baseURL: URL(string: "https://\(fixture.host)")!, apiKey: "events-fixture", replacesKey: true)
        let config = await fixture.api.configuration()
        let query = DailyRadarQuery(category: "ai-weekly-events", period: "weekly")
        _ = try await fixture.api.request(path: "/api/v1/daily-radar/catalog", parameters: query.catalogParameters, etag: nil, configuration: config)
        #expect(fixture.state.requests.last?.value(forHTTPHeaderField: "X-SC-Svc") == "ai-events")
        #expect(fixture.state.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer events-fixture")
        _ = try await fixture.api.request(path: "/api/v1/daily-radar/reports/ai-weekly-events:2026-11-05:ai-weekly-events",
                                         parameters: [.init(name: "revision", value: "fixed")], etag: nil, configuration: config)
        #expect(fixture.state.requests.last?.value(forHTTPHeaderField: "X-SC-Svc") == "ai-events")
        _ = try await fixture.api.request(path: "/catalog", parameters: [], etag: nil, configuration: config)
        #expect(fixture.state.requests.last?.value(forHTTPHeaderField: "X-SC-Svc") == "weekly")
        #expect(fixture.state.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
    }

    /// 新凭据只隔离新服务缓存，既有日报磁盘身份必须继续有效
    @Test @MainActor func eventsCredentialChangePreservesDailyCacheAndInvalidatesEventsCache() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let path = "/api/v1/daily-radar/catalog"
        let parameters = DailyRadarQuery(category: "ai-weekly-events").catalogParameters
        await fixture.api.updateEvents(apiKey: "events-one", replacesKey: true)
        _ = try await fixture.repository.fetch(DailyRadarCatalog.self, path: path, parameters: [])
        _ = try await fixture.repository.fetch(DailyRadarCatalog.self, path: path, parameters: parameters)
        await fixture.api.updateEvents(apiKey: "events-two", replacesKey: true)
        #expect(await fixture.repository.cached(DailyRadarCatalog.self, path: path, parameters: []) != nil)
        #expect(await fixture.repository.cached(DailyRadarCatalog.self, path: path, parameters: parameters) == nil)
        let model = DailyRadarWorkspaceViewModel()
        #expect(model.availableCategories.first?.id == "ai-weekly-events")
    }

    /// 远端目录未返回时也使用正确周期，不能因服务切换把周刊临时当作日报
    @Test @MainActor func weeklyCategoryPeriodIsAvailableBeforeNetwork() {
        let model = DailyRadarWorkspaceViewModel()
        model.category = "ai-weekly-events"
        #expect(model.categoryPeriod == "weekly")
        model.category = "ai-weekly"
        #expect(model.categoryPeriod == "weekly")
        model.category = "ai"
        #expect(model.categoryPeriod == "daily")
    }

    /// 冷启动断网仍恢复整套首屏；网络失败不能推进原来的成功时间
    @Test @MainActor func offlineRestartRestoresCompleteHomeAndCachedArticle() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let first = DailyRadarWorkspaceViewModel()
        first.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        await first.reload()
        let report = try #require(first.items.first)
        await first.open(report)
        #expect(first.detail?.markdown == "# Report")
        try fixture.expireCache()
        fixture.state.mutate { $0.networkError = true }

        // 新建 repository 与模型，避免把内存状态保留误判为磁盘恢复成功
        let repository = DailyRadarRepository(api: fixture.api, directory: fixture.directory)
        let restarted = DailyRadarWorkspaceViewModel()
        restarted.configure(repository: repository, scope: "one", locale: Locale(identifier: "en_US"))
        await restarted.reload(force: true)
        #expect(restarted.items.map(\.contentIdentity) == first.items.map(\.contentIdentity))
        #expect(restarted.isShowingCachedContent)
        await restarted.open(try #require(restarted.items.first))
        #expect(restarted.detail?.markdown == "# Report")
        #expect(restarted.detailFailed)
        let entry = await repository.cached(DailyRadarReport.self, path: "\(DailyRadarWorkspaceViewModel.root)/reports/\(report.id)",
                                            parameters: [.init(name: "language", value: report.contentLanguage),
                                                         .init(name: "fallback", value: "false"),
                                                         .init(name: "revision", value: report.revision)])
        #expect(entry?.validatedAt == Date(timeIntervalSinceReferenceDate: 0))
    }

    /// 新目录已落盘但日期请求失败时，上一份完整首屏必须仍可离线恢复
    @Test @MainActor func partialRefreshDoesNotReplaceLastCompleteHome() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        await model.reload()
        fixture.state.mutate { $0.revision = "2"; $0.failedPaths = ["/api/v1/daily-radar/dates"] }
        await model.reload(force: true)
        #expect(model.catalog?.catalogRevision == "1")
        fixture.state.mutate { $0.networkError = true }
        let restarted = DailyRadarWorkspaceViewModel()
        restarted.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        await restarted.reload(force: true)
        #expect(restarted.catalog?.catalogRevision == "1")
        #expect(!restarted.items.isEmpty)
        #expect(restarted.isShowingCachedContent)
    }

    /// 周刊在空目录冷启动时不能按 daily 查询缓存；未缓存的筛选不能展示另一分类内容
    @Test @MainActor func offlineWeeklySnapshotKeepsPeriodAndFilterIsolation() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        model.selectCategory("ai-weekly-events")
        await model.reload()
        let request = try #require(fixture.state.requests.first { $0.url?.path.hasSuffix("/dates") == true })
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "period", value: "weekly")) == true)
        try fixture.expireCache()
        fixture.state.mutate { $0.networkError = true }
        let restarted = DailyRadarWorkspaceViewModel()
        restarted.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        restarted.selectCategory("ai-weekly-events")
        await restarted.reload(force: true)
        #expect(restarted.categoryPeriod == "weekly")
        #expect(restarted.isShowingCachedContent)
        restarted.selectCategory("ai-cli")
        await restarted.reload(force: true)
        #expect(restarted.items.isEmpty)
        #expect(!restarted.isShowingCachedContent)
    }

    /// 快照沿用服务/凭据及语言边界，不借离线恢复展示其它身份的内容
    @Test @MainActor func completeHomeSnapshotKeepsCredentialAndLanguageIsolation() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        await model.reload()
        #expect(await fixture.repository.restoreHome(query: .init()) != nil)
        #expect(await fixture.repository.restoreHome(query: .init(language: "zh-Hans")) == nil)
        await fixture.api.update(apiKey: "different", replacesKey: true)
        #expect(await fixture.repository.restoreHome(query: .init()) == nil)
    }

    /// 新周报必须使用服务目录的 weekly 周期，避免沿用默认 daily 而查询不到内容
    @Test @MainActor func weeklyEventsSelectionUsesWeeklyRequests() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "weekly-events", locale: Locale(identifier: "en_US"))
        await model.reload()
        model.selectCategory("ai-weekly-events")
        await model.reload()
        #expect(model.categoryPeriod == "weekly")
        let requests = fixture.state.requests.filter { $0.url?.path.hasSuffix("/reports") == true }
        let request = try #require(requests.last)
        let url = try #require(request.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(.init(name: "category", value: "ai-weekly-events")))
        #expect(query.contains(.init(name: "period", value: "weekly")))
        #expect(model.workspaceTitle == DailyRadarCatalog.Category.localizedTitle(for: "ai-weekly-events"))
    }

    @Test func concurrentRequestsShareCacheAndQueryIdentityIncludesFilters() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        async let first = fixture.repository.fetch(DailyRadarCatalog.self, path: "/catalog", parameters: [])
        async let second = fixture.repository.fetch(DailyRadarCatalog.self, path: "/catalog", parameters: [])
        _ = try await (first, second)
        #expect(fixture.state.requests.count == 1)
        #expect(await fixture.repository.cached(
            DailyRadarCatalog.self, path: "/catalog",
            parameters: [.init(name: "language", value: "zh-Hans")]
        ) == nil)
    }

    @Test func etag304PreservesBodyAndFailurePreservesSuccessTime() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let params: [URLQueryItem] = []
        let first = try await fixture.repository.fetch(DailyRadarCatalog.self, path: "/catalog", parameters: params)
        #expect(first.value.catalogRevision == "1")
        fixture.state.mutate { $0.notModified = true }
        let second = try await fixture.repository.fetch(DailyRadarCatalog.self, path: "/catalog", parameters: params, force: true)
        #expect(second.value.catalogRevision == "1")
        #expect(second.validatedAt >= first.validatedAt)
        #expect(fixture.state.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"1\"")
        #expect(fixture.state.requests.last?.value(forHTTPHeaderField: "X-SC-Svc") == "weekly")
        #expect(fixture.state.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        fixture.state.mutate { $0.error = true }
        do {
            _ = try await fixture.repository.fetch(DailyRadarCatalog.self, path: "/catalog", parameters: params, force: true)
            Issue.record("Expected network failure")
        } catch {}
        let restored = await fixture.repository.cached(DailyRadarCatalog.self, path: "/catalog", parameters: params)
        #expect(restored?.validatedAt == second.validatedAt)
        #expect(restored?.value.catalogRevision == "1")
        await fixture.api.update(apiKey: "different", replacesKey: true)
        #expect(await fixture.repository.cached(DailyRadarCatalog.self, path: "/catalog", parameters: params) == nil)
    }

    @Test @MainActor func automaticLatestFollowsNextEditionAndHistoryKeepsAllDates() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        await model.reload()
        let catalogRequests = fixture.state.requests.filter { $0.url?.path.hasSuffix("/catalog") == true }
        #expect(catalogRequests.allSatisfy { request in
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return queryItems.contains { $0.name == "language" && $0.value == "en" } &&
                queryItems.contains { $0.name == "fallback" && $0.value == "false" }
        })
        #expect(model.edition == "2026-10-31")
        #expect(model.items.count == 1)
        // 选择历史期次后 reload 是异步身份切换；edition 仍代表旧首屏，
        // 相邻期次计算必须立即跟随 selectedEdition，支持连续点击导航。
        model.selectedEdition = "2026-10-29"
        // 固定当前 edition 后，当前期与往期必须按日期划分；fixture 首页是 10-29。
        #expect(model.stories.map(\.editionDate) == ["2026-10-31"])
        #expect(model.olderStories.isEmpty)
        #expect(model.previousEdition == "2026-10-24")
        #expect(model.nextEdition == "2026-10-31")
        fixture.state.mutate {
            $0.day = "2026-10-30"
            $0.dates = ["2026-10-30", "2026-10-29", "2026-10-24"]
            $0.revision = "2"
            // 模拟服务端 date_to 分页：所选日期是当前期，列表里还带有更早期次。
            $0.historyDates = ["2026-10-29", "2026-10-24"]
        }
        await model.reload(force: true)
        // selectedEdition 已固定历史期次，不能被 latest 指针覆盖。
        #expect(model.edition == "2026-10-29")
        // 历史首屏必须把等于所选日期的项作为当前期，严格更早的项作为往期。
        model.selectedEdition = "2026-10-15"
        fixture.state.mutate {
            $0.dates = ["2026-10-30", "2026-10-29", "2026-10-24", "2026-10-15", "2026-10-14"]
            $0.historyDates = ["2026-10-15", "2026-10-14"]
        }
        await model.reload(force: true)
        #expect(model.edition == "2026-10-15")
        #expect(model.stories.map(\.editionDate) == ["2026-10-15"])
        #expect(model.olderStories.map(\.editionDate) == ["2026-10-14"])
        #expect(model.dates.first?.date == "2026-10-30")
        let dateRequests = fixture.state.requests.filter { $0.url?.path.hasSuffix("/dates") == true }
        #expect(dateRequests.allSatisfy { request in
            !(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains { $0.name == "date_to" }
        })
        model.selectedEdition = nil
        await model.reload(force: true)
        #expect(model.edition == "2026-10-30")
        let selected = try #require(model.items.first)
        await model.open(selected)
        let oldIdentity = model.detail?.contentIdentity
        fixture.state.mutate { $0.revision = "3" }
        await model.reload(force: true)
        #expect(model.detail?.contentIdentity == oldIdentity)
        model.configure(repository: fixture.repository, scope: "two", locale: Locale(identifier: "en_US"))
        #expect(model.items.isEmpty)
        #expect(model.detail == nil)
    }

    @Test(arguments: ["zh-Hans", "zh-Hant", "zh_CN", "zh_TW", "zh_HK", "zh_MO"])
    @MainActor func contentLanguageFollowsAppLocaleAndNeverFallsBack(chineseLocale: String) async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        #expect(model.contentLanguage == "en")
        // locale 变化复用同一个模型时也必须重新加载，不能继续读旧语言缓存。
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: chineseLocale))
        #expect(model.contentLanguage == "zh-Hans")
        await model.reload()
        let requests = fixture.state.requests.filter { !$0.url!.path.contains("/reports/") }
        #expect(!requests.isEmpty)
        #expect(requests.allSatisfy { request in
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return queryItems.contains { $0.name == "language" && $0.value == "zh-Hans" } &&
                queryItems.contains { $0.name == "fallback" && $0.value == "false" }
        })
    }

    /// 专题按自身最近期次取摘要，不沿用日报历史日期，更不能主动打开任意一篇正文。
    @Test @MainActor func weeklyTopicLoadsRecentCoversWithoutChangingDailySelection() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en"))
        await model.reload()
        model.selectedEdition = "2026-10-24"
        let dailyIDs = model.items.map(\.contentIdentity)
        let dailyEdition = model.edition
        let count = fixture.state.requests.count
        await model.reloadWeeklyTopic()
        #expect(model.weeklyTopicReports.map(\.editionDate) == [
            "2026-11-05", "2026-11-01", "2026-10-25", "2026-10-18", "2026-10-11", "2026-10-04"
        ])
        #expect(model.items.map(\.contentIdentity) == dailyIDs)
        #expect(model.edition == dailyEdition)
        #expect(model.selectedEdition == "2026-10-24")
        #expect(model.category == nil)
        #expect(model.selection == nil)
        #expect(!model.weeklyTopicIsLoading)
        let requests = Array(fixture.state.requests.dropFirst(count))
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-SC-Svc") == "ai-events" })
        let reportRequest = try #require(requests.first { $0.url?.path.hasSuffix("/reports") == true })
        let query = try #require(URLComponents(url: reportRequest.url!, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(.init(name: "limit", value: "6")))
        #expect(query.contains(.init(name: "period", value: "weekly")))
        #expect(!query.contains { $0.name == "date_to" || $0.name == "date_from" })
    }

    /// 离线仍可展示已缓存叠卡，切到繁中后不得借英语封面缓存冒充中文内容。
    @Test @MainActor func weeklyTopicCachePreservesLanguageIsolation() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let first = DailyRadarWorkspaceViewModel()
        first.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en"))
        await first.reloadWeeklyTopic()
        #expect(first.weeklyTopicReports.count == 6)
        try fixture.expireCache()
        fixture.state.mutate { $0.networkError = true }
        let restarted = DailyRadarWorkspaceViewModel()
        restarted.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en"))
        await restarted.reloadWeeklyTopic(force: true)
        #expect(restarted.weeklyTopicReports.map(\.contentIdentity) == first.weeklyTopicReports.map(\.contentIdentity))
        #expect(!restarted.weeklyTopicIsLoading)
        restarted.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "zh-Hant"))
        #expect(restarted.weeklyTopicReports.isEmpty)
        fixture.state.mutate { $0.networkError = false }
        await restarted.reloadWeeklyTopic()
        #expect(restarted.weeklyTopicReports.count == 6)
        #expect(restarted.weeklyTopicReports.allSatisfy { $0.contentLanguage == "zh-Hans" })
    }

    @Test @MainActor func adjacentEditionNavigationSkipsUnavailableDates() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        await model.reload()
        #expect(model.availableDates == Set(["2026-10-31", "2026-10-29", "2026-10-24"]))
        #expect(model.dates.map(\.date) == ["2026-10-31", "2026-10-29", "2026-10-24"])
        #expect(model.edition == "2026-10-31")
        model.selectEarlierEdition()
        #expect(model.selectedEdition == "2026-10-29")
        #expect(model.previousEdition == "2026-10-24")
        model.selectLaterEdition()
        #expect(model.selectedEdition == "2026-10-31")
        #expect(model.nextEdition == nil)
    }

    @Test func safeMarkdownKeepsTablesAndFoldsWithoutExecutingSourceHTML() {
        let input = """
        # Report

        | A | B |
        |---|---|
        | one | two |

        | Project | Lang | Stars | Summary |
        |---|---|---|---|
        | [owner/repo](https://github.com/owner/repo) | Python | 1,234 | A repository |

        | Article | Reactions | Comments | Summary |
        |---|---|---|---|
        | [An article](https://dev.to/example/article) | 59 | 11 | A community article |

        <details>
        <summary>Details</summary>
        Hidden text
        </details>

        <script>alert(1)</script>

        [unsafe](javascript:alert(1))
        ![bad](file:///etc/passwd)

        ```html
        <img src=x onerror=alert(1)>
        ```
        """
        let rendered = DailyRadarMarkdownRenderer.render(input)
        #expect(rendered.contains("<table>"))
        // 项目表和文章表共用元信息布局，避免 Reactions/Comments 被长 Summary 挤成逐字换行。
        #expect(rendered.components(separatedBy: "<table class=\"metadata\">").count == 3)
        #expect(rendered.contains("<th>Project</th><th>Lang</th><th>Stars</th><th>Summary</th>"))
        #expect(rendered.contains("<th>Article</th><th>Reactions</th><th>Comments</th><th>Summary</th>"))
        #expect(rendered.contains("<details>"))
        #expect(rendered.contains("<summary>"))
        #expect(!rendered.contains("<script>"))
        #expect(!rendered.contains("href=\"javascript:"))
        #expect(!rendered.contains("src=\"file:"))
        #expect(!rendered.contains("<img src=x"))
        #expect(rendered.contains("&lt;img"))
        #expect(DailyRadarMarkdownRenderer.safeURL("file:///etc/passwd") == nil)
        #expect(DailyRadarMarkdownRenderer.safeURL("https://user:pass@example.com/") == nil)
    }

    @Test @MainActor func changedCatalogRestartsPaginationAndAppendFailureNeedsExplicitRetry() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        fixture.state.mutate { $0.hasNext = true }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        await model.reload()
        fixture.state.mutate { $0.changeOnNext = true }
        await model.loadMore()
        #expect(model.catalog?.catalogRevision == "2")
        #expect(model.items.count == 1)
        #expect(!model.isLoadingMore)
        fixture.state.mutate { $0.error = true }
        await model.loadMore()
        #expect(model.failed)
        let countAfterFailure = fixture.state.requests.count
        await model.loadMore()
        #expect(fixture.state.requests.count == countAfterFailure)
        fixture.state.mutate { $0.error = false; $0.hasNext = false }
        await model.reload(force: true)
        #expect(!model.failed)
        #expect(model.nextCursor == nil)
    }

    @Test @MainActor func historyPaginationUsesBoundedPagesAndDeduplicatesCursorResults() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        fixture.state.mutate { $0.hasPage = true }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        await model.reload()

        // SwiftUI 可能在同一渲染批次触发多个 onAppear；loading guard 必须保证只发一页请求。
        let requestCount = fixture.state.requests.filter { $0.url?.path.hasSuffix("/reports") == true }.count
        async let firstPage = model.loadMore()
        async let secondPage = model.loadMore()
        _ = await (firstPage, secondPage)
        #expect(fixture.state.requests.filter { $0.url?.path.hasSuffix("/reports") == true }.count == requestCount + 1)
        #expect(model.items.count == 12)
        #expect(Set(model.items.map(\.id)).count == model.items.count)
    }

    @Test @MainActor func workspaceTitleFollowsCategoryAndReturnsToOverview() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        #expect(model.workspaceTitle == String.l10n("dailyRadar.title"))

        // 无需等待分类首屏请求完成，标题就应与侧栏当前选择一致。
        model.selectCategory("ai-cli")
        #expect(model.workspaceTitle == DailyRadarCatalog.Category.localizedTitle(for: "ai-cli"))
        await model.reload()
        let category = try #require(model.availableCategories.first(where: { $0.id == "ai-cli" }))
        #expect(model.workspaceTitle == category.localizedTitle)

        model.selectCategory(nil)
        #expect(model.workspaceTitle == String.l10n("dailyRadar.title"))
    }

    @Test @MainActor func workspaceTitleKeepsUnknownCategoryReadableBeforeCatalogArrives() {
        let model = DailyRadarWorkspaceViewModel()
        model.selectCategory("future-category")
        #expect(model.workspaceTitle == "future-category")
        model.selectCategory("ai-community")
        #expect(model.workspaceTitle == DailyRadarCatalog.Category.localizedTitle(for: "ai-community"))
    }

    @Test @MainActor func sidebarCountsFollowCatalogAndSelectCategoryClosesDetail() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        // 侧边栏计数徽标来自 catalog 计数字段；catalog 未加载时必须为空而非崩溃。
        #expect(model.categoryCounts.isEmpty)
        #expect(model.totalCount == nil)
        await model.reload()
        #expect(model.categoryCounts == ["ai-cli": 12])
        #expect(model.totalCount == 12)
        // 打开报告后切换分类必须关闭详情面板，避免旧详情浮在新分类列表之上。
        let selected = try #require(model.items.first)
        await model.open(selected)
        #expect(model.selection?.id == selected.id)
        #expect(model.detail != nil)
        model.selectCategory("ai-cli")
        #expect(model.selection == nil)
        #expect(model.detail == nil)
        #expect(model.category == "ai-cli")
    }

    /// 探索侧栏首次出现只预加载两份目录，不触发日期/正文，也不改变当前阅读状态
    @Test @MainActor func sidebarCatalogPreloadShowsBothServiceCounts() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))

        await model.reloadSidebarCatalogs()

        #expect(model.categoryCounts == ["ai-cli": 12, "ai-weekly-events": 43])
        #expect(model.totalCount == 55)
        #expect(model.items.isEmpty)
        #expect(model.dates.isEmpty)
        #expect(model.category == nil)
        #expect(!model.isLoading)
        #expect(!model.failed)
        #expect(fixture.state.requests.allSatisfy { $0.url?.path.hasSuffix("/catalog") == true })

        let ids = model.availableCategories.map(\.id)
        #expect(ids.first == "ai-weekly-events")
        #expect(ids.last == "ai-monthly")
        #expect(ids.count == Set(ids).count)

        model.selectCategory("ai-weekly-events")
        await model.reload()
        #expect(!model.failed)
        #expect(ids == model.availableCategories.map(\.id))
        #expect(model.categoryCounts == ["ai-cli": 12, "ai-weekly-events": 43])
        model.selectCategory("ai-cli")
        await model.reload()
        #expect(!model.failed)
        #expect(ids == model.availableCategories.map(\.id))
    }

    /// 侧栏目录重验证失败时保留磁盘计数；一方服务故障不隐藏另一方
    @Test @MainActor func sidebarCatalogPreloadRestoresCountsWhenEventsNetworkFails() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let first = DailyRadarWorkspaceViewModel()
        first.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        await first.reloadSidebarCatalogs()

        try fixture.expireCache()
        fixture.state.mutate { $0.failedEventsCatalog = true }
        let repository = DailyRadarRepository(api: fixture.api, directory: fixture.directory)
        let restarted = DailyRadarWorkspaceViewModel()
        restarted.configure(repository: repository, scope: "one", locale: Locale(identifier: "en_US"))

        await restarted.reloadSidebarCatalogs(force: true)

        #expect(restarted.categoryCounts == ["ai-cli": 12, "ai-weekly-events": 43])
        #expect(restarted.totalCount == 55)
        #expect(!restarted.failed)
    }

    @Test @MainActor func switchingCategoryClearsStaleItemsButSameIdentityFailureKeepsContent() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        await model.reload()
        #expect(!model.items.isEmpty)
        // 切分类后新身份的首屏加载失败：旧分类残留必须已被清理。残留 items 会
        // 同时挡住磁盘缓存路径与首屏骨架，让加载窗口只显示「暂无匹配专题」空态。
        fixture.state.mutate { $0.error = true }
        model.selectCategory("ai-cli")
        // SWR：切分类保留旧当期内容与 edition，等缓存/网络无缝替换，不闪骨架。
        #expect(model.edition == "2026-10-31")
        await model.reload(force: true)
        #expect(model.failed)
        #expect(model.items.isEmpty)
        #expect(model.edition == nil)
        // 同身份刷新成功后恢复内容；再次同身份失败则保留已发布内容（SWR，不闪骨架）。
        fixture.state.mutate { $0.error = false }
        await model.reload(force: true)
        #expect(!model.failed)
        #expect(!model.items.isEmpty)
        fixture.state.mutate { $0.error = true }
        await model.reload(force: true)
        #expect(model.failed)
        #expect(!model.items.isEmpty)
    }

    @Test func businessDateDoesNotDependOnSystemTimezone() {
        // 英文格式采用用户 Locale，业务时区仍固定为上海，不能显示成 10/27。
        let label = DailyRadarDateFormatting.label("2026-10-28", locale: Locale(identifier: "en_US"))
        #expect(label.contains("28"))
        #expect(!label.contains("27"))
    }
}

/// 同步 URLProtocol 回调使用锁保护状态；每个 host 绑定独立 fixture，不串扰并行测试。
private final class DailyRadarFixtureState: @unchecked Sendable {
    struct Values {
        var day = "2026-10-31"
        var dates = ["2026-10-31", "2026-10-29", "2026-10-24"]
        var revision = "1"
        var notModified = false
        var error = false
        var networkError = false
        var failedPaths: Set<String> = []
        var hasNext = false
        var hasPage = false
        var historyDates: [String]? = nil
        var changeOnNext = false
        var failedEventsCatalog = false
        var requests: [URLRequest] = []
    }
    private let lock = NSLock()
    private var values = Values()
    var requests: [URLRequest] { lock.withLock { values.requests } }
    var networkError: Bool { lock.withLock { values.networkError } }
    func mutate(_ body: (inout Values) -> Void) { lock.withLock { body(&values) } }
    func response(_ request: URLRequest) -> (HTTPURLResponse, Data) {
        lock.withLock {
            values.requests.append(request)
            let hasCursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "cursor" }) == true
            if hasCursor && values.changeOnNext {
                values.changeOnNext = false
                values.revision = "2"
                let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (response, Data(#"{"schema_version":1,"error":{"code":"CATALOG_CHANGED","message":"changed"}}"#.utf8))
            }
            let path = request.url!.path
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let isEvents = queryItems.contains { $0.name == "category" && $0.value == "ai-weekly-events" }
            let status = values.error
                || values.failedPaths.contains(path)
                || (values.failedEventsCatalog && path.hasSuffix("/catalog") && isEvents) ? 503 : (values.notModified ? 304 : 200)
            let dateTo = queryItems.first { $0.name == "date_to" }?.value
            var summaries: [String] = []
            if values.hasPage && hasCursor {
                summaries = [
                    "agents-radar:2026-10-28:ai-cli",
                    "agents-radar:2026-10-27:ai-cli",
                    "agents-radar:2026-10-26:ai-cli",
                    "agents-radar:2026-10-25:ai-cli",
                    "agents-radar:2026-10-24:ai-cli",
                    "agents-radar:2026-10-23:ai-cli",
                    "agents-radar:2026-10-22:ai-cli",
                    "agents-radar:2026-10-21:ai-cli",
                    "agents-radar:2026-10-20:ai-cli",
                    "agents-radar:2026-10-19:ai-cli",
                    "agents-radar:2026-10-18:ai-cli"
                ].map { id in
                    let day = String(id.suffix(10))
                    return """
                    {"id":"\(id)","revision":"\(values.revision)","edition_date":"\(day)","category":"ai-cli","period":"daily","title":"Report \(day)","summary":"Summary","reading_minutes":3,"cover":{"kind":"category","card_url":null,"hero_url":null,"fallback":"orbit","alt":"AI"},"related_project_count":0,"content_language":"en","available_languages":["en"]}
                    """
                }
            } else {
                // 显式提供历史列表时模拟 date_to 语义，避免测试把“未按日期过滤”的
                // fixture 行为误当成服务端契约。
                let historyDates = (path.hasSuffix("/reports") && hasCursor == false)
                    ? dateTo.flatMap { _ in values.historyDates }
                    : nil
                summaries = ["""
                {"id":"agents-radar:2026-10-29:ai-cli","revision":"\(values.revision)","edition_date":"\(values.day)","category":"ai-cli","period":"daily","title":"Report","summary":"Summary","reading_minutes":3,"cover":{"kind":"category","card_url":null,"hero_url":null,"fallback":"orbit","alt":"AI"},"related_project_count":0,"content_language":"en","available_languages":["en"]}
                """].map { payload in
                    guard let historyDates else { return payload }
                    return historyDates.map { day in
                        payload
                            .replacingOccurrences(of: "agents-radar:2026-10-29:ai-cli", with: "agents-radar:\(day):ai-cli")
                            .replacingOccurrences(of: "\"edition_date\":\"\(values.day)\"", with: "\"edition_date\":\"\(day)\"")
                    }.joined(separator: ",")
                }
            }
            if isEvents && path.hasSuffix("/reports") && dateTo == nil {
                // 故意打乱并多给一期、重复一期，验证只保留最近六个不同日期。
                let language = queryItems.first { $0.name == "language" }?.value ?? "en"
                summaries = [
                    "2026-10-18", "2026-11-05", "2026-10-04", "2026-10-25",
                    "2026-09-27", "2026-11-01", "2026-10-11", "2026-10-25"
                ].map { day in
                    """
                    {"id":"ai-weekly-events:\(day):ai-weekly-events","revision":"\(values.revision)","edition_date":"\(day)","category":"ai-weekly-events","period":"weekly","title":"Weekly \(day)","summary":"Summary","reading_minutes":8,"cover":{"kind":"category","card_url":null,"hero_url":null,"fallback":"orbit","alt":"AI"},"related_project_count":0,"content_language":"\(language)","available_languages":["en","zh-Hans"]}
                    """
                }
            }
            let summary = summaries.joined(separator: ",")
            let payload: String
            if path.hasSuffix("/catalog") {
                if isEvents {
                    payload = """
                    {"catalog_revision":"\(values.revision)","categories":[{"id":"ai-weekly-events","title":"Weekly AI Highlights","period":"weekly"}],"available_languages":["en","zh-Hans"],"latest_available_date":"\(values.day)","category_counts":{"ai-weekly-events":43},"total_count":43}
                    """
                } else {
                    // 计数与 /reports 的 total=12 语义保持一致，供侧边栏徽标断言使用。
                    payload = """
                    {"catalog_revision":"\(values.revision)","categories":[{"id":"ai-cli","title":"AI CLI","period":"daily"}],"available_languages":["en"],"latest_available_date":"\(values.day)","category_counts":{"ai-cli":12},"total_count":12}
                    """
                }
            } else if path.hasSuffix("/dates") {
                // joined 已负责去掉最后一个元素后的分隔符，不能再 dropLast，
                // 否则会截断最后一个日期对象导致 /dates 响应 JSON 非法。
                let editionJSON = values.dates
                    .map { "{\"date\":\"\($0)\",\"count\":1}" }
                    .joined(separator: ",")
                payload = """
                {"catalog_revision":"\(values.revision)","dates":[\(editionJSON)],"latest_available_date":"\(values.day)"}
                """
            } else if path.hasSuffix("/reports") {
                payload = """
                {"catalog_revision":"\(values.revision)","requested_language":"en","items":[\(summary)],"total":12,"next_cursor":\((values.hasNext || values.hasPage) ? "\"next\"" : "null"),"featured_id":"agents-radar:2026-10-29:ai-cli"}
                """
            } else {
                payload = String(summary.dropLast()) + ",\"markdown\":\"# Report\",\"related_projects\":[],\"related_projects_status\":\"complete\"}"
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["ETag": "\"\(values.revision)\""])!
            return (response, Data("{\"schema_version\":1,\"data\":\(payload)}".utf8))
        }
    }
}

private struct DailyRadarFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let state = DailyRadarFixtureState()
    let api: DailyRadarAPI
    let repository: DailyRadarRepository
    let host: String
    init() {
        host = "\(UUID().uuidString).invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DailyRadarTestProtocol.self]
        let session = URLSession(configuration: configuration)
        DailyRadarTestProtocol.register(state, host: host)
        api = DailyRadarAPI(baseURL: URL(string: "https://\(host)")!, apiKey: "fixture", session: session)
        repository = DailyRadarRepository(api: api, directory: directory)
    }
    func clean() {
        DailyRadarTestProtocol.unregister(host: host)
        try? FileManager.default.removeItem(at: directory)
    }
    /// 仅修改测试临时目录的成功时间，强制走真实过期重验证而非 TTL 内直接返回
    func expireCache() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var entry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            entry["validatedAt"] = 0
            try JSONSerialization.data(withJSONObject: entry).write(to: url, options: .atomic)
        }
    }
}

private final class DailyRadarTestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: DailyRadarFixtureState] = [:]
    static func register(_ state: DailyRadarFixtureState, host: String) { lock.withLock { handlers[host] = state } }
    static func unregister(host: String) { _ = lock.withLock { handlers.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handlers[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (response, data) = handler.response(request)
        if handler.networkError {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
