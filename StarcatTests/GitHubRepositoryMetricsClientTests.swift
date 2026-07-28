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
