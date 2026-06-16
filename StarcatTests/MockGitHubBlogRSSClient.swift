//
//  MockGitHubBlogRSSClient.swift
//  StarcatTests
//
//  Activity PR-3（2026-06-17）：GitHub Blog RSS 客户端测试替身。
//

import Foundation
@testable import Starcat

/// `GitHubBlogRSSAPIProtocol` 的 handler 注入 mock。
final class MockGitHubBlogRSSClient: GitHubBlogRSSAPIProtocol, @unchecked Sendable {

    var fetchFeedHandler: ((String?) async throws -> APIResponse<[GitHubBlogRSSItemDTO]>)?
    private(set) var fetchFeedCalls: [String?] = []

    func fetchFeed(ifNoneMatch: String?) async throws -> APIResponse<[GitHubBlogRSSItemDTO]> {
        fetchFeedCalls.append(ifNoneMatch)
        if let handler = fetchFeedHandler {
            return try await handler(ifNoneMatch)
        }
        return APIResponse(
            value: [],
            linkHeader: LinkHeader(nextPage: nil, lastPage: nil),
            rateLimit: RateLimitInfo(limit: nil, remaining: nil, reset: nil),
            statusCode: 200,
            etag: "\"mock-blog-etag\""
        )
    }
}
