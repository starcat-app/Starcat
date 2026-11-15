//
//  ProfileExtrasAPI.swift
//  Starcat
//
//  账户资料浮层的只读数据源：公开成就 HTML、完整组织列表、官方 GitHub Sponsors GraphQL。
//

import Foundation

extension GitHubAPIClient: GitHubProfileExtrasProviding {
    /// 成就网页使用独立匿名 session，OAuth Token 只发送给 GitHub API，不发送到 HTML 入口。
    func getProfileAchievements(login: String, forceRefresh: Bool) async throws -> [GitHubAchievement] {
        try await GitHubAchievementsClient.fetch(login: login, forceRefresh: forceRefresh)
    }

    /// `/user/orgs` 能包含非公开成员关系；再合并公开列表，避免第三方应用限制隐藏公开组织。
    func getProfileOrganizations(login: String, forceRefresh: Bool) async throws -> GitHubProfileOrganizations {
        var publicOrganizations: [GitHubOrganizationDTO]?
        do {
            publicOrganizations = try await getUserOrganizations(login: login, forceRefresh: forceRefresh)
        } catch {
            try Task.checkCancellation()
        }
        var authorized: [GitHubOrganizationDTO] = []
        var accessLimited = publicOrganizations == nil
        var page = 1
        do {
            while true {
                try Task.checkCancellation()
                let response: APIResponse<[GitHubOrganizationDTO]> = try await get(
                    path: AppEndpoints.GitHubREST.Paths.currentUserOrganizations,
                    queryItems: [
                        URLQueryItem(name: "page", value: String(page)),
                        URLQueryItem(name: "per_page", value: "100")
                    ],
                    cachePolicy: forceRefresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
                )
                authorized.append(contentsOf: response.value)
                accessLimited = accessLimited || response.githubSSO?.contains("partial-results") == true
                guard let nextPage = response.linkHeader.nextPage else { break }
                page = nextPage
            }
        } catch {
            try Task.checkCancellation()
            guard publicOrganizations != nil else { throw error }
            // 分页中途失败不把前几页伪装成全部授权组织；公开列表仍然可用。
            authorized = []
            accessLimited = true
        }
        if authorized.isEmpty && !(publicOrganizations ?? []).isEmpty {
            // Fine-grained PAT 可能成功返回空数组，不能因此声称成员关系已完整取得。
            accessLimited = true
        }
        var seen: Set<Int64> = []
        // 显式合并两份结果；不能靠组织名称去重，组织改名后 ID 仍稳定。
        let organizations = ((publicOrganizations ?? []) + authorized).filter { seen.insert($0.id).inserted }
        return GitHubProfileOrganizations(organizations: organizations, accessLimited: accessLimited)
    }

    /// 两个连接各自走 cursor 分页，保留 User / Organization 两类 Sponsor。
    func getProfileSponsors() async throws -> GitHubSponsors {
        let sponsors = try await sponsorConnection(field: "sponsors")
        let sponsoring = try await sponsorConnection(field: "sponsoring")
        return GitHubSponsors(
            hasSponsorsListing: sponsors.hasSponsorsListing,
            sponsors: sponsors.accounts, sponsoring: sponsoring.accounts
        )
    }

    private func sponsorConnection(field: String) async throws -> (hasSponsorsListing: Bool, accounts: [GitHubSponsor]) {
        var cursor: String?
        var accounts: [GitHubSponsor] = []
        var seen: Set<String> = []
        var hasSponsorsListing = false
        repeat {
            try Task.checkCancellation()
            let payload = try await graphql(
                query: """
                query StarcatProfileSponsors($after: String) {
                  viewer {
                    hasSponsorsListing
                    accounts: \(field)(first: 100, after: $after) {
                      nodes {
                        ... on User { id login avatarUrl }
                        ... on Organization { id login avatarUrl }
                      }
                      pageInfo { hasNextPage endCursor }
                    }
                  }
                }
                """,
                variables: cursor.map { ["after": $0] } ?? [:],
                as: ProfileSponsorsPayload.self
            )
            hasSponsorsListing = payload.viewer.hasSponsorsListing
            accounts.append(contentsOf: payload.viewer.accounts.nodes.compactMap { $0 }.filter { seen.insert($0.id).inserted })
            let page = payload.viewer.accounts.pageInfo
            if page.hasNextPage {
                guard let next = page.endCursor, next != cursor else { throw NetworkError.invalidResponse }
                cursor = next
            } else {
                cursor = nil
            }
        } while cursor != nil
        return (hasSponsorsListing, accounts)
    }
}

/// 匿名网页抓取与 API 客户端分开，测试可以注入 session 而不读取 Keychain。
enum GitHubAchievementsClient {
    /// 勋章只读取公开页面，不携带共享会话的 Cookie；资料缓存统一由 ProfileExtrasService 管理。
    static let anonymousSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    static func fetch(
        login: String, forceRefresh: Bool, session: URLSession = anonymousSession
    ) async throws -> [GitHubAchievement] {
        var components = URLComponents(url: GitHubURLs.userProfile(login: login), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "tab", value: "achievements")]
        guard let url = components.url else { throw NetworkError.invalidResponse }
        var request = URLRequest(
            url: url,
            cachePolicy: forceRefresh ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
            timeoutInterval: 20
        )
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw NetworkError.invalidResponse
        }
        return try GitHubAchievementsParser.parse(html)
    }
}

private struct ProfileSponsorsPayload: Decodable {
    let viewer: Viewer

    struct Viewer: Decodable {
        let hasSponsorsListing: Bool
        let accounts: Connection
    }

    struct Connection: Decodable {
        let nodes: [GitHubSponsor?]
        let pageInfo: PageInfo
    }

    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
}
