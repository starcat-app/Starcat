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

    @Test @MainActor func contentLanguageFollowsAppLocaleAndNeverFallsBack() async throws {
        let fixture = DailyRadarFixture()
        defer { fixture.clean() }
        let model = DailyRadarWorkspaceViewModel()
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "en_US"))
        #expect(model.contentLanguage == "en")
        // locale 变化复用同一个模型时也必须重新加载，不能继续读旧语言缓存。
        model.configure(repository: fixture.repository, scope: "one", locale: Locale(identifier: "zh_CN"))
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
        var hasNext = false
        var hasPage = false
        var historyDates: [String]? = nil
        var changeOnNext = false
        var requests: [URLRequest] = []
    }
    private let lock = NSLock()
    private var values = Values()
    var requests: [URLRequest] { lock.withLock { values.requests } }
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
            let status = values.error ? 503 : (values.notModified ? 304 : 200)
            let path = request.url!.path
            let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
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
            let summary = summaries.joined(separator: ",")
            let payload: String
            if path.hasSuffix("/catalog") {
                // 计数与 /reports 的 total=12 语义保持一致，供侧边栏徽标断言使用。
                payload = """
                {"catalog_revision":"\(values.revision)","categories":[{"id":"ai-cli","title":"AI CLI","period":"daily"}],"available_languages":["en"],"latest_available_date":"\(values.day)","category_counts":{"ai-cli":12},"total_count":12}
                """
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
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
