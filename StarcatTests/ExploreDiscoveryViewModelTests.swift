//
//  ExploreDiscoveryViewModelTests.swift
//  StarcatTests
//
//  探索页 Discovery API 列表状态机测试。
//
//  覆盖目标：
//  - 热门 / 新发布 / 发现模块走正确 endpoint 与 query；
//  - 服务端分页 meta 能驱动 ViewModel 追加下一页；
//  - Discovery 服务不可用时只影响探索列表，不留下过期列表状态。
//
//  测试基础设施：
//  - 复用 `URLProtocolStub`，所有请求都落在测试 URLSession 内；
//  - Suite 串行执行，避免 URLProtocolStub 的静态状态被并发测试串扰；
//  - 不触碰 Keychain，也不依赖真实 starcat-discovery-api。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Explore Discovery ViewModel", .serialized)
@MainActor
struct ExploreDiscoveryViewModelTests {

    private let baseURL = URL(string: "https://discovery.test.invalid")!

    @Test("热门列表透传语言和排序参数")
    func popularReloadPassesLanguageAndSortQuery() async throws {
        let api = makeAPI()
        let viewModel = ExploreDiscoveryViewModel()

        URLProtocolStub.requestHandler = { request in
            let body = Self.makePageBody(repoID: 101, owner: "apple", name: "swift-collections")
            return (Self.httpResponse(200, request.url!), body)
        }

        await viewModel.reload(
            api: api,
            mode: .popular,
            language: "Swift",
            topic: nil,
            platform: nil,
            sort: .stars
        )

        #expect(viewModel.repos.count == 1)
        #expect(viewModel.total == 1)
        #expect(viewModel.nextPage == nil)
        #expect(viewModel.loadError == nil)

        let request = try #require(URLProtocolStub.receivedRequests.first)
        #expect(request.url?.path == "/api/v1/discovery/categories/most-popular")
        let query = Self.queryItems(for: request)
        #expect(query["language"] == "Swift")
        #expect(query["sort"] == "stars")
        #expect(query["page"] == "1")
        #expect(query["limit"] == "20")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test("分页 meta 驱动 loadMore 追加下一页")
    func loadMoreAppendsNextPageFromMeta() async throws {
        let api = makeAPI()
        let viewModel = ExploreDiscoveryViewModel()

        URLProtocolStub.requestHandler = { request in
            let query = Self.queryItems(for: request)
            if query["page"] == "2" {
                let body = Self.makePageBody(
                    repoID: 202,
                    owner: "swiftlang",
                    name: "swift-format",
                    total: 2,
                    nextPage: nil
                )
                return (Self.httpResponse(200, request.url!), body)
            }

            let body = Self.makePageBody(
                repoID: 201,
                owner: "swiftlang",
                name: "swift-syntax",
                total: 2,
                nextPage: 2
            )
            return (Self.httpResponse(200, request.url!), body)
        }

        await viewModel.reload(
            api: api,
            mode: .newReleases,
            language: "Swift",
            topic: nil,
            platform: nil,
            sort: .release
        )

        let firstRepo = try #require(viewModel.repos.first)
        #expect(viewModel.nextPage == 2)

        await viewModel.loadMoreIfNeeded(
            api: api,
            currentRepo: firstRepo,
            mode: .newReleases,
            language: "Swift",
            topic: nil,
            platform: nil,
            sort: .release
        )

        #expect(viewModel.repos.map(\.fullName) == ["swiftlang/swift-syntax", "swiftlang/swift-format"])
        #expect(viewModel.total == 2)
        #expect(viewModel.nextPage == nil)
        #expect(URLProtocolStub.receivedRequests.count == 2)

        let secondRequest = try #require(URLProtocolStub.receivedRequests.last)
        #expect(secondRequest.url?.path == "/api/v1/discovery/categories/new-releases")
        #expect(Self.queryItems(for: secondRequest)["page"] == "2")
    }

    @Test("服务端错误时清空列表并记录可恢复错误")
    func reloadServerErrorClearsListAndStoresError() async throws {
        let api = makeAPI()
        let viewModel = ExploreDiscoveryViewModel()

        URLProtocolStub.requestHandler = { request in
            let body = Self.makePageBody(repoID: 301, owner: "initial", name: "repo")
            return (Self.httpResponse(200, request.url!), body)
        }

        await viewModel.reload(
            api: api,
            mode: .discover,
            language: nil,
            topic: "ai",
            platform: "macos",
            sort: .recommended
        )

        #expect(viewModel.repos.count == 1)

        URLProtocolStub.requestHandler = { request in
            let body = """
            {
              "schema_version": 1,
              "error": {
                "code": "INTERNAL_ERROR",
                "message": "Discovery service unavailable"
              }
            }
            """.data(using: .utf8)!
            return (Self.httpResponse(503, request.url!), body)
        }

        await viewModel.reload(
            api: api,
            mode: .discover,
            language: nil,
            topic: "ai",
            platform: "macos",
            sort: .recommended
        )

        #expect(viewModel.repos.isEmpty)
        #expect(viewModel.total == 0)
        #expect(viewModel.nextPage == nil)
        #expect(viewModel.loadError?.isEmpty == false)
        #expect(!viewModel.isLoading)
        #expect(!viewModel.isRefreshing)

        let failedRequest = try #require(URLProtocolStub.receivedRequests.last)
        let query = Self.queryItems(for: failedRequest)
        #expect(failedRequest.url?.path == "/api/v1/discovery/feed")
        #expect(query["topic"] == "ai")
        #expect(query["platform"] == "macos")
        #expect(query["sort"] == nil)
    }

    private func makeAPI() -> DiscoveryAPI {
        URLProtocolStub.reset()
        return DiscoveryAPI(
            baseURL: baseURL,
            apiKey: "test-discovery-key",
            session: URLProtocolStub.ephemeralSession()
        )
    }

    private nonisolated static func httpResponse(_ statusCode: Int, _ url: URL) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        )!
    }

    private nonisolated static func queryItems(for request: URLRequest) -> [String: String] {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    private nonisolated static func makePageBody(
        repoID: Int64,
        owner: String,
        name: String,
        total: Int = 1,
        nextPage: Int? = nil
    ) -> Data {
        let fullName = "\(owner)/\(name)"
        let nextPageJSON = nextPage.map(String.init) ?? "null"
        return """
        {
          "schema_version": 1,
          "data": [
            {
              "repo_id": \(repoID),
              "full_name": "\(fullName)",
              "owner": "\(owner)",
              "name": "\(name)",
              "description": "A repository for discovery tests.",
              "homepage": null,
              "language": "Swift",
              "stars": 1000,
              "forks": 100,
              "watchers": 1000,
              "subscribers": 20,
              "open_issues": 5,
              "owner_avatar": null,
              "default_branch": "main",
              "license_spdx": "MIT",
              "topics": ["swift", "developer-tools"],
              "platforms": ["macos"],
              "pushed_at": "2026-06-29T00:00:00Z",
              "updated_at": "2026-06-29T00:00:00Z",
              "created_at": "2025-01-01T00:00:00Z",
              "is_archived": false,
              "is_fork": false,
              "latest_release_tag": "1.0.0",
              "latest_release_at": "2026-06-28T00:00:00Z",
              "latest_release_url": "https://github.com/\(fullName)/releases/tag/1.0.0",
              "release_download_count": 42,
              "rank": 1,
              "score": 98.5,
              "reasons": ["Active repository"],
              "signals": [
                { "code": "release", "label": "Recent release", "value": "1.0.0" }
              ]
            }
          ],
          "meta": {
            "page": 1,
            "page_size": 20,
            "total": \(total),
            "next_page": \(nextPageJSON)
          }
        }
        """.data(using: .utf8)!
    }
}
