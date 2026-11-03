//
//  DiskIssueSummaryCacheTests.swift
//  StarcatTests
//
//  Issue 总结文件缓存：落盘回读、损坏删除、语言隔离、路径推导边界。
//  每个用例用临时目录，不碰生产 Application Support。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("DiskIssueSummaryCache")
struct DiskIssueSummaryCacheTests {

    private func makeIsolatedCache() -> (cache: DiskIssueSummaryCache, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-issue-summary-test-\(UUID().uuidString)", isDirectory: true)
        return (DiskIssueSummaryCache(rootOverride: root), root)
    }

    private func makePayload(
        number: Int? = 166,
        repo: String = "starcat-app/Starcat"
    ) -> ActivityNotificationPayload {
        ActivityNotificationPayload(
            threadId: "166", reason: "mention", chip: .mention, subjectType: "Issue", subjectNumber: number,
            repositoryFullName: repo, actorLogin: "reader", authorLogin: "author",
            authorCreatedAt: nil, excerpt: "Opening post", comments: [], people: []
        )
    }

    private func makeContext() -> GitHubNotificationIssueSummary.Context {
        GitHubNotificationIssueSummary.Context(
            text: "prompt 不落盘",
            includedCommentCount: 4,
            availableCommentCount: 6,
            includedEventCount: 2,
            availableEventCount: 2,
            isTruncated: false
        )
    }

    private func summaryFile(root: URL, languageSlug: String, number: Int = 166) -> URL {
        root
            .appendingPathComponent("starcat-app", isDirectory: true)
            .appendingPathComponent("Starcat", isDirectory: true)
            .appendingPathComponent(languageSlug, isDirectory: true)
            .appendingPathComponent("\(number).json")
    }

    private func jsonFileCount(under root: URL) -> Int {
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return children.reduce(0) { count, child in
            child.hasDirectoryPath ? count + jsonFileCount(under: child) : count + (child.pathExtension == "json" ? 1 : 0)
        }
    }

    @Test("save 后按同一 payload + 语言拿回同一份快照")
    func roundTrip() {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = makePayload()
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        cache.save(
            title: "Issue", payload: payload, timeline: [], language: "English",
            context: makeContext(), markdown: "总结正文", generatedAt: generatedAt
        )
        let loaded = cache.load(payload: payload, language: "English")
        #expect(loaded?.markdown == "总结正文")
        #expect(loaded?.generatedAt == generatedAt)
        #expect(loaded?.language == "English")
        #expect(loaded?.payload == payload)
        #expect(loaded?.contextStats.includedCommentCount == 4)
        #expect(loaded?.contextStats.isTruncated == false)
    }

    @Test("语言不同按 miss 处理且不删文件")
    func languageMismatchIsMissWithoutRemoval() {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.save(
            title: "Issue", payload: makePayload(), timeline: [], language: "English",
            context: makeContext(), markdown: "总结正文", generatedAt: Date()
        )
        #expect(cache.load(payload: makePayload(), language: "Simplified Chinese") == nil)
        #expect(FileManager.default.fileExists(atPath: summaryFile(root: root, languageSlug: "English").path))
    }

    @Test("损坏 JSON 会删文件并 miss")
    func corruptFileIsRemoved() {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.save(
            title: "Issue", payload: makePayload(), timeline: [], language: "English",
            context: makeContext(), markdown: "总结正文", generatedAt: Date()
        )
        let file = summaryFile(root: root, languageSlug: "English")
        try? Data("not-json".utf8).write(to: file)
        #expect(cache.load(payload: makePayload(), language: "English") == nil)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test("缺 number 或仓库全名畸形时静默旁路，不产生文件")
    func bypassWithoutUsableKey() {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.save(
            title: "Issue", payload: makePayload(number: nil), timeline: [], language: "English",
            context: makeContext(), markdown: "总结正文", generatedAt: Date()
        )
        cache.save(
            title: "Issue", payload: makePayload(repo: "no-slash"), timeline: [], language: "English",
            context: makeContext(), markdown: "总结正文", generatedAt: Date()
        )
        #expect(cache.load(payload: makePayload(number: nil), language: "English") == nil)
        #expect(cache.load(payload: makePayload(repo: "no-slash"), language: "English") == nil)
        #expect(jsonFileCount(under: root) == 0)
    }

    @Test("空正文不落盘，避免恢复出一个空总结")
    func emptyMarkdownIsNotPersisted() {
        let (cache, root) = makeIsolatedCache()
        defer { try? FileManager.default.removeItem(at: root) }
        cache.save(
            title: "Issue", payload: makePayload(), timeline: [], language: "English",
            context: makeContext(), markdown: "   \n  ", generatedAt: Date()
        )
        #expect(cache.load(payload: makePayload(), language: "English") == nil)
        #expect(jsonFileCount(under: root) == 0)
    }

    @Test("languageSlug 只保留字母数字与单连字符")
    func slugSanitization() {
        #expect(DiskIssueSummaryCache.languageSlug("Simplified Chinese") == "Simplified-Chinese")
        #expect(DiskIssueSummaryCache.languageSlug("English") == "English")
        #expect(DiskIssueSummaryCache.languageSlug("..//..") == "default")
        #expect(DiskIssueSummaryCache.languageSlug("a  b") == "a-b")
    }
}
