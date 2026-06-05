//
//  ReadmeTranslationService.swift
//  Starcat
//
//  README 翻译服务（HOM-68）。
//
//  模块职责：
//  - 把"GitHub HTML render 端点返回的 README 片段"作为源，调用 LLM 翻译成目标语言；
//  - 翻译结果按 `(repo_id, target_language)` 缓存到本地（`readme_translations` 表）；
//  - 提供 `cachedTranslation` / `translate` 两类接口给 ViewModel，UI 端不直接接触 AI 客户端。
//
//  **关键约束**（HOM-68 验收）：
//  1. **保留结构**：必须保留 Markdown/HTML 标签、代码块、表格、链接、图片不变；
//     - 实现方式：system prompt 用强约束语言要求模型"只翻译可见文本，禁止改动任何
//       HTML tag / attribute / code block 内部内容"；
//     - 后处理：调用方在拿到模型输出后，若发现 `<` / `>` 数量与原文严重失衡，
//       视作模型破坏结构 → 抛错并丢弃译文（不写缓存），让用户手动重试；
//     - 第一版不做 DOM 解析重写。原因：原 README HTML 大小受控（GitHub render 端
//       默认会做合理截断），强 system prompt + Markdown 输入习惯下，主流 chat 模型
//       已经能保留绝大多数结构；引入 SwiftSoup 类依赖只是为了一个 P2 推迟功能性价比低。
//  2. **缓存复用**：`source_hash` 命中即返回缓存。源 README 变更（hash 不同）需要
//     用户主动触发重新翻译（避免静默吃 AI 配额做隐式翻译）。
//  3. **翻译失败保留原文**：本 service 失败抛错即可，UI 端 ViewModel 在错误分支
//     不切换显示状态，README 区域继续渲染原文。
//
//  **复用 RepoAIInsightService 的 chat client 构造逻辑**：
//  - 都需要按 `aiSummaryTask.providerID` 查 profile、按 profile 取 keychain API Key；
//  - 都需要尊重 timeoutSeconds / temperature / streamEnabled 等用户设置；
//  - 但 RepoAIInsightService 已经把 makeClient 设为 private，且其 system prompt
//    完全是"摘要专用"——这里没办法直接复用，所以独立一份 makeClient + system prompt，
//    实现量小可控；后续若两边演进出更多通用逻辑再抽 helper。
//

import CryptoKit
import Foundation

/// README 翻译错误。
enum ReadmeTranslationError: Error, LocalizedError, Equatable {
    /// 当前任务对应的 provider 不存在。
    case missingProvider
    /// provider 需要 API Key 但用户未配置。
    case missingAPIKey
    /// 源 README 为空（仓库没有 README）。
    case emptySource
    /// 模型输出明显破坏了 HTML 结构（标签数量与原文严重失衡）。
    case structureBroken

    var errorDescription: String? {
        switch self {
        case .missingProvider:
            return String(localized: "readme.translate.error.missingProvider")
        case .missingAPIKey:
            return String(localized: "readme.translate.error.missingAPIKey")
        case .emptySource:
            return String(localized: "readme.translate.error.emptySource")
        case .structureBroken:
            return String(localized: "readme.translate.error.structureBroken")
        }
    }
}

/// 调用上下文（避免 service 方法签名爆炸）。
struct ReadmeTranslationRequest: Sendable {
    var repo: Repo
    var sourceHtml: String
    var targetLanguage: ReadmeTranslationLanguage
}

@MainActor
final class ReadmeTranslationService {

    private let translationRepository: any ReadmeTranslationRepositoryProtocol
    private let settings: AppSettings
    private let keychain: any KeychainManaging

    init(
        translationRepository: any ReadmeTranslationRepositoryProtocol,
        settings: AppSettings,
        keychain: any KeychainManaging = KeychainManager.shared
    ) {
        self.translationRepository = translationRepository
        self.settings = settings
        self.keychain = keychain
    }

    // MARK: - 公开接口

    /// 读取已缓存的翻译。
    ///
    /// 返回逻辑：
    /// - 缓存不存在 → nil；
    /// - 缓存存在但 `source_hash` 不匹配当前 `sourceHtml` → 仍返回缓存（让 UI 显示
    ///   旧译文并提示"原 README 已更新，建议重新翻译"），由上层 ViewModel 用
    ///   `isCacheFresh(...)` 决定是否提示用户。
    func cachedTranslation(
        repoId: Int64,
        targetLanguage: ReadmeTranslationLanguage
    ) async throws -> ReadmeTranslation? {
        try await translationRepository.find(
            repoId: repoId,
            targetLanguage: targetLanguage.rawValue
        )
    }

    /// 判断已缓存的翻译是否仍与当前源 HTML 对齐。
    nonisolated func isCacheFresh(
        cached: ReadmeTranslation,
        sourceHtml: String
    ) -> Bool {
        cached.sourceHash == Self.hash(sourceHtml)
    }

    /// 翻译并写缓存。
    ///
    /// - Parameter request: 包含 repo / sourceHtml / targetLanguage。
    /// - Parameter onDelta: 流式 token 累积值回调（已包含到目前为止的全部内容），
    ///   `nil` 时走非流式路径。
    /// - Throws: `ReadmeTranslationError` 或底层 `AIClientError`。
    /// - Returns: 新写入的 `ReadmeTranslation` 记录（同时已 upsert 到本地表）。
    func translate(
        request: ReadmeTranslationRequest,
        onDelta: (@MainActor (String) -> Void)? = nil
    ) async throws -> ReadmeTranslation {
        let trimmedSource = request.sourceHtml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { throw ReadmeTranslationError.emptySource }

        let task = settings.aiSummaryTask
        let (client, model) = try makeClient(task: task, fallbackModel: settings.aiChatModel)

        let systemPrompt = Self.systemPrompt(targetLanguage: request.targetLanguage)
        let userPrompt = Self.userPrompt(
            sourceHtml: trimmedSource,
            targetLanguage: request.targetLanguage
        )

        // 翻译走 chat 协议。复用 summary 的 temperature / maxToken / timeout，
        // 但**强制 text 响应**（不能要求 JSON）——README 翻译输出必须保留 HTML，
        // 包裹一层 JSON 等于二次序列化逃逸字符。
        let aiRequest = AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            history: [],
            model: model,
            parameters: task.parameters,
            responseFormat: .text
        )

        let translatedHtml = try await runChat(
            client: client,
            request: aiRequest,
            preferStream: task.parameters.streamEnabled,
            onDelta: onDelta
        )

        let trimmedOutput = translatedHtml.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = Self.stripFenceWrapping(trimmedOutput)
        try Self.assertStructureNotBroken(source: trimmedSource, translated: cleaned)

        let record = ReadmeTranslation(
            repoId: request.repo.id,
            targetLanguage: request.targetLanguage.rawValue,
            model: model,
            sourceHash: Self.hash(trimmedSource),
            translatedHtml: cleaned,
            size: cleaned.utf8.count,
            createdAt: ISO8601DateFormatter.shared.string(from: Date())
        )

        try await translationRepository.upsert(record)
        return record
    }

    // MARK: - 内部：AI 调用

    /// 构造 `AIClientProtocol` 实例与最终使用的 model 名。
    ///
    /// 与 `RepoAIInsightService.makeClient` 逻辑一致：复用 aiSummaryTask 选择的
    /// provider/model，从 keychain 加载该 profile 的 API Key（local provider 允许空）。
    private func makeClient(
        task: AIModelTaskConfiguration,
        fallbackModel: String
    ) throws -> (any AIClientProtocol, String) {
        guard let profile = settings.aiProviderProfiles.first(where: { $0.id == task.providerID }) else {
            throw ReadmeTranslationError.missingProvider
        }
        let apiKey = (try? keychain.loadAIKey(forProvider: profile.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || profile.provider.allowsEmptyAPIKey else {
            throw ReadmeTranslationError.missingAPIKey
        }
        let model = resolvedModelName(task: task, fallback: fallbackModel)

        let client = try OpenAIClient(configuration: AIClientConfiguration(
            providerID: profile.id,
            provider: profile.provider,
            apiKey: apiKey,
            baseURL: profile.baseURL,
            chatModel: model,
            embeddingModel: settings.aiEmbeddingTask.resolvedModelName,
            timeoutInterval: task.parameters.timeoutSeconds
        ))
        return (client, model)
    }

    private func resolvedModelName(task: AIModelTaskConfiguration, fallback: String) -> String {
        let candidate = task.resolvedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? fallback : candidate
    }

    /// 跑一次 chat（流式 / 非流式）并返回完整文本。
    private func runChat(
        client: any AIClientProtocol,
        request: AIChatRequest,
        preferStream: Bool,
        onDelta: (@MainActor (String) -> Void)?
    ) async throws -> String {
        if preferStream {
            var accumulated = ""
            for try await event in client.chatStream(request: request) {
                switch event {
                case .delta(let delta):
                    accumulated += delta
                    onDelta?(accumulated)
                case .completed(let response):
                    return response.content
                }
            }
            guard !accumulated.isEmpty else { throw AIClientError.emptyResponse }
            return accumulated
        } else {
            let response = try await client.chat(request: request)
            return response.content
        }
    }

    // MARK: - Prompt 构造

    /// 翻译用 system prompt。
    ///
    /// 设计：
    /// - **角色明确**：「README 翻译专用」，让模型知道任务是翻译而非总结/重写；
    /// - **结构约束** 用 5 条最高优先级 negative 指令，覆盖最常见的破坏点
    ///   （改 tag / 翻译属性 / 翻译代码 / 翻译 URL / 加包裹 fence）；
    /// - **少即是多**：第一版不试图教模型怎么处理「锚点 link 文本应翻译但 href 不动」
    ///   这种微妙边界——给一条「保留所有 HTML 标签和属性原样」就够覆盖 95% 场景。
    /// - 必须用英文写：跨 provider（DeepSeek / OpenRouter / Ollama / LM Studio）
    ///   对中文 prompt 的解析差异比英文 prompt 大；翻译目标语言通过 `promptName` 传入。
    nonisolated static func systemPrompt(targetLanguage: ReadmeTranslationLanguage) -> String {
        """
        You are Starcat's README translation engine.
        Translate the provided GitHub README HTML fragment into \(targetLanguage.promptName).

        STRICT RULES (failure to follow renders the output unusable):
        - Output the translated HTML fragment ONLY. Do not add prose, comments, or explanations before or after.
        - Do NOT wrap the result in markdown fences such as ```html ... ``` or ``` ... ```.
        - Preserve every HTML tag, attribute, attribute value, id, class, href, src exactly as-is. Do not rename, reorder, or remove tags.
        - Do NOT translate text inside <code>, <pre>, or anything that looks like source code, shell commands, file paths, environment variables, or URLs.
        - Do NOT translate proper nouns: project names, library names, API endpoints, branch names, version strings.
        - Translate ONLY user-visible natural language text nodes (paragraphs, headings, list items, table cells, blockquotes, captions, button labels).
        - Keep emoji and inline icons untouched.
        - Keep the total number of HTML tags identical to the source.
        """
    }

    /// 用户消息正文：直接附原 HTML 片段。
    ///
    /// 不再重复语言要求（system prompt 已强调），避免模型把指令和待翻译内容混淆。
    nonisolated static func userPrompt(sourceHtml: String, targetLanguage: ReadmeTranslationLanguage) -> String {
        """
        Translate the README fragment below into \(targetLanguage.promptName).
        Return the translated HTML fragment only.

        <README_FRAGMENT>
        \(sourceHtml)
        </README_FRAGMENT>
        """
    }

    // MARK: - 输出清洗 / 结构校验

    /// 去掉模型偶尔加上的 ```html / ``` 围栏，避免把围栏当 HTML 渲染。
    ///
    /// 即便 system prompt 已经禁止，部分模型在长输出时仍会习惯性套一层；
    /// 这里做一次幂等剥离比反复改 prompt 更鲁棒。
    nonisolated static func stripFenceWrapping(_ text: String) -> String {
        var result = text
        let lower = result.lowercased()
        // 仅在以 ``` 开头并以 ``` 结尾时才剥（避免误吞内嵌的代码围栏）
        if lower.hasPrefix("```") {
            if let firstNewline = result.firstIndex(of: "\n") {
                result.removeSubrange(result.startIndex...firstNewline)
            } else {
                result.removeSubrange(result.startIndex..<result.index(result.startIndex, offsetBy: 3))
            }
        }
        if result.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("```") {
            if let range = result.range(of: "```", options: [.backwards]) {
                result.removeSubrange(range.lowerBound..<result.endIndex)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 结构破坏粗检。
    ///
    /// 思路：统计源与译文里 `<` 字符的出现次数（HTML 标签起始符的近似指标），
    /// 若译文相对源减少超过 30% 就视作结构被破坏（模型擅自删/合并/翻译了标签）。
    /// 30% 阈值是经验值：少量误差（如模型把 `<br>` 变成 `<br />`）容忍；大幅减少
    /// （如把整段 `<ul><li>` 改成中文段落）拦截。
    ///
    /// 故意不用 `>` / `</` 联合判定：HTML 中 `>` 还会出现在 alert blockquote 等内联
    /// 文本，统计噪声更大。
    nonisolated static func assertStructureNotBroken(source: String, translated: String) throws {
        let sourceTagOpens = source.filter { $0 == "<" }.count
        guard sourceTagOpens > 0 else { return } // 纯文本 README（极少见），跳过校验
        let translatedTagOpens = translated.filter { $0 == "<" }.count
        let retention = Double(translatedTagOpens) / Double(sourceTagOpens)
        if retention < 0.7 {
            throw ReadmeTranslationError.structureBroken
        }
    }

    /// SHA256 十六进制串，用于 `source_hash` 字段。
    nonisolated static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
