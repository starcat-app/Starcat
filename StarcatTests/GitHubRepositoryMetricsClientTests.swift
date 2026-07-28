//
//  GitHubRepositoryMetricsClientTests.swift
//  StarcatTests
//
//  覆盖共享 GitHub Metrics Client 的类型化解码、统一请求头、稳定错误与 actor 串行约束。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHub repository metrics client")
struct GitHubRepositoryMetricsClientTests {

    private let repository = RepoIdentity(ghRepoID: 7, owner: "octo", name: "demo")

    @Test("Search Issues 注入统一请求头并返回候选仓库内的类型化结果")
    func searchIssuesUsesSharedRequestContract() async throws {
        let body = Data(
            """
            {
              "total_count": 1,
              "items": [{
                "number": 12,
                "title": "Crash",
                "state": "open",
                "html_url": "https://github.com/octo/demo/issues/12",
                "repository_url": "https://api.github.com/repos/octo/demo",
                "body": "details",
                "labels": [{"name":"bug"}],
                "comments": 2,
                "created_at": "2026-07-20T00:00:00Z",
                "closed_at": null,
                "updated_at": "2026-07-21T00:00:00Z"
              }]
            }
            """.utf8
        )
        let httpClient = MetricsHTTPClient(responses: [
            .init(
                data: body,
                statusCode: 200,
                headers: [
                    "ETag": "\"metrics-v1\"",
                    "X-RateLimit-Remaining": "4999",
                    "X-RateLimit-Reset": "1785142800"
                ]
            )
        ])
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: "test-token",
            baseURL: URL(string: "https://api.example.test")!
        )

        let response = try await client.searchIssues(
            repository: repository,
            query: "repo:octo/demo is:issue crash",
            sort: "updated",
            order: "desc",
            perPage: 10
        )
        let request = try #require(await httpClient.requests().first)

        #expect(response.value.totalCount == 1)
        #expect(response.value.items.first?.title == "Crash")
        #expect(response.value.items.first?.belongs(to: repository) == true)
        #expect(response.etag == "\"metrics-v1\"")
        #expect(response.rateLimit.remaining == 4_999)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.url?.path == "/search/issues")
        #expect(request.url?.query?.contains("per_page=10") == true)
    }

    @Test("Commit、Contributors 与 Community 使用类型化 DTO")
    func typedRepositoryEndpoints() async throws {
        let httpClient = MetricsHTTPClient(responses: [
            .json(#"[{"week":1785100000,"total":9,"days":[1,1,1,1,1,2,2]}]"#),
            .json(#"[{"login":"octocat","contributions":42,"avatar_url":"https://example.test/a.png","html_url":"https://github.com/octocat"}]"#),
            .json(
                #"{"health_percentage":75,"files":{"code_of_conduct":null,"code_of_conduct_file":{"html_url":"https://github.com/octo/demo/blob/main/CODE_OF_CONDUCT.md"},"contributing":{"html_url":"https://github.com/octo/demo/blob/main/CONTRIBUTING.md"},"license":{"html_url":"https://github.com/octo/demo/blob/main/LICENSE"},"readme":{"html_url":"https://github.com/octo/demo#readme"}}}"#
            )
        ])
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: nil,
            baseURL: URL(string: "https://api.example.test")!
        )

        let commits = try await client.loadCommitActivity(repository: repository)
        let contributors = try await client.loadContributors(repository: repository, limit: 8)
        let community = try await client.loadCommunityProfile(repository: repository)
        let paths = await httpClient.requests().compactMap(\.url?.path)

        #expect(commits.value.first?.total == 9)
        #expect(contributors.value.first?.login == "octocat")
        #expect(contributors.value.first?.contributions == 42)
        #expect(community.value.healthPercentage == 75)
        #expect(community.value.hasReadme)
        #expect(community.value.hasCodeOfConduct)
        #expect(community.value.hasContributing)
        #expect(community.value.hasLicense)
        #expect(community.value.readmeHTMLURL?.absoluteString == "https://github.com/octo/demo#readme")
        #expect(
            community.value.codeOfConductHTMLURL?.absoluteString
                == "https://github.com/octo/demo/blob/main/CODE_OF_CONDUCT.md"
        )
        #expect(
            community.value.contributingHTMLURL?.absoluteString
                == "https://github.com/octo/demo/blob/main/CONTRIBUTING.md"
        )
        #expect(
            community.value.licenseHTMLURL?.absoluteString
                == "https://github.com/octo/demo/blob/main/LICENSE"
        )
        #expect(paths == [
            "/repos/octo/demo/stats/commit_activity",
            "/repos/octo/demo/contributors",
            "/repos/octo/demo/community/profile"
        ])
    }

    @Test("202、403、429、404 与 422 映射为稳定错误")
    func statusCodesMapToStableErrors() async throws {
        let reset = Date(timeIntervalSince1970: 1_785_142_800)
        let cases: [(MetricsHTTPResponse, GitHubRepositoryMetricsError)] = [
            (
                .error(statusCode: 202, headers: ["Retry-After": "3"]),
                .generating(retryAfter: 3)
            ),
            (
                .error(
                    statusCode: 403,
                    headers: [
                        "X-RateLimit-Remaining": "0",
                        "X-RateLimit-Reset": "1785142800"
                    ]
                ),
                .rateLimited(
                    statusCode: 403,
                    message: "stub error",
                    retryAfter: nil,
                    resetAt: reset
                )
            ),
            (
                .error(statusCode: 429, headers: ["Retry-After": "7"]),
                .rateLimited(
                    statusCode: 429,
                    message: "stub error",
                    retryAfter: 7,
                    resetAt: nil
                )
            ),
            (
                .error(statusCode: 404),
                .unavailable(statusCode: 404, message: "stub error")
            ),
            (
                .error(statusCode: 422),
                .unavailable(statusCode: 422, message: "stub error")
            )
        ]

        for (response, expected) in cases {
            let client = DefaultGitHubRepositoryMetricsClient(
                httpClient: MetricsHTTPClient(responses: [response]),
                token: nil
            )
            do {
                _ = try await client.loadCommitActivity(repository: repository)
                Issue.record("Expected \(expected)")
            } catch let error as GitHubRepositoryMetricsError {
                #expect(error == expected)
            }
        }
    }

    @Test("收到 Retry-After 后限流窗口内不再重复出站")
    func rateLimitBackoffStopsQueuedRequests() async throws {
        let currentDate = Date(timeIntervalSince1970: 10_000)
        let httpClient = MetricsHTTPClient(responses: [
            .error(statusCode: 429, headers: ["Retry-After": "60"])
        ])
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: nil,
            now: { currentDate }
        )

        do {
            _ = try await client.loadCommitActivity(repository: repository)
            Issue.record("首次请求应返回限流错误")
        } catch let error as GitHubRepositoryMetricsError {
            #expect(error.statusCode == 429)
        }

        do {
            _ = try await client.loadCommunityProfile(repository: repository)
            Issue.record("backoff 窗口内请求应直接失败")
        } catch let GitHubRepositoryMetricsError.rateLimited(
            statusCode,
            _,
            retryAfter,
            resetAt
        ) {
            #expect(statusCode == 429)
            #expect(retryAfter == 60)
            #expect(resetAt == currentDate.addingTimeInterval(60))
        }

        #expect(await httpClient.requests().count == 1)
    }

    @Test("404 不可用结果在负缓存窗口内不重复出站")
    func unavailableEndpointUsesNegativeCache() async throws {
        let httpClient = MetricsHTTPClient(responses: [
            .error(statusCode: 404)
        ])
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: "test-token"
        )

        for _ in 0..<2 {
            do {
                _ = try await client.loadCommitActivity(repository: repository)
                Issue.record("404 应保持 unavailable 失败")
            } catch let GitHubRepositoryMetricsError.unavailable(statusCode, message) {
                #expect(statusCode == 404)
                #expect(message == "stub error")
            } catch {
                Issue.record("期望 unavailable，实际: \(error)")
            }
        }

        #expect(await httpClient.requests().count == 1)
    }

    @Test("401 不写入 endpoint 失败缓存")
    func unauthorizedResponseIsRetried() async throws {
        let httpClient = MetricsHTTPClient(responses: [
            .error(statusCode: 401),
            .json("[]")
        ])
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: "expired-token"
        )

        do {
            _ = try await client.loadCommitActivity(repository: repository)
            Issue.record("首次请求应返回 unauthorized")
        } catch GitHubRepositoryMetricsError.unauthorized {
            // 401 可能由 Token 更新立即恢复，不能复用普通 endpoint 退避。
        } catch {
            Issue.record("期望 unauthorized，实际: \(error)")
        }

        let response = try await client.loadCommitActivity(repository: repository)

        #expect(response.value.isEmpty)
        #expect(await httpClient.requests().count == 2)
    }

    @Test("普通失败按 2 秒和 4 秒逐级退避，成功后恢复")
    func transientFailuresUseBoundedExponentialBackoff() async throws {
        let clock = MetricsTestClock(Date(timeIntervalSince1970: 20_000))
        let httpClient = MetricsHTTPClient(responses: [
            .error(statusCode: 500),
            .error(statusCode: 500),
            .json("[]")
        ])
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: nil,
            now: { clock.now() }
        )

        await expectFailure {
            _ = try await client.loadCommitActivity(repository: repository)
        }
        await expectFailure {
            _ = try await client.loadCommitActivity(repository: repository)
        }
        #expect(await httpClient.requests().count == 1)

        clock.advance(by: 2)
        await expectFailure {
            _ = try await client.loadCommitActivity(repository: repository)
        }
        await expectFailure {
            _ = try await client.loadCommitActivity(repository: repository)
        }
        #expect(await httpClient.requests().count == 2)

        clock.advance(by: 4)
        let response = try await client.loadCommitActivity(repository: repository)

        #expect(response.value.isEmpty)
        #expect(await httpClient.requests().count == 3)
    }

    @Test("Token 切换后不继承旧账号限流窗口")
    func rateLimitBackoffIsScopedByAuthorization() async throws {
        let tokenProvider = MutableMetricsTokenProvider(token: "old-token")
        let httpClient = MetricsHTTPClient(responses: [
            .error(statusCode: 429, headers: ["Retry-After": "60"]),
            .json("[]")
        ])
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            tokenProvider: tokenProvider
        )

        await expectFailure {
            _ = try await client.loadCommitActivity(repository: repository)
        }
        await tokenProvider.update(token: "new-token")
        let response = try await client.loadCommitActivity(repository: repository)
        let requests = await httpClient.requests()

        #expect(response.value.isEmpty)
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer old-token")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
    }

    @Test("主动清理瞬时状态后同一认证可重新出站")
    func clearingTransientStateResetsRateLimitBackoff() async throws {
        let httpClient = MetricsHTTPClient(responses: [
            .error(statusCode: 429, headers: ["Retry-After": "60"]),
            .json("[]")
        ])
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: "test-token"
        )

        await expectFailure {
            _ = try await client.loadCommitActivity(repository: repository)
        }
        await client.clearTransientState()
        let response = try await client.loadCommitActivity(repository: repository)

        #expect(response.value.isEmpty)
        #expect(await httpClient.requests().count == 2)
    }

    @Test("主动清理瞬时状态会取消并等待普通洞察请求")
    func clearingTransientStateCancelsInflightRequest() async throws {
        let httpClient = CancellableMetricsHTTPClient()
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: "test-token"
        )
        let loadTask = Task {
            try await client.loadCommitActivity(repository: repository)
        }

        await httpClient.waitUntilStarted()
        await client.clearTransientState()

        do {
            _ = try await loadTask.value
            Issue.record("切换作用域应取消旧账号请求")
        } catch is CancellationError {
            // clearTransientState 必须等该取消到达终态后才返回。
        } catch {
            Issue.record("期望 CancellationError，实际: \(error)")
        }
        #expect(await httpClient.requestCount() == 1)
    }

    @Test("不同仓库的指标请求仍按顺序出站")
    func requestsAreSerialized() async throws {
        let httpClient = ConcurrencyProbeMetricsHTTPClient()
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: nil
        )
        let anotherRepository = RepoIdentity(ghRepoID: 8, owner: "octo", name: "another")

        async let first = client.loadCommitActivity(repository: repository)
        async let second = client.loadCommitActivity(repository: anotherRepository)
        _ = try await (first, second)

        #expect(await httpClient.maximumConcurrentRequests() == 1)
        #expect(await httpClient.requestCount() == 2)
    }

    @Test("完全相同的普通指标请求只出站一次")
    func identicalRequestsShareInflightTask() async throws {
        let httpClient = ConcurrencyProbeMetricsHTTPClient()
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: nil
        )

        async let first = client.loadCommitActivity(repository: repository)
        async let second = client.loadCommitActivity(repository: repository)
        _ = try await (first, second)

        #expect(await httpClient.requestCount() == 1)
    }

    @Test("带 observer 的 RAG 指标请求保持一一对应的出站审计")
    func observedRequestsAreNotMerged() async throws {
        let httpClient = ConcurrencyProbeMetricsHTTPClient()
        let client = DefaultGitHubRepositoryMetricsClient(
            httpClient: httpClient,
            token: nil
        )
        let observer: GitHubMetricsRequestObserver = { _ in }

        async let first = client.loadCommitActivity(
            repository: repository,
            observer: observer
        )
        async let second = client.loadCommitActivity(
            repository: repository,
            observer: observer
        )
        _ = try await (first, second)

        #expect(await httpClient.maximumConcurrentRequests() == 1)
        #expect(await httpClient.requestCount() == 2)
    }

    private func expectFailure(
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            Issue.record("期望请求失败但成功返回")
        } catch {
            // 测试只关心是否出站和退避节奏，具体 HTTP 映射由 statusCodesMapToStableErrors 覆盖。
        }
    }
}

private struct MetricsHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]

    static func json(_ body: String) -> MetricsHTTPResponse {
        MetricsHTTPResponse(data: Data(body.utf8), statusCode: 200, headers: [:])
    }

    static func error(
        statusCode: Int,
        headers: [String: String] = [:]
    ) -> MetricsHTTPResponse {
        MetricsHTTPResponse(
            data: Data(#"{"message":"stub error"}"#.utf8),
            statusCode: statusCode,
            headers: headers
        )
    }
}

private actor MetricsHTTPClient: RAGHTTPClientProtocol {
    private var queuedResponses: [MetricsHTTPResponse]
    private var recordedRequests: [URLRequest] = []

    init(responses: [MetricsHTTPResponse]) {
        self.queuedResponses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !queuedResponses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let response = queuedResponses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        return (response.data, httpResponse)
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

/// 测试专用动态 Token Provider，用于验证账号边界不会复用限流状态。
private actor MutableMetricsTokenProvider: GitHubTokenProviding {
    private var token: String?

    init(token: String?) {
        self.token = token
    }

    func currentToken() -> String? {
        token
    }

    func update(token: String?) {
        self.token = token
    }
}

/// 测试专用可变时钟；NSLock 只保护同步 Date，避免引入真实等待。
private final class MetricsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

/// 通过长挂起请求验证 clearTransientState 会取消并等待共享 Task，不使用真实网络。
private actor CancellableMetricsHTTPClient: RAGHTTPClientProtocol {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var totalRequests = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        totalRequests += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await Task.sleep(for: .seconds(60))
        return (
            Data("[]".utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func requestCount() -> Int {
        totalRequests
    }
}

private actor ConcurrencyProbeMetricsHTTPClient: RAGHTTPClientProtocol {
    private var activeRequests = 0
    private var maximumRequests = 0
    private var totalRequests = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        totalRequests += 1
        activeRequests += 1
        maximumRequests = max(maximumRequests, activeRequests)
        try await Task.sleep(for: .milliseconds(40))
        activeRequests -= 1
        return (
            Data("[]".utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
        )
    }

    func maximumConcurrentRequests() -> Int {
        maximumRequests
    }

    func requestCount() -> Int {
        totalRequests
    }
}
