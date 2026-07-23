//
//  ReadmeTranslationRepositoryTests.swift
//  StarcatTests
//
//  覆盖 DiskReadmeTranslationCache CRUD + LRU + 损坏兜底（HOM-68 v2 / 2026-06-15）。
//
//  关注点：
//  - `(owner, repo, target_language, mode)` 元组等价 PK：不同语言/模式可并存；
//    同 (owner, repo) 同语言同模式 upsert 覆盖；
//  - delete(owner:repo:targetLanguage:) 只删指定语言记录，其他语言保留；
//  - deleteAll(owner:repo:) 清空该 (owner, repo) 所有语言译文；
//  - deleteEverything() 一次性清空整个磁盘缓存；
//  - 损坏 metadata JSON → find 返 nil + 自动删除损坏对，避免长期占空间；
//  - LRU sweep 按"60 天未访问" 优先删，仍超 50MB 再按 mtime 升序补删；
//  - 写入后 totalBytes / itemCount / latestCreatedAt 三个 Observable 派生量同步更新。
//
//  关键约束：
//  - 每个用例用 `rootOverride: tempDir` 注入隔离目录，绝不污染 production
//    `~/Library/Application Support/com.starcat.app/translations-cache/`；
//  - DiskReadmeTranslationCache 是 `@MainActor`，整个 Suite 标 `@MainActor` 简化签名。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("DiskReadmeTranslationCache")
struct ReadmeTranslationRepositoryTests {

    /// 创建一份隔离的 cache 实例 + 它的临时 root。测试结束后调用方负责删 root。
    private func makeIsolatedCache(file: StaticString = #filePath, line: UInt = #line) throws
        -> (cache: DiskReadmeTranslationCache, root: URL)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-translation-test-\(UUID().uuidString)", isDirectory: true)
        let cache = DiskReadmeTranslationCache(rootOverride: root)
        return (cache, root)
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeTranslation(
        repoId: Int64? = 42,
        lang: String,
        text: String = "已翻译",
        hash: String = "deadbeef",
        model: String = "gpt-4o-mini",
        createdAt: String = "2026-06-15T10:00:00Z"
    ) -> ReadmeTranslation {
        ReadmeTranslation(
            repoId: repoId,
            targetLanguage: lang,
            model: model,
            sourceHash: hash,
            segments: [
                ReadmeTranslatedSegment(sourceHash: "\(hash)-segment", translatedText: text)
            ],
            isComplete: true,
            size: text.utf8.count,
            createdAt: createdAt
        )
    }

    // MARK: - find

    @Test("find 未命中返回 nil")
    func findMiss() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        let result = try await cache.find(owner: "octo", repo: "demo", targetLanguage: "zh-Hans")
        #expect(result == nil)
    }

    @Test("upsert + find 同 (owner,repo,language) 往返")
    func upsertAndFind() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        let record = makeTranslation(lang: "zh-Hans", text: "你好")
        try await cache.upsert(record, owner: "octo", repo: "demo")

        let fetched = try await cache.find(owner: "octo", repo: "demo", targetLanguage: "zh-Hans")
        let expectedText = "你好"
        #expect(fetched?.segments.first?.translatedText == expectedText)
        #expect(fetched?.targetLanguage == "zh-Hans")
        #expect(fetched?.size == expectedText.utf8.count)
        #expect(fetched?.sourceHash == "deadbeef")
        #expect(fetched?.model == "gpt-4o-mini")
        #expect(fetched?.repoId == 42)
    }

    @Test("upsert 后 Observable 派生量 itemCount / totalBytes 同步更新")
    func upsertUpdatesObservableProperties() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        #expect(cache.itemCount == 0)
        #expect(cache.totalBytes == 0)

        try await cache.upsert(makeTranslation(lang: "zh-Hans"), owner: "octo", repo: "demo")
        #expect(cache.itemCount == 1)
        #expect(cache.totalBytes > 0)
    }

    // MARK: - upsert 覆盖语义

    @Test("同 (owner,repo) + 同语言 upsert 覆盖，不抛错")
    func upsertOverwritesSameLanguage() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.upsert(
            makeTranslation(lang: "zh-Hans", text: "v1", hash: "h1"),
            owner: "octo",
            repo: "demo"
        )
        try await cache.upsert(
            makeTranslation(lang: "zh-Hans", text: "v2", hash: "h2"),
            owner: "octo",
            repo: "demo"
        )

        let fetched = try await cache.find(owner: "octo", repo: "demo", targetLanguage: "zh-Hans")
        #expect(fetched?.segments.first?.translatedText == "v2")
        #expect(fetched?.sourceHash == "h2")
        // 仍只有一条
        #expect(cache.itemCount == 1)
    }

    @Test("同 (owner,repo) + 不同语言可以并存")
    func multipleLanguagesCoexist() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.upsert(
            makeTranslation(lang: "zh-Hans", text: "你好"),
            owner: "octo",
            repo: "demo"
        )
        try await cache.upsert(
            makeTranslation(lang: "ja", text: "こんにちは"),
            owner: "octo",
            repo: "demo"
        )

        let zh = try await cache.find(owner: "octo", repo: "demo", targetLanguage: "zh-Hans")
        let ja = try await cache.find(owner: "octo", repo: "demo", targetLanguage: "ja")
        #expect(zh?.segments.first?.translatedText == "你好")
        #expect(ja?.segments.first?.translatedText == "こんにちは")
        #expect(cache.itemCount == 2)
    }

    @Test("同仓库同语言的分段与全文缓存互相隔离")
    func translationModesCoexist() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.upsert(
            makeTranslation(lang: "zh-Hans", text: "分段译文"),
            owner: "octo",
            repo: "demo",
            mode: .segmented
        )
        try await cache.upsert(
            makeTranslation(lang: "zh-Hans", text: "全文译文"),
            owner: "octo",
            repo: "demo",
            mode: .full
        )

        let segmented = try await cache.find(
            owner: "octo",
            repo: "demo",
            targetLanguage: "zh-Hans",
            mode: .segmented
        )
        let full = try await cache.find(
            owner: "octo",
            repo: "demo",
            targetLanguage: "zh-Hans",
            mode: .full
        )

        #expect(segmented?.segments.first?.translatedText == "分段译文")
        #expect(full?.segments.first?.translatedText == "全文译文")
        #expect(cache.itemCount == 2)
    }

    @Test("不同 (owner,repo) 互不干扰")
    func differentReposIsolated() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.upsert(
            makeTranslation(repoId: 1, lang: "zh-Hans", text: "repoA"),
            owner: "octo",
            repo: "demo"
        )
        try await cache.upsert(
            makeTranslation(repoId: 2, lang: "zh-Hans", text: "repoB"),
            owner: "octo",
            repo: "another"
        )

        let a = try await cache.find(owner: "octo", repo: "demo", targetLanguage: "zh-Hans")
        let b = try await cache.find(owner: "octo", repo: "another", targetLanguage: "zh-Hans")
        #expect(a?.segments.first?.translatedText == "repoA")
        #expect(b?.segments.first?.translatedText == "repoB")
    }

    // MARK: - delete / deleteAll / deleteEverything

    @Test("delete(language) 只删指定语言，其他语言保留")
    func deleteOneLanguageKeepsOthers() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.upsert(makeTranslation(lang: "zh-Hans"), owner: "octo", repo: "demo")
        try await cache.upsert(makeTranslation(lang: "ja"), owner: "octo", repo: "demo")

        try await cache.delete(owner: "octo", repo: "demo", targetLanguage: "zh-Hans")

        #expect(try await cache.find(owner: "octo", repo: "demo", targetLanguage: "zh-Hans") == nil)
        #expect(try await cache.find(owner: "octo", repo: "demo", targetLanguage: "ja") != nil)
    }

    @Test("deleteAll(owner,repo) 清空该 repo 全部语言译文")
    func deleteAllLanguages() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.upsert(makeTranslation(lang: "zh-Hans"), owner: "octo", repo: "demo")
        try await cache.upsert(makeTranslation(lang: "en"), owner: "octo", repo: "demo")
        try await cache.upsert(makeTranslation(lang: "ja"), owner: "octo", repo: "demo")
        // 不同 repo 不应被清掉
        try await cache.upsert(makeTranslation(lang: "zh-Hans"), owner: "other", repo: "keep")

        try await cache.deleteAll(owner: "octo", repo: "demo")

        #expect(try await cache.find(owner: "octo", repo: "demo", targetLanguage: "zh-Hans") == nil)
        #expect(try await cache.find(owner: "octo", repo: "demo", targetLanguage: "en") == nil)
        #expect(try await cache.find(owner: "octo", repo: "demo", targetLanguage: "ja") == nil)
        #expect(try await cache.find(owner: "other", repo: "keep", targetLanguage: "zh-Hans") != nil)
    }

    @Test("deleteEverything() 清空整个翻译缓存")
    func deleteEverythingWipesAll() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.upsert(makeTranslation(lang: "zh-Hans"), owner: "octo", repo: "a")
        try await cache.upsert(makeTranslation(lang: "ja"), owner: "octo", repo: "b")
        try await cache.upsert(makeTranslation(lang: "en"), owner: "other", repo: "c")

        try await cache.deleteEverything()

        #expect(cache.itemCount == 0)
        #expect(cache.totalBytes == 0)
        #expect(cache.latestCreatedAt == nil)
        #expect(try await cache.find(owner: "octo", repo: "a", targetLanguage: "zh-Hans") == nil)
    }

    // MARK: - 损坏 metadata 兜底

    @Test("metadata JSON 损坏 → find 返 nil 且自动删除损坏对")
    func corruptedMetadataIsRemoved() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.upsert(
            makeTranslation(lang: "zh-Hans", text: "hi"),
            owner: "octo",
            repo: "demo"
        )

        // 手工损坏 metadata 文件（写入非 JSON 内容模拟磁盘 corruption）
        let metadataURL = root
            .appendingPathComponent("octo", isDirectory: true)
            .appendingPathComponent("demo", isDirectory: true)
            .appendingPathComponent("zh-Hans.json")
        try Data("not-a-valid-json".utf8).write(to: metadataURL, options: .atomic)

        let result = try await cache.find(owner: "octo", repo: "demo", targetLanguage: "zh-Hans")
        #expect(result == nil)

        // find 命中损坏后应该已经删了这对文件
        let stillExists = FileManager.default.fileExists(atPath: metadataURL.path)
        #expect(stillExists == false)
    }

    @Test("初始化时一次性删除旧整页 HTML 缓存，不保留双轨文件")
    func legacyHTMLCacheIsRemovedOnInitialization() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-translation-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { cleanup(root) }
        let directory = root
            .appendingPathComponent("octo", isDirectory: true)
            .appendingPathComponent("demo", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = directory.appendingPathComponent("zh-Hans.json")
        let html = directory.appendingPathComponent("zh-Hans.html")
        try Data(#"{"source_hash":"old","translated_html":"legacy"}"#.utf8)
            .write(to: metadata, options: .atomic)
        try Data("<p>旧译文</p>".utf8).write(to: html, options: .atomic)

        let cache = DiskReadmeTranslationCache(rootOverride: root)

        #expect(cache.itemCount == 0)
        #expect(!FileManager.default.fileExists(atPath: metadata.path))
        #expect(!FileManager.default.fileExists(atPath: html.path))
    }

    // MARK: - LRU sweep

    @Test("LRU sweep：60 天未访问条目被删")
    func lruSweepRemovesAged() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.upsert(makeTranslation(lang: "zh-Hans"), owner: "octo", repo: "aged")
        try await cache.upsert(makeTranslation(lang: "zh-Hans"), owner: "octo", repo: "fresh")

        // 把 aged 的 metadata mtime 调到 90 天前
        let agedMetadata = root
            .appendingPathComponent("octo", isDirectory: true)
            .appendingPathComponent("aged", isDirectory: true)
            .appendingPathComponent("zh-Hans.json")
        let oldDate = Date(timeIntervalSinceNow: -90 * 24 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: agedMetadata.path
        )

        try cache.lruSweep()

        #expect(try await cache.find(owner: "octo", repo: "aged", targetLanguage: "zh-Hans") == nil)
        #expect(try await cache.find(owner: "octo", repo: "fresh", targetLanguage: "zh-Hans") != nil)
    }

    @Test("reload() 不删任何文件，纯刷新派生量")
    func reloadIsReadonly() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        try await cache.upsert(makeTranslation(lang: "zh-Hans"), owner: "octo", repo: "demo")
        let beforeCount = cache.itemCount

        cache.reload()
        cache.reload()

        #expect(cache.itemCount == beforeCount)
        #expect(try await cache.find(owner: "octo", repo: "demo", targetLanguage: "zh-Hans") != nil)
    }

    // MARK: - 路径防护

    @Test("路径含非法字符 → 抛 invalidPathComponent")
    func invalidPathComponentRejected() async throws {
        let (cache, root) = try makeIsolatedCache()
        defer { cleanup(root) }
        await #expect(throws: DiskReadmeTranslationCacheError.self) {
            try await cache.find(owner: "octo", repo: "../escape", targetLanguage: "zh-Hans")
        }
    }
}
