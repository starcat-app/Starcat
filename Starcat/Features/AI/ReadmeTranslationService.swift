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
//  **任务配置独立于摘要**（HOM-68 follow-up 2026-06-05）：
//  - 用户在设置页里可以为「README 翻译」单独选择 provider + model + 参数（与摘要 /
//    推荐标签 / 向量 三类并列），所以本 service 读 `settings.aiTranslationTask`，
//    而不是把摘要任务的配置二次借用；
//  - 首次升级时 AppSettings.init 会把翻译任务的默认 provider/model 与摘要对齐
//    （但参数走 `AIModelParameters.translationDefault` —— 更低温度 + 更大 maxToken，
//    适合"保结构、不发挥"的翻译场景）；
//  - chat client 构造仍与 RepoAIInsightService 同一套（按 providerID 查 profile +
//    按 profile 取 keychain API Key），但 RepoAIInsightService 把 makeClient 设为
//    private 且 system prompt 完全是"摘要专用"，所以这里维持独立实现。
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
            return String.l10n("readme.translate.error.missingProvider")
        case .missingAPIKey:
            return String.l10n("readme.translate.error.missingAPIKey")
        case .emptySource:
            return String.l10n("readme.translate.error.emptySource")
        case .structureBroken:
            return String.l10n("readme.translate.error.structureBroken")
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
    private let entitlementGate: EntitlementGate?

    init(
        translationRepository: any ReadmeTranslationRepositoryProtocol,
        settings: AppSettings,
        entitlementGate: EntitlementGate? = nil,
        keychain: any KeychainManaging = KeychainManager.shared
    ) {
        self.translationRepository = translationRepository
        self.settings = settings
        self.keychain = keychain
        self.entitlementGate = entitlementGate
    }

    // MARK: - 公开接口

    /// 读取已缓存的翻译。
    ///
    /// 返回逻辑：
    /// - 缓存不存在 → nil；
    /// - 缓存存在但 `source_hash` 不匹配当前 `sourceHtml` → 仍返回缓存（让 UI 显示
    ///   旧译文并提示"原 README 已更新，建议重新翻译"），由上层 ViewModel 用
    ///   `isCacheFresh(...)` 决定是否提示用户。
    ///
    /// **签名变更（HOM-68 v2 / 2026-06-15）**：`repoId` 改为 `owner / repo`。背景
    /// 见 `ReadmeTranslationRepositoryProtocol` 顶部注释——磁盘 cache 路径用 owner/
    /// repo 而非 repo_id，让 trending / activity 这类 ephemeral repo（id 不稳定）
    /// 也能正确命中。
    func cachedTranslation(
        owner: String,
        repo: String,
        targetLanguage: ReadmeTranslationLanguage
    ) async throws -> ReadmeTranslation? {
        try await translationRepository.find(
            owner: owner,
            repo: repo,
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
        try entitlementGate?.requirePro(.readmeTranslation)
        let trimmedSource = request.sourceHtml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSource.isEmpty else { throw ReadmeTranslationError.emptySource }

        // HOM-68 follow-up：翻译任务有独立配置，不再借用摘要任务。
        let task = settings.aiTranslationTask
        let (client, model) = try makeClient(task: task, fallbackModel: settings.aiChatModel)

        // HOM-68 follow-up v2 (2026-06-05 22:30)：prompt 从 task 配置读，
        // 用户可在 设置 → AI → Prompt 区改；service 只负责按目标语言渲染占位符
        // + 结构校验 / fence 剥离等后处理，承担"安全网"角色。
        let prompt = Self.effectivePromptConfiguration(task.prompt)
        let systemPrompt = Self.renderTemplate(
            prompt.systemPrompt,
            targetLanguage: request.targetLanguage,
            sourceHtml: trimmedSource
        )
        let userPrompt = Self.renderTemplate(
            prompt.userPromptTemplate,
            targetLanguage: request.targetLanguage,
            sourceHtml: trimmedSource
        )

        // 翻译走 chat 协议。复用 summary 的 temperature / maxToken / timeout，
        // 但**强制 text 响应**（不能要求 JSON）——README 翻译输出必须保留 HTML，
        // 包裹一层 JSON 等于二次序列化逃逸字符。
        // HOM-68 follow-up v9：从 model descriptor 拿覆盖参数（若设过），
        // 否则按 capability 默认；任务粒度的 task.parameters 仅做最终兜底。
        let effectiveParams = settings.effectiveParameters(for: task)

        let aiRequest = AIChatRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            history: [],
            model: model,
            parameters: effectiveParams,
            responseFormat: .text
        )

        let translatedHtml = try await runChat(
            client: client,
            request: aiRequest,
            preferStream: effectiveParams.streamEnabled,
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

        // 写入磁盘缓存：路径用 `<owner>/<repo>/<lang>.{html,json}`（HOM-68 v2 / 砍 DB
        // 走纯磁盘后，写入不再受 FK 约束 → trending / activity 未 star 也能命中缓存）。
        try await translationRepository.upsert(
            record,
            owner: request.repo.owner,
            repo: request.repo.name
        )
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
            timeoutInterval: settings.effectiveParameters(for: task).timeoutSeconds
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
                case .reasoningDelta, .reasoningCompleted, .toolCallDelta, .usage:
                    continue
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

    // MARK: - Prompt 构造（HOM-68 follow-up v2）

    /// 占位符：将被替换为 `ReadmeTranslationLanguage.promptName`（如 `Simplified Chinese`）。
    ///
    /// 标 `nonisolated` 与下面 `renderTemplate` 一致：纯字符串常量，无任何 actor
    /// 状态依赖，在 Swift 6 严格隔离下，被 `nonisolated` 函数引用必须是 nonisolated。
    nonisolated static let targetLanguagePlaceholder = "{targetLanguage}"

    /// 占位符：将被替换为源 README HTML 片段。
    ///
    /// **2026-06-14 v2 重命名**：原 `{context}` → `{readmeHTML}`，原因：
    /// - 业务化命名，与 Tags / Embedding 重构对齐（每个任务局部命名空间）；
    /// - 与 user prompt 中的 `<README_FRAGMENT>` 包裹标签语义呼应；
    /// - 区别于 summary 任务的 `{context}`，避免用户在不同任务间复用模板时混淆。
    /// pre-launch 直接换名，不做兼容（详见 `AIDefaultPrompts.translation` 注释）。
    nonisolated static let readmeHTMLPlaceholder = "{readmeHTML}"

    /// 替换 prompt 模板里的 `{targetLanguage}` / `{readmeHTML}` 占位符。
    ///
    /// 与 `AIPromptConfiguration.renderedUserPrompt(context:)` 同等地位，
    /// 但翻译比摘要 / 标签多一个目标语言变量，所以这里独立一份 renderer。
    /// 故意不写到 `AIPromptConfiguration` 上：那样会污染摘要 / 标签的 API，
    /// 而它们根本没有目标语言概念。
    nonisolated static func renderTemplate(
        _ template: String,
        targetLanguage: ReadmeTranslationLanguage,
        sourceHtml: String
    ) -> String {
        template
            .replacingOccurrences(of: targetLanguagePlaceholder, with: targetLanguage.promptName)
            .replacingOccurrences(of: readmeHTMLPlaceholder, with: sourceHtml)
    }

    /// 从用户设置中取出有效 prompt 配置，必要时回退到 `AIDefaultPrompts.translation`。
    ///
    /// 触发回退条件：system 或 user prompt 任一为空（trim 后）。这是"用户误清空"
    /// 安全网——若用户在设置页把 system 或 user prompt 改成空白，回退到默认能让翻译
    /// 继续可用，避免以"空 system prompt + 只发原文"的方式调用 LLM 拿到破坏结构的输出。
    nonisolated static func effectivePromptConfiguration(
        _ prompt: AIPromptConfiguration
    ) -> AIPromptConfiguration {
        let trimmedSystem = prompt.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = prompt.userPromptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSystem.isEmpty || trimmedUser.isEmpty {
            return AIDefaultPrompts.translation
        }
        return prompt
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
