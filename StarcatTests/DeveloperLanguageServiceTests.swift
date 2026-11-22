//
//  DeveloperLanguageServiceTests.swift
//  StarcatTests
//
//  开发语言缓存回归测试：首屏不等待联网，七天内复用快照，过期后台刷新。
//  每项测试使用独立账号缓存键，避免清除真实用户或其他测试的统计。
//  全仓性能专项 P2-6(2026-11-22)：补有界并发取语言、单仓失败隔离、在途去重与换号取消回归。
//

import Foundation
import Observation
import Testing
@testable import Starcat

/// 使用真实网络客户端和本地响应验证缓存策略，保留生产环境的编码与请求路径。
@Suite("开发语言缓存与启动恢复", .serialized)
@MainActor
struct DeveloperLanguageServiceTests {
    @Test("启动恢复过期缓存也不触发网络")
    func primeRestoresExpiredCacheWithoutNetworking() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let cached = try fixture.seedCache(age: 8 * 24 * 60 * 60)

        fixture.service.primeFromCache(login: fixture.login.uppercased())
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.service.snapshot == cached)
        #expect(fixture.service.lastFetchedAt == cached.fetchedAt)
        #expect(!fixture.service.isLoading)
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("恢复其他账号时不沿用上个账号的语言")
    func primeKeepsAccountsIsolated() throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let cached = try fixture.seedCache(age: 60)
        fixture.service.primeFromCache(login: fixture.login)
        #expect(fixture.service.snapshot == cached)

        fixture.service.primeFromCache(login: "uncached-\(UUID().uuidString)")

        #expect(fixture.service.snapshot == nil)
        #expect(fixture.service.lastFetchedAt == nil)
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("六天前的缓存仍直接复用")
    func loadReusesCacheWithinSevenDays() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let cached = try fixture.seedCache(age: 6 * 24 * 60 * 60)

        fixture.service.load(login: fixture.login)
        try await Task.sleep(for: .milliseconds(50))

        #expect(fixture.service.snapshot == cached)
        #expect(fixture.service.lastFetchedAt == cached.fetchedAt)
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    @Test("过期刷新期间先显示旧值，成功后持久化新快照")
    func expiredCacheRefreshesInBackground() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let cached = try fixture.seedCache(age: 8 * 24 * 60 * 60)

        fixture.service.load(login: fixture.login)

        #expect(fixture.service.snapshot == cached)
        #expect(!fixture.service.isLoading)
        try await waitForRefresh(fixture.service, after: cached.fetchedAt)

        let refreshed = try #require(fixture.service.snapshot)
        #expect(refreshed.fetchedAt > cached.fetchedAt)
        #expect(refreshed.repositoryCount == 0)
        #expect(URLProtocolStub.receivedRequests.count == 1)
        let restored = DeveloperLanguageService(apiClient: fixture.apiClient)
        restored.primeFromCache(login: fixture.login)
        #expect(restored.snapshot == refreshed)
    }

    @Test("主动刷新可以跳过七天缓存")
    func forceRefreshBypassesFreshCache() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let cached = try fixture.seedCache(age: 60)

        fixture.service.load(login: fixture.login, force: true)
        try await waitForRefresh(fixture.service, after: cached.fetchedAt)

        #expect(fixture.service.lastFetchedAt != cached.fetchedAt)
        #expect(URLProtocolStub.receivedRequests.count == 1)
    }

    @Test("联网刷新失败仍保留内存和磁盘缓存")
    func failedRefreshKeepsCachedSnapshot() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let cached = try fixture.seedCache(age: 8 * 24 * 60 * 60)
        URLProtocolStub.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        fixture.service.load(login: fixture.login)
        try await waitForRefresh(fixture.service, after: cached.fetchedAt)

        #expect(fixture.service.lastError != nil)
        #expect(fixture.service.snapshot == cached)
        #expect(fixture.service.lastFetchedAt == cached.fetchedAt)
        let restored = DeveloperLanguageService(apiClient: fixture.apiClient)
        restored.primeFromCache(login: fixture.login)
        #expect(restored.snapshot == cached)
    }

    // MARK: - 有界并发取语言（全仓性能专项 P2-6）

    @Test("有界并发：3 仓 languages 并行取数并按字节聚合")
    func boundedConcurrencyAggregatesAllRepos() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        URLProtocolStub.requestHandler = { request in
            switch request.url?.path {
            case "/user/repos":
                return (okResponse(request), Data(repoListJSON(["repo-1", "repo-2", "repo-3"]).utf8))
            case "/repos/octo/repo-1/languages":
                return (okResponse(request), Data(#"{"Swift": 300}"#.utf8))
            case "/repos/octo/repo-2/languages":
                return (okResponse(request), Data(#"{"Swift": 100, "Go": 200}"#.utf8))
            case "/repos/octo/repo-3/languages":
                return (okResponse(request), Data(#"{"Rust": 50}"#.utf8))
            default:
                return (okResponse(request), Data("{}".utf8))
            }
        }

        fixture.service.load(login: fixture.login)
        try await waitForSnapshot(fixture.service)

        // 聚合口径：仓库数、字节合计、排序与占比都来自逐仓 /languages 字节数求和。
        let snapshot = try #require(fixture.service.snapshot)
        #expect(snapshot.repositoryCount == 3)
        #expect(snapshot.totalBytes == 650)
        #expect(snapshot.languages.map(\.name) == ["Swift", "Go", "Rust"])
        #expect(snapshot.languages.map(\.bytes) == [400, 200, 50])
        #expect(abs(snapshot.languages[0].ratio - 400.0 / 650.0) < 0.0001)
        #expect(fixture.service.lastError == nil)
        // 总请求数与旧串行版一致：1 次列表 + 每仓恰好 1 次 languages。
        #expect(URLProtocolStub.receivedRequests.count == 4)
    }

    @Test("有界并发：单仓 languages 失败只跳过该仓，不污染 lastError")
    func singleRepoFailureIsIsolated() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        URLProtocolStub.requestHandler = { request in
            switch request.url?.path {
            case "/user/repos":
                return (okResponse(request), Data(repoListJSON(["repo-1", "repo-2", "repo-3"]).utf8))
            case "/repos/octo/repo-2/languages":
                // 仓库已删除 / 重命名场景：非 2xx 视作单仓失败。
                return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            case "/repos/octo/repo-1/languages":
                return (okResponse(request), Data(#"{"Swift": 300}"#.utf8))
            case "/repos/octo/repo-3/languages":
                return (okResponse(request), Data(#"{"Rust": 50}"#.utf8))
            default:
                return (okResponse(request), Data("{}".utf8))
            }
        }

        fixture.service.load(login: fixture.login)
        try await waitForSnapshot(fixture.service)

        let snapshot = try #require(fixture.service.snapshot)
        #expect(snapshot.repositoryCount == 3)
        #expect(snapshot.totalBytes == 350)
        #expect(snapshot.languages.map(\.name) == ["Swift", "Rust"])
        #expect(fixture.service.lastError == nil)
        #expect(URLProtocolStub.receivedRequests.count == 4)
    }

    @Test("同 login 在途加载去重：第二次 load 不追加请求")
    func sameLoginInflightLoadIsDeduped() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let gate = RequestGate(gatedCount: 1)
        URLProtocolStub.requestHandler = { request in
            switch request.url?.path {
            case "/user/repos":
                return (okResponse(request), Data(repoListJSON(["repo-1"]).utf8))
            case "/repos/octo/repo-1/languages":
                // 门控住唯一 languages 请求，人为拉长在途窗口。
                gate.awaitIfGated()
                return (okResponse(request), Data(#"{"Swift": 10}"#.utf8))
            default:
                return (okResponse(request), Data("{}".utf8))
            }
        }

        fixture.service.load(login: fixture.login)
        // 列表 + languages 都已进入 stub（第二个请求正阻塞在 handler 里，
        // stub 在执行 handler 前就已登记计数）。
        try await waitForRequestCount(2)
        fixture.service.load(login: fixture.login)
        gate.releaseAll()
        try await waitForSnapshot(fixture.service)

        // 去重生效：同 login 的第二次 load 早退，不产生第 3 条请求。
        #expect(URLProtocolStub.receivedRequests.count == 2)
        let snapshot = try #require(fixture.service.snapshot)
        #expect(snapshot.repositoryCount == 1)
        #expect(snapshot.languages.map(\.bytes) == [10])
    }

    @Test("换号取消旧在途加载：旧任务清理不破坏新账号在途登记")
    func accountSwitchCancelsStaleInflight() async throws {
        let fixture = Fixture()
        let loginA = "switch-a-\(UUID().uuidString)"
        let loginB = "switch-b-\(UUID().uuidString)"
        defer {
            fixture.service.reset(login: loginA)
            fixture.service.reset(login: loginB)
            URLProtocolStub.reset()
        }
        let gate = RequestGate(gatedCount: 2)
        URLProtocolStub.requestHandler = { request in
            switch request.url?.path {
            case "/user/repos":
                // 两个账号的列表请求都被门控；列表为空，不触发 languages。
                gate.awaitIfGated()
                return (okResponse(request), Data("[]".utf8))
            default:
                return (okResponse(request), Data("{}".utf8))
            }
        }

        fixture.service.load(login: loginA)
        try await waitForRequestCount(1)
        // 换号：取消 A 的在途任务、登记并启动 B。
        fixture.service.load(login: loginB)
        try await waitForRequestCount(2)
        // 放行 A 的响应，给被取消的旧任务恢复执行 catch / defer 的窗口。
        gate.release(0)
        try await Task.sleep(for: .milliseconds(200))
        // 修复后：旧 defer 因代数不匹配跳过清理，B 的在途登记还在 → 本次 load 早退；
        // 缺陷版会误清登记并在此发出第 3 条请求。
        fixture.service.load(login: loginB)
        gate.release(1)
        try await waitForSnapshot(fixture.service)

        #expect(URLProtocolStub.receivedRequests.count == 2)
        let snapshot = try #require(fixture.service.snapshot)
        #expect(snapshot.login.lowercased() == loginB.lowercased())
        #expect(snapshot.repositoryCount == 0)
        #expect(fixture.service.lastError == nil)
    }

    @Test("缓存登录态发布时语言已恢复，无需验证网络")
    func cachedSessionPrimesLanguagesBeforeAuthentication() async throws {
        let fixture = Fixture()
        defer { fixture.cleanup() }
        let cached = try fixture.seedCache(age: 8 * 24 * 60 * 60)
        let user = GitHubUserDTO(
            id: 12345, login: fixture.login, name: nil, avatarUrl: nil,
            publicRepos: 1, followers: 0, following: 0,
            bio: nil, company: nil, location: nil, email: nil,
            blog: nil, twitterUsername: nil, htmlUrl: nil
        )
        let authAPIClient = MockGitHubAPIClient()
        authAPIClient.getCurrentUserHandler = {
            Issue.record("恢复本地缓存不能等待联网验证")
            throw URLError(.notConnectedToInternet)
        }
        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: authAPIClient,
            keychain: InMemoryKeychain()
        )
        session.developerLanguageService = fixture.service
        session.onUserSessionChanged = { [weak session] userID in
            #expect(userID == user.id)
            #expect(session?.state == .unauthenticated)
        }
        withObservationTracking {
            _ = session.state
        } onChange: {
            // 登录态在 MainActor 上同步修改；观察回调必须看到已经恢复的语言快照。
            MainActor.assumeIsolated {
                #expect(fixture.service.snapshot == cached)
            }
        }

        await session.activateCachedSession(user)

        #expect(session.state == .authenticated(user: user))
        #expect(fixture.service.snapshot == cached)
        #expect(URLProtocolStub.receivedRequests.isEmpty)
    }

    /// 等待可观察的请求结果而不是固定长延时，超时后直接报告本次刷新没有完成。
    private func waitForRefresh(
        _ service: DeveloperLanguageService,
        after fetchedAt: Date
    ) async throws {
        for _ in 0..<200 {
            if service.lastFetchedAt != fetchedAt || service.lastError != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("开发语言后台刷新未在预期时间内完成")
    }

    /// 等待 stub 收到的请求计数达到目标。stub 在执行 handler 前就登记计数，
    /// 因此计数达标即代表阻塞中的请求也已进入，可安全衔接门控放行。
    private func waitForRequestCount(_ count: Int) async throws {
        for _ in 0..<200 {
            if URLProtocolStub.receivedRequests.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("请求计数未在预期时间内达到 \(count)")
    }

    /// 等待首次快照落定（成功或失败），超时后报告。
    private func waitForSnapshot(_ service: DeveloperLanguageService) async throws {
        for _ in 0..<200 {
            if service.snapshot != nil || service.lastError != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("开发语言快照未在预期时间内完成")
    }

    /// 独立账号键隔离持久化数据；清理只影响本测试创建的快照。
    @MainActor
    private struct Fixture {
        let login = "developer-language-tests-\(UUID().uuidString)"
        let apiClient: GitHubAPIClient
        let service: DeveloperLanguageService

        init() {
            URLProtocolStub.reset()
            URLProtocolStub.requestHandler = { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
                return (response, Data("[]".utf8))
            }
            apiClient = GitHubAPIClient(
                baseURL: URL(string: "https://developer-languages.test.invalid")!,
                session: URLProtocolStub.ephemeralSession(),
                tokenProvider: StubTokenProvider(token: nil)
            )
            service = DeveloperLanguageService(apiClient: apiClient)
        }

        /// 按既有磁盘格式准备旧快照，同时验证升级后无需清缓存或迁移。
        func seedCache(age: TimeInterval) throws -> DeveloperLanguageSnapshot {
            // 封装使用 Unix 时间，快照使用 Codable Date；整秒时间避免换算误差让等待提前结束。
            let fetchedAt = Date(
                timeIntervalSince1970: (Date().timeIntervalSince1970 - age).rounded(.down)
            )
            let snapshot = DeveloperLanguageSnapshot(
                login: login,
                fetchedAt: fetchedAt,
                repositoryCount: 1,
                totalBytes: 100,
                languages: [DeveloperLanguageEntry(name: "Swift", bytes: 100, ratio: 1)]
            )
            let envelope = DiskEnvelope(
                fetchedAt: snapshot.fetchedAt.timeIntervalSince1970,
                snapshot: snapshot
            )
            UserDefaults.standard.set(
                try JSONEncoder().encode(envelope),
                forKey: "developer.languages.snapshot.\(login.lowercased())"
            )
            return snapshot
        }

        func cleanup() {
            service.reset(login: login)
            URLProtocolStub.reset()
        }
    }

    /// 仅描述测试输入的历史缓存结构，不向生产服务暴露内部持久化类型。
    private struct DiskEnvelope: Encodable {
        let fetchedAt: TimeInterval
        let snapshot: DeveloperLanguageSnapshot
    }
}

// MARK: - P2-6 测试帮助设施

/// stub 线程内阻塞 / 放行请求的门。
///
/// `awaitIfGated()` 在 URLProtocolStub 的加载线程执行，阻塞的是 stub 线程而非
/// MainActor；测试在 MainActor 上显式 release。NSLock 保护序号计数与信号量，
/// 类型以 @unchecked Sendable 承诺线程安全，供 @Sendable handler 闭包捕获。
private final class RequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let gates: [DispatchSemaphore]
    private var nextIndex = 0

    init(gatedCount: Int) {
        gates = (0..<gatedCount).map { _ in DispatchSemaphore(value: 0) }
    }

    /// handler 进入点：按到达顺序领取序号，序号落在门控范围内的请求阻塞等待放行。
    func awaitIfGated() {
        let assigned = lock.withLock { () -> Int in
            let index = nextIndex
            nextIndex += 1
            return index
        }
        guard assigned < gates.count else { return }
        gates[assigned].wait()
    }

    /// 放行第 index 个被门控的请求。
    func release(_ index: Int) {
        gates[index].signal()
    }

    /// 放行全部已门控请求（测试收尾兜底，避免 stub 线程永久阻塞）。
    func releaseAll() {
        lock.withLock {
            for semaphore in gates { semaphore.signal() }
        }
    }
}

/// 构造 GitHubRepoDTO 列表的最小 JSON；字段集满足 DTO 必填解码要求，
/// snake_case 键由生产 decoder 的 convertFromSnakeCase 映射。
private func repoListJSON(_ names: [String]) -> String {
    let items = names.enumerated().map { index, name in
        "{\"id\": \(100 + index), \"name\": \"\(name)\", \"full_name\": \"octo/\(name)\", \"owner\": {\"id\": 1, \"login\": \"octo\"}, \"private\": false, \"fork\": false, \"archived\": false, \"stargazers_count\": 1, \"forks_count\": 0, \"watchers_count\": 0, \"html_url\": \"https://github.com/octo/\(name)\"}"
    }
    return "[" + items.joined(separator: ",") + "]"
}

/// 最小 200 响应（无 Link 头 → 单页列表）。
private func okResponse(_ request: URLRequest) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
}
