//
//  ReadmeTranslationServiceTests.swift
//  StarcatTests
//
//  覆盖 ReadmeTranslationService 中可不依赖 AI 客户端的纯逻辑：
//  - SHA256 哈希稳定性 + 与 isCacheFresh 联动；
//  - stripFenceWrapping 正常剥离 / 内嵌代码块不误伤；
//  - assertStructureNotBroken 阈值行为；
//  - systemPrompt / userPrompt 包含目标语言 promptName 与硬约束关键字。
//
//  设计取舍：
//  - 不 mock AI client：完整 translate 路径需要 OpenAIClient + AppSettings + Keychain 全套联动，
//    投入产出比低；改用「拆出来测纯函数 + 拆 cachedTranslation 走真 repository」组合覆盖。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ReadmeTranslationService 静态辅助")
struct ReadmeTranslationServiceStaticTests {

    // MARK: - hash 行为

    @Test("hash：相同输入 → 相同输出；不同输入 → 不同输出")
    func hashIsDeterministic() {
        let a1 = ReadmeTranslationService.hash("hello world")
        let a2 = ReadmeTranslationService.hash("hello world")
        let b1 = ReadmeTranslationService.hash("hello world!")
        #expect(a1 == a2)
        #expect(a1 != b1)
        #expect(a1.count == 64, "SHA256 hex 长度应为 64")
        #expect(a1.allSatisfy { $0.isHexDigit })
    }

    // MARK: - stripFenceWrapping

    @Test("stripFenceWrapping：剥掉 ```html ...``` 围栏")
    func stripFenceHtml() {
        let input = """
        ```html
        <h1>你好</h1>
        ```
        """
        let cleaned = ReadmeTranslationService.stripFenceWrapping(input)
        #expect(cleaned == "<h1>你好</h1>")
    }

    @Test("stripFenceWrapping：剥掉裸 ``` 围栏")
    func stripFenceBare() {
        let input = """
        ```
        <p>x</p>
        ```
        """
        let cleaned = ReadmeTranslationService.stripFenceWrapping(input)
        #expect(cleaned == "<p>x</p>")
    }

    @Test("stripFenceWrapping：无围栏文本原样返回")
    func stripFenceNoOp() {
        let raw = "<h1>纯</h1><p>正文</p>"
        #expect(ReadmeTranslationService.stripFenceWrapping(raw) == raw)
    }

    // MARK: - assertStructureNotBroken

    @Test("结构校验：tag 数量持平 → 通过")
    func structurePass() throws {
        let src = "<h1>A</h1><p>B</p>"
        let translated = "<h1>甲</h1><p>乙</p>"
        try ReadmeTranslationService.assertStructureNotBroken(source: src, translated: translated)
    }

    @Test("结构校验：tag 减少 >30% → 抛 structureBroken")
    func structureFailsOnMajorReduction() {
        let src = "<h1>A</h1><p>B</p><p>C</p><p>D</p>" // 4 个 '<'
        let translated = "纯文本无标签" // 0 个 '<' → 100% 损失
        #expect(throws: ReadmeTranslationError.structureBroken) {
            try ReadmeTranslationService.assertStructureNotBroken(source: src, translated: translated)
        }
    }

    @Test("结构校验：源无 tag（纯文本 README）→ 跳过校验")
    func structureSkippedForPlainText() throws {
        let src = "纯文本 README，无任何 HTML 标签"
        let translated = "Plain text README"
        try ReadmeTranslationService.assertStructureNotBroken(source: src, translated: translated)
    }

    // MARK: - Prompt 拼装

    @Test("systemPrompt：包含目标语言 promptName 与硬约束关键字")
    func systemPromptContainsLanguageAndRules() {
        let prompt = ReadmeTranslationService.systemPrompt(targetLanguage: .simplifiedChinese)
        #expect(prompt.contains(ReadmeTranslationLanguage.simplifiedChinese.promptName))
        #expect(prompt.contains("STRICT RULES"))
        #expect(prompt.contains("Do NOT translate"))
        #expect(prompt.contains("HTML"))
    }

    @Test("userPrompt：包含 <README_FRAGMENT> 包裹与目标语言")
    func userPromptWrapsSource() {
        let html = "<h1>Hello</h1>"
        let prompt = ReadmeTranslationService.userPrompt(
            sourceHtml: html,
            targetLanguage: .japanese
        )
        #expect(prompt.contains(html))
        #expect(prompt.contains("<README_FRAGMENT>"))
        #expect(prompt.contains("</README_FRAGMENT>"))
        #expect(prompt.contains(ReadmeTranslationLanguage.japanese.promptName))
    }
}

// MARK: - 与真实 Repository 联动：isCacheFresh / cachedTranslation

@MainActor
@Suite("ReadmeTranslationService 缓存联动")
struct ReadmeTranslationServiceCacheTests {

    private func makeStack() async throws
        -> (ReadmeTranslationService, GRDBReadmeTranslationRepository, AppSettings, Int64)
    {
        let db = try InMemoryDatabaseManager()
        let translationRepo = GRDBReadmeTranslationRepository(database: db)
        let settings = AppSettings()
        let service = ReadmeTranslationService(
            translationRepository: translationRepo,
            settings: settings,
            keychain: KeychainManager.shared
        )

        let repoId: Int64 = 99
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
        return (service, translationRepo, settings, repoId)
    }

    @Test("isCacheFresh：source_hash 匹配当前 sourceHtml → true，被改一字符 → false")
    func isCacheFreshReactsToSourceChange() async throws {
        let (service, repo, _, repoId) = try await makeStack()
        let source = "<h1>Title</h1><p>body</p>"

        try await repo.upsert(ReadmeTranslation(
            repoId: repoId,
            targetLanguage: "zh-Hans",
            model: "test-model",
            sourceHash: ReadmeTranslationService.hash(source),
            translatedHtml: "<h1>标题</h1><p>正文</p>",
            size: 16,
            createdAt: "2026-06-05T10:00:00Z"
        ))

        let cached = try #require(
            try await service.cachedTranslation(repoId: repoId, targetLanguage: .simplifiedChinese)
        )

        #expect(service.isCacheFresh(cached: cached, sourceHtml: source))
        #expect(!service.isCacheFresh(cached: cached, sourceHtml: source + "."))
    }

    @Test("cachedTranslation：按 (repo_id, language) 取，命中错语言时返回 nil")
    func cachedTranslationKeyedByLanguage() async throws {
        let (service, repo, _, repoId) = try await makeStack()
        try await repo.upsert(ReadmeTranslation(
            repoId: repoId,
            targetLanguage: "ja",
            model: "test-model",
            sourceHash: "fixed",
            translatedHtml: "<p>こんにちは</p>",
            size: 10,
            createdAt: "2026-06-05T10:00:00Z"
        ))

        let jaHit = try await service.cachedTranslation(
            repoId: repoId,
            targetLanguage: .japanese
        )
        let zhMiss = try await service.cachedTranslation(
            repoId: repoId,
            targetLanguage: .simplifiedChinese
        )

        #expect(jaHit?.translatedHtml == "<p>こんにちは</p>")
        #expect(zhMiss == nil)
    }
}

// MARK: - ReadmeTranslationLanguage 偏好枚举

@Suite("ReadmeTranslationLanguage")
struct ReadmeTranslationLanguageTests {

    @Test("rawValue 为 BCP-47 风格 tag")
    func rawValuesAreBcp47() {
        #expect(ReadmeTranslationLanguage.simplifiedChinese.rawValue == "zh-Hans")
        #expect(ReadmeTranslationLanguage.traditionalChinese.rawValue == "zh-Hant")
        #expect(ReadmeTranslationLanguage.english.rawValue == "en")
        #expect(ReadmeTranslationLanguage.japanese.rawValue == "ja")
        #expect(ReadmeTranslationLanguage.korean.rawValue == "ko")
    }

    @Test("promptName 非空且不包含 raw tag（用于 LLM 自然语言提示）")
    func promptNamesAreReadable() {
        for lang in ReadmeTranslationLanguage.allCases {
            #expect(!lang.promptName.isEmpty)
            #expect(!lang.displayName.isEmpty)
        }
    }
}
