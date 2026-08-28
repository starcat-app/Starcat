//
//  AwesomeSourceOpenGraphTests.swift
//  StarcatTests
//
//  OG URL 只在客户端拼装：校验 owner/repo 解析、UTC 小时缓存键和缺字段回退。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Awesome Source Open Graph")
struct AwesomeSourceOpenGraphTests {

    @Test("用 repoFullName 和 UTC 小时拼 OG URL")
    func buildsHourlyCacheURL() throws {
        let date = try #require(ISO8601DateFormatter.githubDate(from: "2026-08-24T08:17:00Z"))
        let url = AwesomeSourceOpenGraph.imageURL(
            repoFullName: "vinta/awesome-python",
            updatedAt: date,
            lastSyncedAt: nil
        )

        #expect(url?.absoluteString == "https://opengraph.githubassets.com/2026082408/vinta/awesome-python")
    }

    @Test("同一小时内不同分钟共用缓存键")
    func reusesCacheKeyWithinTheSameHour() throws {
        let first = try #require(ISO8601DateFormatter.githubDate(from: "2026-08-24T08:00:00Z"))
        let last = try #require(ISO8601DateFormatter.githubDate(from: "2026-08-24T08:59:59Z"))

        let firstURL = AwesomeSourceOpenGraph.imageURL(
            repoFullName: "sindresorhus/awesome",
            updatedAt: first,
            lastSyncedAt: nil
        )
        let lastURL = AwesomeSourceOpenGraph.imageURL(
            repoFullName: "sindresorhus/awesome",
            updatedAt: last,
            lastSyncedAt: nil
        )

        #expect(firstURL == lastURL)
        #expect(firstURL?.absoluteString == "https://opengraph.githubassets.com/2026082408/sindresorhus/awesome")
    }

    @Test("没有 updatedAt 时回退 lastSyncedAt，都没有则用 1")
    func fallsBackToLastSyncedThenLiteralOne() throws {
        let synced = try #require(ISO8601DateFormatter.githubDate(from: "2026-08-25T01:04:00Z"))

        let syncedURL = AwesomeSourceOpenGraph.imageURL(
            repoFullName: "avelino/awesome-go",
            updatedAt: nil,
            lastSyncedAt: synced
        )
        let literalURL = AwesomeSourceOpenGraph.imageURL(
            repoFullName: "avelino/awesome-go",
            updatedAt: nil,
            lastSyncedAt: nil
        )

        #expect(syncedURL?.absoluteString == "https://opengraph.githubassets.com/2026082501/avelino/awesome-go")
        #expect(literalURL?.absoluteString == "https://opengraph.githubassets.com/1/avelino/awesome-go")
    }

    @Test("解析不出 owner/repo 时不拼 URL")
    func rejectsMalformedFullName() {
        let names = ["awesome-python", "vinta/", "/awesome-python", "a/b/c", ""]
        for name in names {
            #expect(
                AwesomeSourceOpenGraph.imageURL(
                    repoFullName: name,
                    updatedAt: Date(timeIntervalSince1970: 0),
                    lastSyncedAt: nil
                ) == nil
            )
        }
    }

    @Test("预拉列表覆盖全部合法来源并按 URL 去重")
    func collectsUniqueImageURLsForCatalog() throws {
        let hour = try #require(ISO8601DateFormatter.githubDate(from: "2026-08-25T09:10:00Z"))
        let python = source(repoFullName: "vinta/awesome-python", updatedAt: hour)
        let duplicate = source(id: "python-dup", repoFullName: "vinta/awesome-python", updatedAt: hour)
        let go = source(repoFullName: "avelino/awesome-go", updatedAt: hour)
        let invalid = source(id: "bad", repoFullName: "not-a-repo", updatedAt: hour)

        let urls = AwesomeSourceOpenGraph.imageURLs(for: [python, duplicate, go, invalid])

        #expect(urls.map(\.absoluteString) == [
            "https://opengraph.githubassets.com/2026082509/vinta/awesome-python",
            "https://opengraph.githubassets.com/2026082509/avelino/awesome-go"
        ])
    }

    private func source(
        id: String = "one",
        repoFullName: String,
        updatedAt: Date
    ) -> AwesomeSource {
        AwesomeSource(
            id: id,
            kind: .managed,
            displayName: repoFullName,
            repoFullName: repoFullName,
            repoURL: URL(string: "https://github.com/\(repoFullName)")!,
            repoDescription: nil,
            imageURL: nil,
            summaryZH: nil,
            summaryEN: nil,
            featured: false,
            sortOrder: 0,
            sourceStars: 0,
            sourceForks: 0,
            sourceWatchers: 0,
            sourceSubscribers: 0,
            sourceOpenIssues: 0,
            sourceLanguage: nil,
            languageBytes: [:],
            githubRepoCount: 0,
            externalEntryCount: 0,
            resourceEntryCount: 0,
            isAvailable: true,
            isEnabled: false,
            addedAt: updatedAt,
            lastSyncedAt: nil,
            updatedAt: updatedAt
        )
    }
}
