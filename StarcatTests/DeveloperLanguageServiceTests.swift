//
//  DeveloperLanguageServiceTests.swift
//  StarcatTests
//
//  开发语言缓存回归测试：首屏不等待联网，七天内复用快照，过期后台刷新。
//  每项测试使用独立账号缓存键，避免清除真实用户或其他测试的统计。
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
