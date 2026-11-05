//
//  FollowGraphAPI.swift
//  Starcat
//
//  复用 GitHubAPIClient 的认证、401 与 GraphQL 错误处理，不向渲染页面暴露 Token。
//

import Foundation

/// following 查询只返回公开身份、游标与 GraphQL 配额，不允许 partial data 冒充成功。
struct FollowGraphAPI: FollowGraphProviding {
    let client: GitHubAPIClient

    func page(login: String, cursor: String?, count: Int) async throws -> FollowGraphPage {
        var variables: [String: Any] = ["login": login, "first": min(100, max(1, count))]
        if let cursor { variables["after"] = cursor }
        let data: Response = try await client.graphql(query: """
        query($login: String!, $first: Int!, $after: String) {
          user(login: $login) {
            databaseId login name avatarUrl
            following(first: $first, after: $after) {
              totalCount pageInfo { endCursor hasNextPage }
              nodes { databaseId login name avatarUrl }
            }
          }
          rateLimit { remaining resetAt }
        }
        """, variables: variables)
        guard let user = data.user, let source = user.node else {
            throw NetworkError.clientError(statusCode: 404, message: String.l10n("followGraph.status.unavailable"))
        }
        let connection = user.following
        // 缺失用户身份不能被当成完整分页，否则下次刷新可能错误删除旧边。
        let nodes = connection.nodes.compactMap { $0?.node }
        guard nodes.count == connection.nodes.count,
              !connection.pageInfo.hasNextPage || connection.pageInfo.endCursor != nil else {
            throw NetworkError.clientError(statusCode: 502, message: String.l10n("followGraph.status.unavailable"))
        }
        return .init(source: source, nodes: nodes, cursor: connection.pageInfo.endCursor,
                     hasNextPage: connection.pageInfo.hasNextPage, totalCount: connection.totalCount,
                     remaining: data.rateLimit.remaining, resetAt: data.rateLimit.resetAt)
    }

    private struct Response: Decodable {
        let user: User?
        let rateLimit: Quota
    }
    private struct Quota: Decodable { let remaining: Int; let resetAt: String }
    private struct User: Decodable {
        let databaseId: Int64?
        let login: String
        let name: String?
        let avatarUrl: String?
        let following: Connection
        var node: FollowGraphNode? {
            databaseId.map { .init(id: String($0), login: login, name: name, avatarURL: avatarUrl) }
        }
    }
    private struct Person: Decodable {
        let databaseId: Int64?
        let login: String
        let name: String?
        let avatarUrl: String?
        var node: FollowGraphNode? {
            databaseId.map { .init(id: String($0), login: login, name: name, avatarURL: avatarUrl) }
        }
    }
    private struct Connection: Decodable {
        let totalCount: Int
        let pageInfo: PageInfo
        let nodes: [Person?]
    }
    private struct PageInfo: Decodable { let endCursor: String?; let hasNextPage: Bool }
}
