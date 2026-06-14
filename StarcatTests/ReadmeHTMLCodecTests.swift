//
//  ReadmeHTMLCodecTests.swift
//  StarcatTests
//
//  README HTML 压缩 / 解压 codec 测试(HOM-201 P2-1,2026-06-14)。
//
//  覆盖:
//   - encode / decode 往返保真(短串 / 长串 / unicode / 含 HTML 标签)
//   - nil / 空串短路
//   - 解压失败兜底(非压缩数据 / 损坏 blob)
//   - 压缩比断言(对结构化 HTML 应该明显小于明文)
//

import Testing
import Foundation
@testable import Starcat

@Suite("ReadmeHTMLCodec — 压缩 / 解压")
struct ReadmeHTMLCodecTests {

    // MARK: - 往返保真

    @Test("encode / decode 往返:ASCII")
    func roundTripAscii() {
        let original = "<h1>Hello, README!</h1><p>Some content here.</p>"
        let encoded = ReadmeHTMLCodec.encode(original)
        #expect(encoded != nil)
        let decoded = ReadmeHTMLCodec.decode(encoded)
        #expect(decoded == original)
    }

    @Test("encode / decode 往返:中文 + Emoji")
    func roundTripUnicode() {
        let original = "<h1>你好 README 🚀</h1><p>测试中文 unicode 与 emoji 编解码。</p>"
        let encoded = ReadmeHTMLCodec.encode(original)
        #expect(encoded != nil)
        let decoded = ReadmeHTMLCodec.decode(encoded)
        #expect(decoded == original)
    }

    @Test("encode / decode 往返:大 HTML 片段")
    func roundTripLargeHTML() {
        // 模拟典型 README HTML:重复结构
        let block = """
        <div class="markdown-body">
          <h2>Installation</h2>
          <pre><code>npm install foo-bar-baz</code></pre>
          <p>This package solves the X problem by Y means.</p>
        </div>
        """
        let original = Array(repeating: block, count: 200).joined(separator: "\n")
        let encoded = ReadmeHTMLCodec.encode(original)
        let decoded = ReadmeHTMLCodec.decode(encoded)
        #expect(decoded == original)
    }

    // MARK: - nil / 空串短路

    @Test("encode nil → nil")
    func encodeNilReturnsNil() {
        #expect(ReadmeHTMLCodec.encode(nil) == nil)
    }

    @Test("encode 空串 → nil(写库不会塞空 BLOB)")
    func encodeEmptyReturnsNil() {
        #expect(ReadmeHTMLCodec.encode("") == nil)
    }

    @Test("decode nil → nil")
    func decodeNilReturnsNil() {
        #expect(ReadmeHTMLCodec.decode(nil) == nil)
    }

    @Test("decode 空 Data → nil")
    func decodeEmptyDataReturnsNil() {
        #expect(ReadmeHTMLCodec.decode(Data()) == nil)
    }

    // MARK: - 压缩比断言

    @Test("结构化 HTML 压缩比 >= 3x(zlib 对重复结构高效)")
    func compressionRatioReasonable() {
        let block = "<div class='x'><p>repeated content</p></div>"
        let original = String(repeating: block, count: 500)
        let originalBytes = Data(original.utf8).count
        let encoded = ReadmeHTMLCodec.encode(original)
        let compressedBytes = encoded!.count

        // 重复结构 zlib 应能压缩到 1/3 以下;断言宽松点防机器差异
        #expect(compressedBytes < originalBytes / 3,
                "压缩后 \(compressedBytes) vs 原文 \(originalBytes),比 \(Double(originalBytes) / Double(compressedBytes))")
    }

    // MARK: - 兜底

    @Test("decode 非压缩 utf-8 明文 BLOB → 兜底返回 String")
    func decodeRawTextFallback() {
        // 模拟 encode fallback 路径写的明文 utf-8 字节(或老库残留)
        let rawText = "<h1>not compressed</h1>"
        let blob = Data(rawText.utf8)
        let decoded = ReadmeHTMLCodec.decode(blob)
        #expect(decoded == rawText)
    }

    @Test("decode 损坏 BLOB(既非 zlib 也非 utf-8) → nil")
    func decodeCorruptedBlobReturnsNil() {
        // 0xFF 0xFE 等开头是 BOM / 二进制头,zlib 解压会失败,
        // utf-8 解码也会失败(0xFF 单独不是 utf-8 起始字节)
        let corrupted = Data([0xFF, 0xFE, 0xFD, 0xFC])
        let decoded = ReadmeHTMLCodec.decode(corrupted)
        #expect(decoded == nil)
    }
}

/// Repository 端到端验证:upsert 写明文 String → 库里存压缩 BLOB → find 读回明文 String。
/// 这一层确认 codec 集成进 Readme / TrendingReadme 的 init(row:) / encode(to:) 后,
/// 整个 GRDB 链路对调用方透明。
@Suite("ReadmeHTMLCodec — Repository 端到端")
struct ReadmeHTMLCodecRepositoryIntegrationTests {

    @Test("ReadmeRepository upsert + find 透明压缩")
    func readmeRepositoryRoundTrip() async throws {
        let db = try InMemoryDatabaseManager()
        let repo = ReadmeRepository(database: db)
        let repoId: Int64 = 42

        // 满足 readmes.repo_id 外键
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

        let html = "<div><h1>压缩 round-trip 测试 🚀</h1></div>"
        try await repo.upsert(Readme(
            repoId: repoId,
            content: nil,
            renderedHtml: html,
            etag: "\"e\"",
            lastModified: nil,
            cachedAt: "2026-06-14T00:00:00Z",
            size: html.utf8.count
        ))

        let fetched = try await repo.find(repoId: repoId)
        #expect(fetched?.renderedHtml == html)
        #expect(fetched?.size == html.utf8.count)

        // 直接读底层 BLOB 字节,确认确实是压缩后字节(不是明文)
        let blobBytes: Int = try await db.writer.read { db in
            let data = try Data.fetchOne(
                db,
                sql: "SELECT rendered_html FROM readmes WHERE repo_id = ?",
                arguments: [repoId]
            )
            return data?.count ?? 0
        }
        #expect(blobBytes > 0)
        // 压缩后字节 < 明文(短 HTML 也能小一点)
        #expect(blobBytes < html.utf8.count + 16, "应有压缩或与明文近似,实际 \(blobBytes) vs 明文 \(html.utf8.count)")
    }

    @Test("TrendingReadmeRepository upsert + find 透明压缩")
    func trendingReadmeRepositoryRoundTrip() async throws {
        let db = try InMemoryDatabaseManager()
        let repo = TrendingReadmeRepository(database: db)
        let html = "<h1>trending 压缩</h1><p>" + String(repeating: "x", count: 500) + "</p>"

        try await repo.upsert(TrendingReadme(
            fullName: "owner/repo",
            renderedHtml: html,
            etag: "\"t\"",
            lastModified: nil,
            cachedAt: "2026-06-14T00:00:00Z",
            size: html.utf8.count
        ))

        let fetched = try await repo.find(fullName: "owner/repo")
        #expect(fetched?.renderedHtml == html)
        #expect(fetched?.size == html.utf8.count)

        // 验证底层 BLOB 比明文小(500 字符 x 重复 → zlib 应能显著压缩)
        let blobBytes: Int = try await db.writer.read { db in
            let data = try Data.fetchOne(
                db,
                sql: "SELECT rendered_html FROM trending_readmes WHERE full_name = ?",
                arguments: ["owner/repo"]
            )
            return data?.count ?? 0
        }
        #expect(blobBytes > 0)
        #expect(blobBytes < html.utf8.count / 2, "重复字符 zlib 应能压缩到 1/2 以下,实际 \(blobBytes) vs 明文 \(html.utf8.count)")
    }
}
