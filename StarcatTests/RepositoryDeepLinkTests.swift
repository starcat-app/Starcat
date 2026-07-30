//
//  RepositoryDeepLinkTests.swift
//  StarcatTests
//
//  公开仓库链接协议单测：覆盖 URL 生成、Universal Link 解析与恶意路径拒绝。
//

import Foundation
import Testing
@testable import Starcat

@Suite("RepositoryDeepLink")
struct RepositoryDeepLinkTests {

    @Test("生成唯一的 starcat.ink 公开仓库 URL")
    func buildsPublicURL() throws {
        let link = try #require(RepositoryDeepLink(owner: "swiftlang", name: "swift", repositoryID: 44838949))
        #expect(link.publicURL.absoluteString == "https://starcat.ink/r/swiftlang/swift?v=1&rid=44838949")
        #expect(link.appURL.absoluteString == "starcat://repo/swiftlang/swift?v=1&rid=44838949")
    }

    @Test("解析 Universal Link 与内部 custom scheme")
    func parsesSupportedURLs() throws {
        let universal = try #require(URL(string: "https://starcat.ink/r/SwiftLang/Swift?v=1&rid=44838949"))
        let custom = try #require(URL(string: "starcat://repo/SwiftLang/Swift?v=1&rid=44838949"))

        let expected = RepositoryDeepLink(owner: "SwiftLang", name: "Swift", repositoryID: 44838949)
        #expect(RepositoryDeepLink(url: universal) == expected)
        #expect(RepositoryDeepLink(url: custom) == expected)
    }

    @Test("拒绝错误域名、多余路径与非 GitHub 命名字符")
    func rejectsUnsupportedURLs() throws {
        let wrongHost = try #require(URL(string: "https://example.com/r/swiftlang/swift"))
        let extraPath = try #require(URL(string: "https://starcat.ink/r/swiftlang/swift/issues"))
        let encodedSlash = try #require(URL(string: "https://starcat.ink/r/swiftlang/swift%2Fissues"))

        #expect(RepositoryDeepLink(url: wrongHost) == nil)
        #expect(RepositoryDeepLink(url: extraPath) == nil)
        #expect(RepositoryDeepLink(url: encodedSlash) == nil)
        #expect(RepositoryDeepLink(owner: "-invalid", name: "repo") == nil)
        #expect(RepositoryDeepLink(owner: "owner", name: "bad name") == nil)
        #expect(RepositoryDeepLink(owner: "所有者", name: "repo") == nil)
        #expect(RepositoryDeepLink(url: URL(string: "https://starcat.ink/r/owner/repo?v=2&rid=1")!) == nil)
        #expect(RepositoryDeepLink(url: URL(string: "https://starcat.ink/r/owner/repo?v=1&rid=0")!) == nil)
    }

    @Test("fullName 必须严格为 owner/repo 两段")
    func validatesFullName() {
        #expect(RepositoryDeepLink(fullName: "owner/repo") != nil)
        #expect(RepositoryDeepLink(fullName: "owner") == nil)
        #expect(RepositoryDeepLink(fullName: "owner/repo/issues") == nil)
    }

    @Test("生成并解析 Release custom scheme 与受信任 Universal Link")
    func buildsAndParsesReleaseLinks() throws {
        let link = try #require(
            RepositoryReleaseDeepLink(
                owner: "swiftlang",
                name: "swift",
                repositoryID: 44_838_949,
                releaseID: 250_000_001
            )
        )
        #expect(
            link.appURL.absoluteString
                == "starcat://repo/swiftlang/swift/releases?v=1&rid=44838949&release_id=250000001"
        )

        let custom = try #require(RepositoryReleaseDeepLink(url: link.appURL))
        let universalURL = try #require(
            URL(
                string: "https://starcat.ink/r/swiftlang/swift/releases?v=1&rid=44838949&release_id=250000001"
            )
        )
        let universal = try #require(RepositoryReleaseDeepLink(url: universalURL))

        #expect(custom == link)
        #expect(universal == link)
        #expect(RepositoryDeepLink(url: link.appURL) == nil)
    }

    @Test("Release 链接拒绝缺失、非正数、重复参数和非受信任路径")
    func rejectsInvalidReleaseLinks() throws {
        let rawURLs = [
            "starcat://repo/owner/repo/releases?rid=1&release_id=2",
            "starcat://repo/owner/repo/releases?v=2&rid=1&release_id=2",
            "starcat://repo/owner/repo/releases?v=1&rid=0&release_id=2",
            "starcat://repo/owner/repo/releases?v=1&rid=1&release_id=0",
            "starcat://repo/owner/repo/releases?v=1&rid=1&release_id=2&release_id=3",
            "starcat://repo/owner/repo%2Freleases?v=1&rid=1&release_id=2",
            "https://example.com/r/owner/repo/releases?v=1&rid=1&release_id=2",
            "https://starcat.ink/r/owner/repo/releases/extra?v=1&rid=1&release_id=2",
        ]

        for rawURL in rawURLs {
            let url = try #require(URL(string: rawURL))
            #expect(RepositoryReleaseDeepLink(url: url) == nil)
        }

        #expect(
            RepositoryReleaseDeepLink(
                owner: "owner",
                name: "repo",
                repositoryID: -1,
                releaseID: 2
            ) == nil
        )
        #expect(
            RepositoryReleaseDeepLink(
                owner: "owner",
                name: "repo",
                repositoryID: 1,
                releaseID: -2
            ) == nil
        )
    }
}
