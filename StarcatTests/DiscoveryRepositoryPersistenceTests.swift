//
//  DiscoveryRepositoryPersistenceTests.swift
//  StarcatTests
//
//  DiscoveryRepository 的 SQLite 缓存 round-trip 测试。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Discovery Repository Persistence", .serialized)
struct DiscoveryRepositoryPersistenceTests {

    @Test("列表页 fetch 后可从 SQLite 缓存读回")
    func fetchPagePersistsCache() async throws {
        let repository = try makeRepository { request in
            let body = Self.makePageBody(repoID: 501, owner: "cache", name: "repo")
            return (Self.httpResponse(200, request.url!), body)
        }

        let query = DiscoveryListQuery(language: "Swift", sort: "stars", page: 1, limit: 20)
        let fetched = try await repository.fetchPage(mode: .popular, query: query)
        #expect(fetched.page.items.first?.fullName == "cache/repo")

        let cached = try #require(await repository.cachedPage(mode: .popular, query: query))
        #expect(cached.page.items.first?.repoID == 501)
        #expect(cached.page.total == 1)
        #expect(cached.page.nextPage == nil)
    }

    @Test("summary fetch 后可从 SQLite 缓存读回")
    func fetchSummaryPersistsCache() async throws {
        let repository = try makeRepository { request in
            let body = """
            {
              "schema_version": 1,
              "data": {
                "generated_at": "2026-06-30T10:00:00Z",
                "modes": [
                  {
                    "mode": "discover",
                    "total": 12,
                    "topics": [
                      { "key": "ai", "label": "人工智能", "count": 5 }
                    ],
                    "platforms": [
                      { "key": "macos", "label": "macOS", "count": 3, "system_name": "desktopcomputer" }
                    ]
                  },
                  {
                    "mode": "popular",
                    "total": 8,
                    "languages": [
                      { "key": "Swift", "label": "Swift", "count": 4 }
                    ]
                  }
                ]
              }
            }
            """.data(using: .utf8)!
            return (Self.httpResponse(200, request.url!), body)
        }

        let fetched = try await repository.fetchSummary()
        #expect(fetched.mode(.discover)?.total == 12)

        let cached = try #require(await repository.cachedSummary())
        #expect(cached.generatedAt == "2026-06-30T10:00:00Z")
        #expect(cached.mode(.discover)?.topics?.first?.count == 5)
        #expect(cached.mode(.popular)?.languages?.first?.key == "Swift")
    }

    @Test("bulk fetch 后可从 SQLite 缓存读回")
    func fetchBulkPersistsCache() async throws {
        let repository = try makeRepository { request in
            let body = Self.makeBulkBody(repoID: 601, owner: "bulk", name: "repo")
            return (Self.httpResponse(200, request.url!, headers: ["ETag": "W/bulk-test"]), body)
        }

        let fetched = try await repository.fetchBulk()
        #expect(fetched.repos.first?.fullName == "bulk/repo")
        #expect(fetched.repos.first?.popularityScore == 8.5)
        #expect(fetched.repos.first?.categories == ["popular", "new_releases"])
        #expect(fetched.summary.mode(.discover)?.total == 1)

        let cached = try #require(await repository.cachedBulk())
        #expect(cached.repos.first?.repoID == 601)
        #expect(cached.repos.first?.releaseScore == 7.5)
        #expect(cached.repos.first?.categoryRanks["new_releases"] == 2)
        #expect(cached.summary.mode(.popular)?.languages?.first?.key == "Swift")
        #expect(cached.etag == "W/bulk-test")
    }


    private func makeRepository(
        handler: @escaping @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    ) throws -> DiscoveryRepository {
        URLProtocolStub.reset()
        URLProtocolStub.requestHandler = handler
        let db = try InMemoryDatabaseManager()
        let api = DiscoveryAPI(
            baseURL: URL(string: "https://discovery.test.invalid")!,
            apiKey: "test-key",
            session: URLProtocolStub.ephemeralSession()
        )
        return DiscoveryRepository(api: api, database: db)
    }

    private nonisolated static func httpResponse(
        _ statusCode: Int,
        _ url: URL,
        headers: [String: String] = [:]
    ) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private nonisolated static func makePageBody(
        repoID: Int64,
        owner: String,
        name: String
    ) -> Data {
        let fullName = "\(owner)/\(name)"
        return """
        {
          "schema_version": 1,
          "data": [
            {
              "repo_id": \(repoID),
              "full_name": "\(fullName)",
              "owner": "\(owner)",
              "name": "\(name)",
              "description": "Cached discovery repository.",
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
              "topics": ["swift"],
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
              "reasons": ["popular"],
              "signals": [
                { "code": "release", "label": "Recent release", "value": "1.0.0" }
              ]
            }
          ],
          "meta": {
            "page": 1,
            "page_size": 20,
            "total": 1,
            "next_page": null
          }
        }
        """.data(using: .utf8)!
    }

    private nonisolated static func makeBulkBody(
        repoID: Int64,
        owner: String,
        name: String
    ) -> Data {
        let fullName = "\(owner)/\(name)"
        return """
        {
          "schema_version": 1,
          "data": {
            "repos": [
              {
                "repo_id": \(repoID),
                "full_name": "\(fullName)",
                "owner": "\(owner)",
                "name": "\(name)",
                "description": "Cached discovery repository.",
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
                "topics": ["tools"],
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
                "score": 9.5,
                "trending_score": 6.5,
                "popularity_score": 8.5,
                "release_score": 7.5,
                "discovery_score": 9.5,
                "search_score": 1000,
                "categories": ["popular", "new_releases"],
                "category_ranks": { "popular": 1, "new_releases": 2 },
                "reasons": ["popular"],
                "signals": [
                  { "code": "release", "label": "Recent release", "value": "1.0.0" }
                ]
              }
            ],
            "summary": {
              "generated_at": "2026-06-30T10:00:00Z",
              "modes": [
                {
                  "mode": "discover",
                  "total": 1,
                  "topics": [
                    { "key": "tools", "label": "工具", "count": 1 }
                  ],
                  "platforms": [
                    { "key": "macos", "label": "macOS", "count": 1, "system_name": "desktopcomputer" }
                  ]
                },
                {
                  "mode": "popular",
                  "total": 1,
                  "languages": [
                    { "key": "Swift", "label": "Swift", "count": 1 }
                  ]
                }
              ]
            }
          },
          "meta": {
            "total": 1,
            "generated_at": "2026-06-30T10:00:00Z"
          }
        }
        """.data(using: .utf8)!
    }
}
