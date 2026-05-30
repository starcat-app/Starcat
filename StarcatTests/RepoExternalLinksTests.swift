//
//  RepoExternalLinksTests.swift
//  StarcatTests
//
//  RepoExternalLinks URL 构造单测（W4 Batch B3）。
//

import Testing
import Foundation
@testable import Starcat

@Suite("RepoExternalLinks")
struct RepoExternalLinksTests {

    /// 复用主代码的 Repo 模型构造一个最小 fixture。
    private func makeRepo(
        owner: String = "swiftlang",
        name: String = "swift",
        htmlUrl: String = "https://github.com/swiftlang/swift",
        homepage: String? = nil
    ) -> Repo {
        Repo(
            id: 1,
            owner: owner,
            name: name,
            fullName: "\(owner)/\(name)",
            description: nil,
            language: nil,
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: homepage,
            htmlUrl: htmlUrl,
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    @Test("repo: 从 htmlUrl 直接构造")
    func repoFromHtmlUrl() {
        let r = makeRepo()
        #expect(RepoExternalLinks.repo(r)?.absoluteString == "https://github.com/swiftlang/swift")
    }

    @Test("issues / pulls / releases 通过 owner+name 拼接")
    func subPagesUseOwnerName() {
        let r = makeRepo(owner: "owner", name: "repo")
        #expect(RepoExternalLinks.issues(r)?.absoluteString == "https://github.com/owner/repo/issues")
        #expect(RepoExternalLinks.pulls(r)?.absoluteString == "https://github.com/owner/repo/pulls")
        #expect(RepoExternalLinks.releases(r)?.absoluteString == "https://github.com/owner/repo/releases")
    }

    @Test("homepage: 缺失 / 空字符串 → nil")
    func homepageMissing() {
        #expect(RepoExternalLinks.homepage(makeRepo(homepage: nil)) == nil)
        #expect(RepoExternalLinks.homepage(makeRepo(homepage: "")) == nil)
        #expect(RepoExternalLinks.homepage(makeRepo(homepage: "   ")) == nil)
    }

    @Test("homepage: 必须 http(s) scheme，避免本地路径或自定义 URL scheme")
    func homepageRequiresHttpScheme() {
        #expect(RepoExternalLinks.homepage(makeRepo(homepage: "example.com")) == nil)
        #expect(RepoExternalLinks.homepage(makeRepo(homepage: "ftp://example.com")) == nil)
        #expect(RepoExternalLinks.homepage(makeRepo(homepage: "javascript:alert(1)")) == nil)
    }

    @Test("homepage: 合法 http / https → URL")
    func homepageValid() {
        #expect(RepoExternalLinks.homepage(makeRepo(homepage: "https://swift.org"))?.absoluteString == "https://swift.org")
        #expect(RepoExternalLinks.homepage(makeRepo(homepage: "http://swift.org"))?.absoluteString == "http://swift.org")
    }
}
