//
//  ReadmeTranslationServiceTests.swift
//  StarcatTests
//
//  覆盖 ReadmeTranslationService 中可不依赖 AI 客户端的纯逻辑：
//  - SHA256 哈希稳定性 + 与 isCacheFresh 联动；
//  - stripFenceWrapping 正常剥离；
//  - 首批优先和后续字符预算切分；
//  - 分段 JSON Prompt 占位符与旧默认 Prompt 迁移；
//  - Provider 外围文本提取、严格 id 校验与单批重试。
//
//  设计取舍：
//  - 完整 translate 路径仍不连接真实 Provider；仅用队列 stub 覆盖单批重试，缓存联动继续
//    使用真实 DiskReadmeTranslationCache，避免测试依赖 API Key 或网络。
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

    // MARK: - 分段响应解析与重试

    @Test("decodeBatchResponse：从 think + fence 外围文本中提取严格 JSON")
    func extractsJSONFromReasoningAndFence() throws {
        let source = [
            ReadmeSourceSegment(id: "segment-1", text: "Hello"),
            ReadmeSourceSegment(id: "segment-2", text: "Use `npm install`")
        ]
        let response = #"""
        <think>This outline contains {not-json} and must not be returned.</think>
        ```json
        {"translations":[
          {"id":"segment-1","translation":"你好"},
          {"id":"segment-2","translation":"使用 `npm install`"}
        ]}
        ```
        """#

        let decoded = try #require(
            ReadmeTranslationService.decodeBatchResponse(response, source: source)
        )
        #expect(decoded.count == 2)
        #expect(decoded[0].sourceHash == source[0].sourceHash)
        #expect(decoded[0].translatedText == "你好")
        #expect(decoded[1].translatedText == "使用 `npm install`")
    }

    @Test("decodeBatchResponse：缺失、重复或未知 id 时拒绝结果")
    func rejectsUnsafeSegmentAlignment() {
        let source = [
            ReadmeSourceSegment(id: "segment-1", text: "One"),
            ReadmeSourceSegment(id: "segment-2", text: "Two")
        ]
        let missing = #"{"translations":[{"id":"segment-1","translation":"一"}]}"#
        let duplicate = #"{"translations":[{"id":"segment-1","translation":"一"},{"id":"segment-1","translation":"二"}]}"#
        let unknown = #"{"translations":[{"id":"segment-1","translation":"一"},{"id":"segment-x","translation":"二"}]}"#

        #expect(ReadmeTranslationService.decodeBatchResponse(missing, source: source) == nil)
        #expect(ReadmeTranslationService.decodeBatchResponse(duplicate, source: source) == nil)
        #expect(ReadmeTranslationService.decodeBatchResponse(unknown, source: source) == nil)
    }

    @Test("performBatch：首次结构异常时只重试当前批次一次")
    func retriesMalformedBatchOnce() async throws {
        let source = [ReadmeSourceSegment(id: "segment-1", text: "Hello")]
        let queue = TranslationResponseQueue(contents: [
            "I translated it, but forgot JSON.",
            #"{"translations":[{"id":"segment-1","translation":"你好"}]}"#
        ])
        let client = TranslationAIClientStub(queue: queue)

        let result = try await ReadmeTranslationService.performBatch(
            client: client,
            request: Self.makeRequest(),
            source: source
        )
        let callCount = await queue.callCount

        #expect(callCount == 2)
        #expect(result.map(\.translatedText) == ["你好"])
    }

    @Test("performBatch：连续两次结构异常后返回 structureBroken")
    func stopsAfterSingleRetry() async {
        let source = [ReadmeSourceSegment(id: "segment-1", text: "Hello")]
        let queue = TranslationResponseQueue(contents: ["invalid-1", "invalid-2"])
        let client = TranslationAIClientStub(queue: queue)

        await #expect(throws: ReadmeTranslationError.structureBroken) {
            try await ReadmeTranslationService.performBatch(
                client: client,
                request: Self.makeRequest(),
                source: source
            )
        }
        let callCount = await queue.callCount
        #expect(callCount == 2)
    }

    private static func makeRequest() -> AIChatRequest {
        AIChatRequest(
            systemPrompt: "Return JSON.",
            userPrompt: #"{"segments":[]}"#,
            model: "test-model",
            parameters: .translationDefault,
            responseFormat: .jsonObject
        )
    }

    // MARK: - Prompt 模板渲染

    @Test("renderTemplate：替换 {targetLanguage} 与 {readmeSegments} 占位符")
    func renderTemplateSubstitutesPlaceholders() {
        let rendered = ReadmeTranslationService.renderTemplate(
            "Translate into {targetLanguage}: {readmeSegments}",
            targetLanguage: .japanese,
            sourceSegmentsJSON: #"{"segments":[]}"#
        )
        #expect(rendered == #"Translate into Japanese: {"segments":[]}"#)
    }

    @Test("renderTemplate：旧 {readmeHTML} 自定义占位符仍注入分段 JSON")
    func renderTemplateSupportsLegacyCustomPlaceholder() {
        let rendered = ReadmeTranslationService.renderTemplate(
            "lang={targetLanguage}; body={readmeHTML}",
            targetLanguage: .english,
            sourceSegmentsJSON: "JSON"
        )
        #expect(rendered == "lang=English; body=JSON")
    }

    @Test("renderTemplate：全文 Prompt 的 {readmeTextNodes} 注入纯文本节点 JSON")
    func renderTemplateSupportsFullTextNodesPlaceholder() {
        let rendered = ReadmeTranslationService.renderTemplate(
            "lang={targetLanguage}; nodes={readmeTextNodes}",
            targetLanguage: .simplifiedChinese,
            sourceSegmentsJSON: "JSON"
        )
        #expect(rendered == "lang=Simplified Chinese; nodes=JSON")
    }

    @Test("AIDefaultPrompts.translation：要求严格 JSON 与逐 id 返回")
    func defaultTranslationPromptShape() {
        let prompt = AIDefaultPrompts.translation
        #expect(prompt.systemPrompt.contains(ReadmeTranslationService.targetLanguagePlaceholder))
        #expect(prompt.systemPrompt.contains("strict JSON"))
        #expect(prompt.systemPrompt.contains(#""translations""#))
        #expect(prompt.systemPrompt.contains("Preserve each id"))
        #expect(prompt.systemPrompt.contains("copy the source text"))
        #expect(prompt.userPromptTemplate.contains(ReadmeTranslationService.readmeSegmentsPlaceholder))
    }

    @Test("AIDefaultPrompts.fullTranslation：不接收 HTML，并要求逐文本节点返回")
    func defaultFullTranslationPromptShape() {
        let prompt = AIDefaultPrompts.fullTranslation
        #expect(prompt.systemPrompt.contains(ReadmeTranslationService.targetLanguagePlaceholder))
        #expect(prompt.systemPrompt.contains("strict JSON"))
        #expect(prompt.systemPrompt.contains("text node"))
        #expect(prompt.systemPrompt.contains("do not output HTML"))
        #expect(prompt.systemPrompt.contains("copy the source text"))
        #expect(prompt.userPromptTemplate.contains(ReadmeTranslationService.readmeTextNodesPlaceholder))
    }

    @Test("makeBatches：首批最多 5 段，后续最多 10 段且不漏段")
    func batchesPrioritizeSmallFirstBatch() {
        let segments = (0..<23).map {
            ReadmeSourceSegment(id: "s-\($0)", text: "segment \($0)")
        }
        let batches = ReadmeTranslationService.makeBatches(segments)

        #expect(batches.first?.count == 5)
        #expect(batches.dropFirst().allSatisfy { $0.count <= 10 })
        #expect(batches.flatMap { $0 }.map(\.id) == segments.map(\.id))
    }

    @Test("后续批次并发上限固定为 4")
    func concurrentBatchLimitIsFour() {
        #expect(ReadmeTranslationService.maxConcurrentBatchCount == 4)
    }

    // MARK: - effectivePromptConfiguration 回退兜底

    @Test("effectivePromptConfiguration：完整自定义 prompt 原样返回")
    func effectivePromptKeepsCustom() {
        let custom = AIPromptConfiguration(
            systemPrompt: "Custom system into {targetLanguage}",
            userPromptTemplate: "Custom user: {readmeSegments}"
        )
        let effective = ReadmeTranslationService.effectivePromptConfiguration(custom)
        #expect(effective.systemPrompt == custom.systemPrompt)
        #expect(effective.userPromptTemplate == custom.userPromptTemplate)
    }

    @Test("effectivePromptConfiguration：用户误清空 system / user 任一时也回退")
    func effectivePromptFallsBackForEmptyEither() {
        let emptySystem = AIPromptConfiguration(systemPrompt: "   ", userPromptTemplate: "Custom user {readmeSegments}")
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

    @Test("effectivePromptConfiguration：旧整页 HTML 默认 Prompt 自动升级")
    func effectivePromptMigratesLegacyDefault() {
        #expect(
            ReadmeTranslationService.effectivePromptConfiguration(
                AIDefaultPrompts.legacyTranslationHTMLV1
            ) == AIDefaultPrompts.translation
        )
    }

    @Test("effectivePromptConfiguration：全文 Prompt 清空时回退全文默认值")
    func effectiveFullPromptFallsBackToFullDefault() {
        let empty = AIPromptConfiguration(systemPrompt: "", userPromptTemplate: "")
        #expect(
            ReadmeTranslationService.effectivePromptConfiguration(
                empty,
                mode: .full
            ) == AIDefaultPrompts.fullTranslation
        )
    }
}

/// 按顺序提供模型正文，让重试测试不依赖真实 Provider 或时间。
private actor TranslationResponseQueue {
    private var contents: [String]
    private(set) var callCount = 0

    init(contents: [String]) {
        self.contents = contents
    }

    func next() throws -> AIChatResponse {
        guard !contents.isEmpty else { throw AIClientError.emptyResponse }
        callCount += 1
        return AIChatResponse(
            content: contents.removeFirst(),
            model: "test-model",
            finishReason: "stop"
        )
    }
}

/// 仅实现 `performBatch` 会调用的非流式 chat，其余能力若被误调即明确失败。
private struct TranslationAIClientStub: AIClientProtocol {
    let queue: TranslationResponseQueue

    func chat(request: AIChatRequest) async throws -> AIChatResponse {
        try await queue.next()
    }

    func chatStream(request: AIChatRequest) -> AsyncThrowingStream<AIChatStreamEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIClientError.emptyResponse) }
    }

    func chat(systemPrompt: String, userPrompt: String, model: String?) async throws -> String {
        throw AIClientError.emptyResponse
    }

    func embedding(input: String, model: String?) async throws -> [Float] {
        throw AIClientError.emptyResponse
    }

    func embeddings(inputs: [String], model: String?) async throws -> [[Float]] {
        throw AIClientError.emptyResponse
    }

    func listModels() async throws -> [AIModelDescriptor] { [] }

    func testConnection() async throws {}
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
                segments: [
                    ReadmeTranslatedSegment(
                        sourceHash: ReadmeSourceSegment(id: "s1", text: "Title").sourceHash,
                        translatedText: "标题"
                    )
                ],
                isComplete: true,
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
                segments: [
                    ReadmeTranslatedSegment(sourceHash: "hash", translatedText: "こんにちは")
                ],
                isComplete: true,
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

        #expect(jaHit?.segments.first?.translatedText == "こんにちは")
        #expect(zhMiss == nil)
    }

    @Test("renderedTranslations：按段落 hash 对齐到当前 DOM id，段落重排仍可复用")
    func renderedTranslationsUseCurrentDOMIDs() async throws {
        let (service, _, _, root) = try await makeStack()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ReadmeSourceSegment(id: "current-2", text: "Second paragraph")
        let second = ReadmeSourceSegment(id: "current-1", text: "First paragraph")
        let cached = ReadmeTranslation(
            repoId: 99,
            targetLanguage: "zh-Hans",
            model: "test-model",
            sourceHash: "old-document",
            segments: [
                ReadmeTranslatedSegment(sourceHash: second.sourceHash, translatedText: "第一段"),
                ReadmeTranslatedSegment(sourceHash: first.sourceHash, translatedText: "第二段")
            ],
            isComplete: true,
            size: 18,
            createdAt: "2026-06-05T10:00:00Z"
        )

        let rendered = service.renderedTranslations(
            from: cached,
            matching: [first, second]
        )

        #expect(rendered.map(\.id) == ["current-2", "current-1"])
        #expect(rendered.map(\.translatedText) == ["第二段", "第一段"])
    }

    @Test("全部段落已是目标语言时直接失败，不要求 API Key")
    func alreadyInTargetLanguageDoesNotNeedClient() async throws {
        let (service, _, _, root) = try await makeStack()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "这是一段足够长的简体中文说明，用来确认翻译服务在同语种时不会去创建 AI 客户端。"
        await #expect(throws: ReadmeTranslationError.alreadyInTargetLanguage) {
            try await service.translate(
                request: ReadmeTranslationRequest(
                    cacheOwner: "octo",
                    cacheRepo: "demo",
                    sourceHtml: text,
                    sourceSegments: [ReadmeSourceSegment(id: "o:0", text: text)],
                    targetLanguage: .simplifiedChinese,
                    mode: .segmented
                ),
                cached: nil
            )
        }
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

    @Test("全文 Prompt 独立持久化，不改动分段 Prompt 与任务模型")
    func fullTranslationPromptIsPersistedIndependently() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let first = AppSettings(defaults: defaults)
        let segmentedPrompt = first.aiTranslationTask.prompt
        let providerID = first.aiTranslationTask.providerID
        let custom = AIPromptConfiguration(
            systemPrompt: "Full system {targetLanguage}",
            userPromptTemplate: "Full nodes {readmeTextNodes}"
        )

        first.aiFullTranslationPrompt = custom

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.aiFullTranslationPrompt == custom)
        #expect(reloaded.aiTranslationTask.prompt == segmentedPrompt)
        #expect(reloaded.aiTranslationTask.providerID == providerID)
    }

    @Test("README 翻译方式默认分段并可独立持久化")
    func translationModeDefaultsAndPersists() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let first = AppSettings(defaults: defaults)
        #expect(first.readmeTranslationMode == .segmented)

        first.readmeTranslationMode = .full

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.readmeTranslationMode == .full)
    }

    @Test("旧整页 HTML 默认 Prompt 只迁移 Prompt，保留 Provider 与 Model")
    func legacyDefaultTranslationPromptMigratesSafely() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let first = AppSettings(defaults: defaults)

        var legacy = first.aiTranslationTask
        legacy.providerID = "kept-provider"
        legacy.modelID = "kept-model"
        legacy.prompt = AIDefaultPrompts.legacyTranslationHTMLV1
        first.aiTranslationTask = legacy

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.aiTranslationTask.providerID == "kept-provider")
        #expect(reloaded.aiTranslationTask.modelID == "kept-model")
        #expect(reloaded.aiTranslationTask.prompt == AIDefaultPrompts.translation)
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

    @Test("rawValue：auto 单独；其余为 BCP-47 风格 tag")
    func rawValuesAreBcp47() {
        let expectedIdentifiers: Set<String> = [
            "en", "zh-Hans", "zh-Hant", "ja", "ko", "de", "fr", "es", "pt-BR",
            "it", "ru", "nl", "pl", "uk", "tr", "vi", "id", "ar",
        ]
        let concreteIdentifiers = Set(
            ReadmeTranslationLanguage.allCases
                .filter { $0 != .auto }
                .map(\.rawValue)
        )

        #expect(ReadmeTranslationLanguage.allCases.first == .auto)
        #expect(ReadmeTranslationLanguage.auto.rawValue == "auto")
        #expect(concreteIdentifiers == expectedIdentifiers)
        #expect(
            concreteIdentifiers == Set(
                AppLocale.allCases
                    .filter { $0 != .system }
                    .map(\.rawValue)
            )
        )
    }

    @Test("展示名包含国旗且 promptName 非空")
    func promptNamesAreReadable() {
        #expect(!ReadmeTranslationLanguage.auto.displayName.isEmpty)
        for lang in ReadmeTranslationLanguage.allCases where lang != .auto {
            #expect(!lang.promptName.isEmpty)
            #expect(!lang.displayName.isEmpty)
            let leadingScalars = lang.displayName.unicodeScalars.prefix(2)
            #expect(
                leadingScalars.count == 2
                    && leadingScalars.allSatisfy { (0x1F1E6...0x1F1FF).contains($0.value) }
            )
        }
    }
}

@Suite("ReadmeTranslationMode")
struct ReadmeTranslationModeTests {

    @Test("翻译方式菜单图标与呈现语义一致")
    func systemImagesMatchPresentationMode() {
        #expect(ReadmeTranslationMode.segmented.systemImage == "text.append")
        #expect(ReadmeTranslationMode.full.systemImage == "doc.text")
    }
}
