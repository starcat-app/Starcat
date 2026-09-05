//
//  OwnerCardSocialLinksTests.swift
//  StarcatTests
//
//  覆盖 Owner 卡片外链合并、X 兼容兜底、URL 去重与 Social accounts 缓存。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Owner 卡片社交链接")
struct OwnerCardSocialLinksTests {

    @Test("Social accounts 提供 X 与 Telegram 时保留顺序且不重复 X 兜底")
    func socialAccountsWinOverTwitterFallback() throws {
        let profile = makeUser(blog: "", twitterUsername: "AdrianPunk115")
        let links = OwnerCardExternalLink.make(
            profile: profile,
            socialAccounts: [
                .init(provider: "twitter", url: "https://x.com/AdrianPunk115"),
                .init(provider: "generic", url: "https://web.telegram.org/k/"),
            ]
        )

        #expect(links.map(\.kind) == [.x, .generic])
        #expect(links.map(\.url.absoluteString) == [
            "https://x.com/AdrianPunk115",
            "https://web.telegram.org/k/",
        ])
    }

    @Test("Social accounts 缺失时用 twitter_username 生成 X 入口")
    func twitterUsernameProvidesFallback() throws {
        let links = OwnerCardExternalLink.make(
            profile: makeUser(blog: nil, twitterUsername: "@dong4j"),
            socialAccounts: []
        )

        #expect(links.map(\.kind) == [.x])
        #expect(links.first?.url.absoluteString == "https://x.com/dong4j")
    }

    @Test("网站与 Social accounts 重复时只保留一次，并丢弃非网页 URL")
    func duplicateAndUnsafeLinksAreFiltered() throws {
        let links = OwnerCardExternalLink.make(
            profile: makeUser(blog: "example.com", twitterUsername: nil),
            socialAccounts: [
                .init(provider: "generic", url: "https://example.com/"),
                .init(provider: "generic", url: "javascript:alert(1)"),
            ]
        )

        #expect(links.count == 1)
        #expect(links.first?.kind == .website)
        #expect(links.first?.url.absoluteString == "https://example.com")
    }

    @MainActor
    @Test("公开 Social accounts 按不区分大小写的 login 缓存")
    func socialAccountsUseCaseInsensitiveCache() async throws {
        let mock = MockGitHubAPIClient()
        var requestedLogins: [String] = []
        mock.getUserSocialAccountsHandler = { login in
            requestedLogins.append(login)
            return [.init(provider: "generic", url: "https://example.com")]
        }
        let service = OwnerFollowService(apiClient: mock)

        _ = try await service.socialAccounts(login: "AdrianPunk")
        _ = try await service.socialAccounts(login: "adrianpunk")

        #expect(requestedLogins == ["AdrianPunk"])
    }

    /// 构造只关注主页外链字段的最小用户数据。
    private func makeUser(blog: String?, twitterUsername: String?) -> GitHubUserDTO {
        GitHubUserDTO(
            id: 1,
            login: "adrianpunk",
            name: "Punk",
            avatarUrl: nil,
            blog: blog,
            twitterUsername: twitterUsername
        )
    }
}
