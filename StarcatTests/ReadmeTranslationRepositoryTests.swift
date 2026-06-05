//
//  ReadmeTranslationRepositoryTests.swift
//  StarcatTests
//
//  覆盖 GRDBReadmeTranslationRepository CRUD（HOM-68）。
//
//  关注点：
//  - (repo_id, target_language) 复合 PK：同 repo 不同语言可并存；同 repo 同语言 upsert 覆盖；
//  - 多语言 upsert 后能按各自语言取回；
//  - delete(repoId:targetLanguage:) 只删指定语言记录，其他语言保留；
//  - deleteAll(repoId:) 清空该 repo 所有语言译文；
//  - ON DELETE CASCADE：删 repo 时 readme_translations 一起清——保证不会留孤儿数据。
//

import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("ReadmeTranslationRepository")
struct ReadmeTranslationRepositoryTests {

    /// 起内存库 + 插入一行 repos（满足外键约束）。
    /// 返回 repository、db handle、可用 repoId 三件套。
    private func makeRepoAndDb(repoId: Int64 = 42) async throws
        -> (GRDBReadmeTranslationRepository, any DatabaseManaging, Int64)
    {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBReadmeTranslationRepository(database: db)
        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (
                    id, owner, name, full_name, html_url, cached_at
                ) VALUES (?, 'octo', 'demo', 'octo/demo', 'https://github.com/octo/demo', '2026-05-30T00:00:00Z')
                """,
                arguments: [repoId]
            )
        }
        return (repo, db, repoId)
    }

    private func makeTranslation(
        repoId: Int64,
        lang: String,
        html: String = "<p>已翻译</p>",
        hash: String = "deadbeef",
        model: String = "gpt-4o-mini"
    ) -> ReadmeTranslation {
        ReadmeTranslation(
            repoId: repoId,
            targetLanguage: lang,
            model: model,
            sourceHash: hash,
            translatedHtml: html,
            size: html.utf8.count,
            createdAt: "2026-06-05T10:00:00Z"
        )
    }

    @Test("find 未命中返回 nil")
    func findMiss() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        let result = try await repo.find(repoId: repoId, targetLanguage: "zh-Hans")
        #expect(result == nil)
    }

    @Test("upsert + find 同语言往返")
    func upsertAndFind() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        let record = makeTranslation(repoId: repoId, lang: "zh-Hans", html: "<h1>你好</h1>")
        try await repo.upsert(record)

        let fetched = try await repo.find(repoId: repoId, targetLanguage: "zh-Hans")
        let expectedHtml = "<h1>你好</h1>"
        #expect(fetched?.translatedHtml == expectedHtml)
        #expect(fetched?.targetLanguage == "zh-Hans")
        // 注意：size 是 UTF-8 字节数，中文每字 3 字节，所以 `<h1>你好</h1>` = 9 ASCII + 6 中文 = 15
        #expect(fetched?.size == expectedHtml.utf8.count)
        #expect(fetched?.sourceHash == "deadbeef")
        #expect(fetched?.model == "gpt-4o-mini")
    }

    @Test("同 repo + 同语言 upsert 覆盖，不抛主键冲突")
    func upsertOverwritesSameLanguage() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "zh-Hans", html: "v1", hash: "h1"))
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "zh-Hans", html: "v2", hash: "h2"))

        let fetched = try await repo.find(repoId: repoId, targetLanguage: "zh-Hans")
        #expect(fetched?.translatedHtml == "v2")
        #expect(fetched?.sourceHash == "h2")
    }

    @Test("同 repo + 不同语言可以并存")
    func multipleLanguagesCoexist() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "zh-Hans", html: "你好"))
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "ja", html: "こんにちは"))

        let zh = try await repo.find(repoId: repoId, targetLanguage: "zh-Hans")
        let ja = try await repo.find(repoId: repoId, targetLanguage: "ja")
        #expect(zh?.translatedHtml == "你好")
        #expect(ja?.translatedHtml == "こんにちは")
    }

    @Test("delete(language) 只删指定语言，其他语言保留")
    func deleteOneLanguageKeepsOthers() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "zh-Hans"))
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "ja"))

        try await repo.delete(repoId: repoId, targetLanguage: "zh-Hans")

        #expect(try await repo.find(repoId: repoId, targetLanguage: "zh-Hans") == nil)
        #expect(try await repo.find(repoId: repoId, targetLanguage: "ja") != nil)
    }

    @Test("deleteAll(repoId) 清空该 repo 全部语言译文")
    func deleteAllLanguages() async throws {
        let (repo, _, repoId) = try await makeRepoAndDb()
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "zh-Hans"))
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "en"))
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "ja"))

        try await repo.deleteAll(repoId: repoId)

        #expect(try await repo.find(repoId: repoId, targetLanguage: "zh-Hans") == nil)
        #expect(try await repo.find(repoId: repoId, targetLanguage: "en") == nil)
        #expect(try await repo.find(repoId: repoId, targetLanguage: "ja") == nil)
    }

    @Test("外键 ON DELETE CASCADE：删 repos 行连带删除全部语言译文")
    func cascadeDeleteFromRepos() async throws {
        let (repo, db, repoId) = try await makeRepoAndDb()
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "zh-Hans"))
        try await repo.upsert(makeTranslation(repoId: repoId, lang: "ja"))

        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM repos WHERE id = ?", arguments: [repoId])
        }

        #expect(try await repo.find(repoId: repoId, targetLanguage: "zh-Hans") == nil)
        #expect(try await repo.find(repoId: repoId, targetLanguage: "ja") == nil)
    }
}
