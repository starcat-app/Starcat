//
//  GitHubRepositorySearchTests.swift
//  StarcatTests
//
//  验证 GitHub Repository Search qualifier、排序和日期格式。
//

import Foundation
import Testing
@testable import Starcat

@Suite("GitHub Repository Search")
struct GitHubRepositorySearchTests {
    @Test("query builder 生成结构化 qualifiers")
    func structuredQuery() throws {
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(year: 2025, month: 6, day: 1)))
        let filters = GitHubSearchFilters(
            language: " Swift ",
            topic: "macos",
            minimumStars: 100,
            createdAfter: date,
            pushedAfter: nil,
            sort: .stars,
            order: .descending
        )
        let query = GitHubRepositorySearchQuery(text: "menu bar", filters: filters)

        #expect(query.encodedQuery == "menu bar language:Swift topic:macos stars:>=100 created:>=2025-06-01")
        #expect(query.queryItems.contains(URLQueryItem(name: "sort", value: "stars")))
        #expect(query.queryItems.contains(URLQueryItem(name: "order", value: "desc")))
    }

    @Test("best match 不发送 sort 和 order")
    func bestMatchOmitsSort() {
        let query = GitHubRepositorySearchQuery(text: "swift", filters: .empty)
        #expect(!query.queryItems.contains { $0.name == "sort" })
        #expect(!query.queryItems.contains { $0.name == "order" })
    }
}
