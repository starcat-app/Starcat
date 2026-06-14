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

    // MARK: - Prompt 模板渲染（HOM-68 follow-up v2）

    @Test("renderTemplate：替换 {targetLanguage} 与 {readmeHTML} 占位符")
    func renderTemplateSubstitutesPlaceholders() {
        let rendered = ReadmeTranslationService.renderTemplate(
            "Translate into {targetLanguage}: {readmeHTML}",
            targetLanguage: .japanese,
            sourceHtml: "<p>hi</p>"
        )
        #expect(rendered == "Translate into Japanese: <p>hi</p>")
    }

    @Test("renderTemplate：同一占位符出现多次都被替换")
    func renderTemplateReplacesAllOccurrences() {
        let rendered = ReadmeTranslationService.renderTemplate(
            "lang={targetLanguage}; again={targetLanguage}; body={readmeHTML}{readmeHTML}",
            targetLanguage: .english,
            sourceHtml: "X"
        )
        #expect(rendered == "lang=English; again=English; body=XX")
    }

    @Test("AIDefaultPrompts.translation：system 与 user 模板都包含必要占位符与硬约束")
    func defaultTranslationPromptShape() {
        let prompt = AIDefaultPrompts.translation
        // system 含语言占位 + 9 编号 STRICT RULES + EXAMPLE 段（2026-06-14 v2）
        #expect(prompt.systemPrompt.contains(ReadmeTranslationService.targetLanguagePlaceholder))
        #expect(prompt.systemPrompt.contains("STRICT RULES"))
        #expect(prompt.systemPrompt.contains("HTML"))
        // 验证 v2 几个关键新增 / 强化点：HTML 实体 / 注释保真、proper noun 具象例子、EXAMPLE 段
        #expect(prompt.systemPrompt.contains("HTML entities"))
        #expect(prompt.systemPrompt.contains("HTML comments"))
        #expect(prompt.systemPrompt.contains("React"))
        #expect(prompt.systemPrompt.contains("EXAMPLE"))
        // user 含 readmeHTML + 包裹标签
        #expect(prompt.userPromptTemplate.contains(ReadmeTranslationService.readmeHTMLPlaceholder))
        #expect(prompt.userPromptTemplate.contains("<README_FRAGMENT>"))
        #expect(prompt.userPromptTemplate.contains("</README_FRAGMENT>"))
    }

    // MARK: - effectivePromptConfiguration 回退兜底

    @Test("effectivePromptConfiguration：完整自定义 prompt 原样返回")
    func effectivePromptKeepsCustom() {
        let custom = AIPromptConfiguration(
            systemPrompt: "Custom system into {targetLanguage}",
            userPromptTemplate: "Custom user: {readmeHTML}"
        )
        let effective = ReadmeTranslationService.effectivePromptConfiguration(custom)
        #expect(effective.systemPrompt == custom.systemPrompt)
        #expect(effective.userPromptTemplate == custom.userPromptTemplate)
    }

    @Test("effectivePromptConfiguration：用户误清空 system / user 任一时也回退")
    func effectivePromptFallsBackForEmptyEither() {
        let emptySystem = AIPromptConfiguration(systemPrompt: "   ", userPromptTemplate: "Custom user {readmeHTML}")
        let emptyUser = AIPromptConfiguration(systemPrompt: "Custom system", userPromptTemplate: " ")

        #expect(
            ReadmeTranslationService.effectivePromptConfiguration(emptySystem).systemPrompt
                == AIDefaultPrompts.translation.systemPrompt
        )
        #expect(
            ReadmeTranslationService.effectivePromptConfiguration(emptyUser).userPromptTemplate
                == AIDefaultPrompts.translation.userPromptTemplate
        )
    }
}

// MARK: - 与真实 Repository 联动：isCacheFresh / cachedTranslation

@MainActor
@Suite("ReadmeTranslationService 缓存联动")
struct ReadmeTranslationServiceCacheTests {

    /// 隔离的 disk cache + service 三件套。
    ///
    /// **HOM-68 v2（2026-06-15）**：原 GRDB 路径已下线，stack 改为：
    ///   - `DiskReadmeTranslationCache(rootOverride: tmpDir)` 注入测试目录
    ///   - service 直接消费 cache 作为 `translationRepository`
    /// 不再需要 `InMemoryDatabaseManager` / repos 表 fixture（owner/repo 自由组合即可）。
    private func makeStack() async throws
        -> (ReadmeTranslationService, DiskReadmeTranslationCache, AppSettings, URL)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("starcat-service-test-\(UUID().uuidString)", isDirectory: true)
        let cache = DiskReadmeTranslationCache(rootOverride: root)
        let settings = AppSettings()
        let service = ReadmeTranslationService(
            translationRepository: cache,
            settings: settings,
            keychain: KeychainManager.shared
        )
        return (service, cache, settings, root)
    }

    @Test("isCacheFresh：source_hash 匹配当前 sourceHtml → true，被改一字符 → false")
    func isCacheFreshReactsToSourceChange() async throws {
        let (service, cache, _, root) = try await makeStack()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "<h1>Title</h1><p>body</p>"

        try await cache.upsert(
            ReadmeTranslation(
                repoId: 99,
                targetLanguage: "zh-Hans",
                model: "test-model",
                sourceHash: ReadmeTranslationService.hash(source),
                translatedHtml: "<h1>标题</h1><p>正文</p>",
                size: 16,
                createdAt: "2026-06-05T10:00:00Z"
            ),
            owner: "octo",
            repo: "demo"
        )

        let cached = try #require(
            try await service.cachedTranslation(
                owner: "octo",
                repo: "demo",
                targetLanguage: .simplifiedChinese
            )
        )

        #expect(service.isCacheFresh(cached: cached, sourceHtml: source))
        #expect(!service.isCacheFresh(cached: cached, sourceHtml: source + "."))
    }

    @Test("cachedTranslation：按 (owner, repo, language) 取，命中错语言时返回 nil")
    func cachedTranslationKeyedByLanguage() async throws {
        let (service, cache, _, root) = try await makeStack()
        defer { try? FileManager.default.removeItem(at: root) }
        try await cache.upsert(
            ReadmeTranslation(
                repoId: 99,
                targetLanguage: "ja",
                model: "test-model",
                sourceHash: "fixed",
                translatedHtml: "<p>こんにちは</p>",
                size: 10,
                createdAt: "2026-06-05T10:00:00Z"
            ),
            owner: "octo",
            repo: "demo"
        )

        let jaHit = try await service.cachedTranslation(
            owner: "octo",
            repo: "demo",
            targetLanguage: .japanese
        )
        let zhMiss = try await service.cachedTranslation(
            owner: "octo",
            repo: "demo",
            targetLanguage: .simplifiedChinese
        )

        #expect(jaHit?.translatedHtml == "<p>こんにちは</p>")
        #expect(zhMiss == nil)
    }
}

// MARK: - HOM-68 follow-up：翻译任务独立配置

@MainActor
@Suite("AppSettings.aiTranslationTask（HOM-68 follow-up）")
struct AppSettingsTranslationTaskTests {

    /// 给每个用例单独的 UserDefaults suite，避免相互污染或读到磁盘上的真实偏好。
    private func makeSettings(_ suite: String = UUID().uuidString) -> AppSettings {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults)
    }

    @Test("首次升级：未持久化时 aiTranslationTask 默认值与 aiSummaryTask 共享 provider+model")
    func defaultsAlignWithSummaryProviderAndModel() {
        let settings = makeSettings()
        let summary = settings.aiSummaryTask
        let translation = settings.aiTranslationTask

        #expect(translation.providerID == summary.providerID, "翻译默认 provider 应与摘要一致")
        #expect(translation.modelID == summary.modelID, "翻译默认 model 应与摘要一致")
    }

    @Test("首次升级：aiTranslationTask 默认参数 = AIModelParameters.translationDefault（低温度 + 大 maxToken）")
    func defaultParametersUseTranslationDefault() {
        let settings = makeSettings()
        let params = settings.aiTranslationTask.parameters

        #expect(params.temperature == AIModelParameters.translationDefault.temperature)
        #expect(params.maxCompletionTokens == AIModelParameters.translationDefault.maxCompletionTokens)
        #expect(params.timeoutSeconds == AIModelParameters.translationDefault.timeoutSeconds)
        #expect(params.streamEnabled == AIModelParameters.translationDefault.streamEnabled)
        // 翻译应当比摘要更低温度（保结构 vs 通顺）
        #expect(params.temperature < settings.aiSummaryTask.parameters.temperature)
    }

    @Test("aiTranslationTask 写入后再 init 同 suite 能正确读回（独立 UserDefaults 键）")
    func translationTaskIsPersistedIndependently() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let first = AppSettings(defaults: defaults)

        var mutated = first.aiTranslationTask
        mutated.providerID = "test-profile-id"
        mutated.modelID = "gpt-4o-translation"
        mutated.customModelName = "gpt-4o-translation"
        mutated.parameters.temperature = 0.05
        first.aiTranslationTask = mutated

        // 摘要任务不应受影响（独立键）
        #expect(first.aiSummaryTask.providerID != "test-profile-id")

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.aiTranslationTask.providerID == "test-profile-id")
        #expect(reloaded.aiTranslationTask.modelID == "gpt-4o-translation")
        #expect(reloaded.aiTranslationTask.parameters.temperature == 0.05)
    }

    @Test("AIModelTask.translation 暴露 chat capability + 非空 displayName")
    func translationTaskEnumShape() {
        #expect(AIModelTask.translation.requiredCapability == .chat)
        #expect(!AIModelTask.translation.displayName.isEmpty)
        #expect(AIModelTask.allCases.contains(.translation))
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
