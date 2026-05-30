//
//  ReadmeRepositoryTests.swift
//  StarcatTests
//
//  验证 ReadmeRepository 的基本 CRUD + ETag 字段往返。
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("ReadmeRepository")
struct ReadmeRepositoryTests {

    /// 构造内存库 + 写入一个 repo（满足 readmes.repo_id 外键约束）。
    private func makeRepoAndDb() async throws -> (ReadmeRepository, any DatabaseManaging, Int64) {
        let db = try InMemoryDatabaseManager()
        let readmeRepo = ReadmeRepository(database: db)
        let repoId: Int64 = 42

        // readmes.repo_id 是 repos.id 的外键 → 必须先有 repos 行
        // 列对齐 DatabaseMigrationsV1.createRepos（status 字段在 repo_notes 表，不在 repos）
        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (
                    id, owner, name, full_name, description, language,
                    stars_count, forks_count, watchers_count, topics, license,
                    homepage, html_url, clone_url, ssh_url,
                    is_private, is_fork, is_archived, is_starred,
                    pushed_at, created_at, updated_at, starred_at, cached_at
                ) VALUES (
                    ?, 'octo', 'demo', 'octo/demo', 'd', 'Swift',
                    0, 0, 0, '[]', NULL,
                    NULL, 'https://github.com/octo/demo', NULL, NULL,
                    0, 0, 0, 1,
                    NULL, NULL, NULL, NULL, '2026-05-30T00:00:00Z'
                )
                """,
                arguments: [repoId]
            )
        }
        return (readmeRepo, db, repoId)
    }

    private func makeReadme(repoId: Int64, html: String, etag: String? = "\"abc123\"") -> Readme {
        Readme(
            repoId: repoId,
            content: nil,
            renderedHtml: html,
            etag: etag,
            lastModified: "Sat, 30 May 2026 09:00:00 GMT",
            cachedAt: "2026-05-30T09:30:00Z",
            size: html.utf8.count
        )
    }

    @Test("find 未命中返回 nil")
    func findMiss() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        let result = try await repo.find(repoId: repoId)
        #expect(result == nil)
    }

    @Test("upsert 后 find 能取回完整字段（含 etag / lastModified / size）")
    func upsertAndFind() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        let readme = makeReadme(repoId: repoId, html: "<h1>hi</h1>")

        try await repo.upsert(readme)
        let fetched = try await repo.find(repoId: repoId)

        #expect(fetched != nil)
        #expect(fetched?.renderedHtml == "<h1>hi</h1>")
        #expect(fetched?.etag == "\"abc123\"")
        #expect(fetched?.lastModified == "Sat, 30 May 2026 09:00:00 GMT")
        #expect(fetched?.size == 11)
    }

    @Test("再次 upsert 同 repoId 应覆盖（不报主键冲突）")
    func upsertOverwrites() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        try await repo.upsert(makeReadme(repoId: repoId, html: "v1", etag: "\"e1\""))
        try await repo.upsert(makeReadme(repoId: repoId, html: "v2", etag: "\"e2\""))

        let fetched = try await repo.find(repoId: repoId)
        #expect(fetched?.renderedHtml == "v2")
        #expect(fetched?.etag == "\"e2\"")
    }

    @Test("touchCachedAt 只更新 cached_at，不动 html / etag")
    func touchCachedAt() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        // 写入初始 cached_at（"2026-05-30T09:30:00Z" 见 makeReadme）
        try await repo.upsert(makeReadme(repoId: repoId, html: "stable"))

        // 用一个明确的"未来"时间点更新；与 ISO8601DateFormatter.shared 的精度无关，
        // 仅检查 cached_at 真的变了并且其他字段未动
        let newDate = Date(timeIntervalSince1970: 1_780_000_000) // 约 2026-06-30
        try await repo.touchCachedAt(repoId: repoId, at: newDate)

        let fetched = try await repo.find(repoId: repoId)
        #expect(fetched?.renderedHtml == "stable")
        #expect(fetched?.etag == "\"abc123\"")
        // cached_at 应变为新写入值，原"2026-05-30..."不再保留
        #expect(fetched?.cachedAt.hasPrefix("2026-05-30") == false)
        #expect(fetched?.cachedAt.contains("2026") == true)
    }

    @Test("delete 后再 find 返回 nil")
    func deleteThenFind() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        try await repo.upsert(makeReadme(repoId: repoId, html: "x"))

        try await repo.delete(repoId: repoId)
        let fetched = try await repo.find(repoId: repoId)
        #expect(fetched == nil)
    }

    // MARK: - W4-4 D4 缓存统计

    @Test("D4: countAll / totalBytes / deleteAll 联动")
    func cacheStatsAndDeleteAll() async throws {
        let (repo, db, _) = try await makeRepoAndDb()
        // 先插另外两条 repo 给 readmes 用
        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url, cached_at)
                VALUES (?, 'o', ?, ?, ?, '2026-05-30T00:00:00Z')
                """,
                arguments: [100, "r100", "o/r100", "https://github.com/o/r100"]
            )
            try db.execute(
                sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url, cached_at)
                VALUES (?, 'o', ?, ?, ?, '2026-05-30T00:00:00Z')
                """,
                arguments: [101, "r101", "o/r101", "https://github.com/o/r101"]
            )
        }
        try await repo.upsert(makeReadme(repoId: 42,  html: "aaa"))
        try await repo.upsert(makeReadme(repoId: 100, html: "bbbb"))
        try await repo.upsert(makeReadme(repoId: 101, html: "ccccc"))

        #expect(try await repo.countAll() == 3)
        #expect(try await repo.totalBytes() == 12, "3+4+5 = 12 bytes")

        try await repo.deleteAll()

        #expect(try await repo.countAll() == 0)
        #expect(try await repo.totalBytes() == 0)
    }
}

// MARK: - W4-4 D4：CacheCleaner

@MainActor
@Suite("CacheCleaner (D4)")
struct CacheCleanerTests {

    /// Kingfisher 部分(图片缓存)不纳入测试 — 它有自己的磁盘 I/O,
    /// 会污染测试主机的 Kingfisher 默认 disk cache。这里只覆盖 README 路径。
    private func makeReadmeRepo() async throws -> (ReadmeRepository, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        let repo = ReadmeRepository(database: db)
        // 插 1 个 repo 满足外键
        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (id, owner, name, full_name, html_url, cached_at)
                VALUES (1, 'o', 'r', 'o/r', 'https://x', '2026-05-30T00:00:00Z')
                """
            )
        }
        return (repo, db)
    }

    private func insertReadme(_ repo: ReadmeRepository, html: String) async throws {
        try await repo.upsert(Readme(
            repoId: 1, content: nil, renderedHtml: html,
            etag: nil, lastModified: nil,
            cachedAt: "2026-05-30T00:00:00Z",
            size: html.utf8.count
        ))
    }

    @Test("loadStatistics 返回 README 计数与字节")
    func loadStatsReturnsReadmeMetrics() async throws {
        let (repo, _) = try await makeReadmeRepo()
        try await insertReadme(repo, html: "hello world")

        let cleaner = CacheCleaner(readmeRepository: repo)
        let stats = await cleaner.loadStatistics()

        #expect(stats.readmeCount == 1)
        #expect(stats.readmeBytes == 11)
    }

    @Test("clearReadmes 后 stats 归零")
    func clearReadmesEmptiesStats() async throws {
        let (repo, _) = try await makeReadmeRepo()
        try await insertReadme(repo, html: "abc")
        let cleaner = CacheCleaner(readmeRepository: repo)

        await cleaner.clearReadmes()
        let stats = await cleaner.loadStatistics()

        #expect(stats.readmeCount == 0)
        #expect(stats.readmeBytes == 0)
    }
}

// MARK: - Int64.formattedByteSize

@Suite("Int64.formattedByteSize (D4)")
struct ByteFormattingTests {
    @Test("0 字节 → '零字节' 风格(系统本地化)")
    func zeroBytes() {
        let s = Int64(0).formattedByteSize
        #expect(!s.isEmpty)
    }
    @Test("1.5 MB 数量级输出非空且含'MB'")
    func megaByte() {
        let s = Int64(1_500_000).formattedByteSize
        #expect(s.contains("MB"))
    }
}
