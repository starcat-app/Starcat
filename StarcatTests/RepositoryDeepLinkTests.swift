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
}
