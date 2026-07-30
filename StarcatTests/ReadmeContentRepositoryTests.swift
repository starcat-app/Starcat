//
//  ReadmeContentRepositoryTests.swift
//  StarcatTests
//
//  HOM-201 P2-2(2026-06-14):readmes.content 拆到独立表 readme_contents 后,
//  验证 `ReadmeRepository.findContent` / `upsertContent` 的读写 + 与 readmes 表完全
//  隔离的边界(读 readme_contents 不引发 readmes 行变更)。
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("ReadmeRepository — readme_contents 路径(P2-2)")
struct ReadmeContentRepositoryTests {

    private func makeRepoAndDb() async throws -> (ReadmeRepository, any DatabaseManaging, Int64) {
        let db = try InMemoryDatabaseManager()
        let repo = ReadmeRepository(database: db)
        let repoId: Int64 = 7

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
                    ?, 'a', 'b', 'a/b', 'd', 'Swift', 0, 0, 0, '[]', NULL,
                    NULL, 'https://github.com/a/b', NULL, NULL,
                    0, 0, 0, 1, NULL, NULL, NULL, NULL, '2026-05-30T00:00:00Z'
                )
                """,
                arguments: [repoId]
            )
        }
        return (repo, db, repoId)
    }

    @Test("findContent 未命中返回 nil")
    func findContentMiss() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        let result = try await repo.findContent(repoId: repoId)
        #expect(result == nil)
    }

    @Test("upsertContent 后 findContent 取回原文 + size 写入明文字节")
    func upsertAndFindContent() async throws {
        let (repo, db, repoId) = try await makeRepoAndDb()
        let markdown = "# Title\n\n这是中文 raw markdown 🚀\n\n- bullet 1\n- bullet 2"

        try await repo.upsertContent(repoId: repoId, content: markdown, at: Date())

        let fetched = try await repo.findContent(repoId: repoId)
        #expect(fetched == markdown)

        // size 列写入明文字节数(LRU 决策口径稳定)
        let size: Int? = try await db.writer.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT size FROM readme_contents WHERE repo_id = ?",
                arguments: [repoId]
            )
        }
        #expect(size == markdown.utf8.count)
    }

    @Test("upsertContent 同 repoId 覆盖")
    func upsertContentOverwrites() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        try await repo.upsertContent(repoId: repoId, content: "v1", at: Date())
        try await repo.upsertContent(repoId: repoId, content: "v2", at: Date())

        let fetched = try await repo.findContent(repoId: repoId)
        #expect(fetched == "v2")
    }

    @Test("upsertContent 仅在正文变化时发送 RAG 刷新事件")
    func contentChangeNotificationIsDiffAware() async throws {
        let (baseRepository, db, repoId) = try await makeRepoAndDb()
        _ = baseRepository
        let center = NotificationCenter()
        let repository = ReadmeRepository(database: db, notificationCenter: center)
        let recorder = ReadmeChangeNotificationRecorder()
        let token = center.addObserver(forName: .readmeContentDidChange, object: nil, queue: nil) { notification in
            recorder.record(repoID: notification.userInfo?["repoId"] as? Int64)
        }
        defer { center.removeObserver(token) }

        try await repository.upsertContent(repoId: repoId, content: "v1", at: Date())
        try await repository.upsertContent(repoId: repoId, content: "v1", at: Date().addingTimeInterval(1))
        try await repository.upsertContent(repoId: repoId, content: "v2", at: Date().addingTimeInterval(2))

        let recorded = recorder.snapshot
        #expect(recorded.count == 2)
        #expect(recorded.repoID == repoId)
    }

    @Test("readme_contents 列存压缩 BLOB(磁盘不是明文)")
    func contentStoredAsCompressedBlob() async throws {
        let (repo, db, repoId) = try await makeRepoAndDb()
        // 重复字符 → zlib 压缩比应该很高
        let markdown = String(repeating: "# Section\nrepeated paragraph.\n\n", count: 200)
        try await repo.upsertContent(repoId: repoId, content: markdown, at: Date())

        let blobBytes: Int = try await db.writer.read { db in
            let data = try Data.fetchOne(
                db,
                sql: "SELECT content FROM readme_contents WHERE repo_id = ?",
                arguments: [repoId]
            )
            return data?.count ?? 0
        }
        #expect(blobBytes > 0)
        #expect(blobBytes < markdown.utf8.count / 3,
                "重复结构 zlib 压缩比应至少 3x,实际 \(blobBytes) vs 明文 \(markdown.utf8.count)")
    }

    @Test("拆表隔离:upsert html 不影响 readme_contents")
    func htmlUpsertDoesNotTouchContents() async throws {
        let (repo, db, repoId) = try await makeRepoAndDb()
        // 先写 markdown
        try await repo.upsertContent(repoId: repoId, content: "raw markdown", at: Date())
        // 再写 html(走 readmes 表)
        try await repo.upsert(Readme(
            repoId: repoId,
            renderedHtml: "<h1>html</h1>",
            etag: nil,
            lastModified: nil,
            cachedAt: "2026-06-14T00:00:00Z",
            size: 13
        ))

        // markdown 应仍在 readme_contents
        let markdown = try await repo.findContent(repoId: repoId)
        #expect(markdown == "raw markdown")
        // html 行也在 readmes
        let html = try await repo.find(repoId: repoId)
        #expect(html?.renderedHtml == "<h1>html</h1>")
        // readmes 表行不再带 content 列(P2-2 已删)
        let columnExists: Int = try await db.writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM pragma_table_info('readmes') WHERE name = 'content'
                """
            ) ?? 0
        }
        #expect(columnExists == 0, "readmes.content 列应在 P2-2 后删除")
    }

    @Test("拆表隔离:delete readme 不影响 markdown(独立 cascade 来自 repos)")
    func deletingReadmeKeepsContent() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        try await repo.upsertContent(repoId: repoId, content: "raw md", at: Date())
        try await repo.upsert(Readme(
            repoId: repoId,
            renderedHtml: "<h1>x</h1>",
            etag: nil,
            lastModified: nil,
            cachedAt: "2026-06-14T00:00:00Z",
            size: 12
        ))

        // 删 readmes 行(用户主动清 / cache cleaner)
        try await repo.delete(repoId: repoId)

        // markdown 仍在 readme_contents
        let markdown = try await repo.findContent(repoId: repoId)
        #expect(markdown == "raw md",
                "readme_contents 直接绑 repos FK,不应被 readmes 删除连带清掉")
    }

    @Test("Private 缓存清理不影响 Public README 或项目数据")
    func clearPrivateRemoteCachesIsSelective() async throws {
        let (repository, database, privateRepoID) = try await makeRepoAndDb()
        let publicRepoID: Int64 = 8
        try await database.writer.write { db in
            try db.execute(
                sql: "UPDATE repos SET is_private = 1 WHERE id = ?",
                arguments: [privateRepoID]
            )
            try db.execute(
                sql: """
                    INSERT INTO repos (
                        id, owner, name, full_name, stars_count, forks_count, watchers_count,
                        html_url, is_private, is_fork, is_archived, is_starred
                    ) VALUES (?, 'public', 'repo', 'public/repo', 0, 0, 0,
                              'https://github.com/public/repo', 0, 0, 0, 0)
                    """,
                arguments: [publicRepoID]
            )
        }
        try await repository.upsert(Readme(
            repoId: privateRepoID,
            renderedHtml: "<p>private</p>",
            etag: nil,
            lastModified: nil,
            cachedAt: "2026-07-29T00:00:00Z",
            size: 14
        ))
        try await repository.upsertContent(
            repoId: privateRepoID,
            content: "private markdown",
            at: Date()
        )
        try await repository.upsert(Readme(
            repoId: publicRepoID,
            renderedHtml: "<p>public</p>",
            etag: nil,
            lastModified: nil,
            cachedAt: "2026-07-29T00:00:00Z",
            size: 13
        ))

        let deleted = try await repository.deletePrivateRemoteCaches()

        #expect(deleted == 1)
        #expect(try await repository.find(repoId: privateRepoID) == nil)
        #expect(try await repository.findContent(repoId: privateRepoID) == nil)
        #expect(try await repository.find(repoId: publicRepoID)?.renderedHtml == "<p>public</p>")
        try await database.writer.read { db in
            let repoCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM repos")
            #expect(repoCount == 2)
        }
    }
}

/// Notification 回调没有 actor 隔离，测试状态必须显式加锁；直接捕获并修改局部变量在
/// Swift 6 下既有数据竞争风险，也会产生并发诊断警告。
private final class ReadmeChangeNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var repoID: Int64?

    var snapshot: (count: Int, repoID: Int64?) {
        lock.withLock { (count, repoID) }
    }

    func record(repoID: Int64?) {
        lock.withLock {
            count += 1
            self.repoID = repoID
        }
    }
}
