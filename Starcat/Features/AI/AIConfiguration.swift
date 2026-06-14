//
//  AIConfiguration.swift
//  Starcat
//
//  AI 配置领域模型。
//
//  模块职责：
//  - 描述 Starcat 设置页里的多个 AI provider profile；
//  - 描述 provider 下可启用 / 禁用的模型列表；
//  - 描述摘要、推荐标签、Embedding 三类任务各自使用的模型、参数和 Prompt。
//
//  关键约束：
//  - 这些模型只保存非敏感配置。API Key 由 `KeychainManager` 按 profile ID 单独加密保存。
//  - 第一版继续使用 OpenAI-compatible 协议；不同 provider 的差异通过默认值和模型列表解析收口。
//  - Prompt 使用 `{context}` 占位符，运行时由业务层替换为 repo 元数据 / README 上下文。
//

import Foundation

/// AI 模型能力。
enum AIModelCapability: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat
    case embedding
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chat:      return "Chat"
        case .embedding: return "Embedding"
        case .unknown:   return "Unknown"
        }
    }

    /// 根据模型名做保守推断。
    ///
    /// OpenAI-compatible 的 `/models` 返回没有统一 capability schema，OpenRouter 会给
    /// architecture，LM Studio / Ollama 又只返回本地模型名。这里仅用于初始填充 UI，
    /// 用户仍可在设置页手动修正。
    static func inferred(from modelName: String) -> AIModelCapability {
        let lower = modelName.localizedLowercase
        if lower.contains("embedding")
            || lower.contains("embed")
            || lower.contains("nomic")
            || lower.contains("bge")
            || lower.contains("text-embedding") {
            return .embedding
        }
        return .chat
    }
}

/// Provider 测试状态。
enum AIProviderTestStatus: Codable, Equatable, Sendable {
    case notTested
    case success(modelCount: Int)
    case failed(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case modelCount
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "success":
            self = .success(modelCount: try container.decode(Int.self, forKey: .modelCount))
        case "failed":
            self = .failed(try container.decode(String.self, forKey: .message))
        default:
            self = .notTested
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notTested:
            try container.encode("notTested", forKey: .kind)
        case .success(let modelCount):
            try container.encode("success", forKey: .kind)
            try container.encode(modelCount, forKey: .modelCount)
        case .failed(let message):
            try container.encode("failed", forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }

    var displayText: String {
        switch self {
        case .notTested:
            return "未测试"
        case .success(let modelCount):
            return "连接正常，发现 \(modelCount) 个模型"
        case .failed(let message):
            return message
        }
    }

    /// 是否已经通过连接测试。
    ///
    /// 设置页把“支持的服务商草稿”和“已配置好的可调用服务商”分开展示；只有测试成功
    /// 的 profile 才能进入正式列表和任务模型选择，避免未验证配置污染真实 AI 调用链。
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// Provider 下的模型描述。
struct AIModelDescriptor: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var providerID: String
    var name: String
    var ownedBy: String?
    var capability: AIModelCapability
    var isEnabled: Bool
    var isCustom: Bool
    /// HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
    /// 模型粒度的参数覆盖。`nil` 表示走 `AIModelParameters.defaults(for: capability)`，
    /// 非 `nil` 时这份覆盖会被 `AppSettings.effectiveParameters(for:)` 在任务调用时
    /// 拉取使用。可空 + 默认 nil 让 Codable 解码老版本数据自动落到"未覆盖"状态。
    var parameters: AIModelParameters?

    init(
        id: String? = nil,
        providerID: String,
        name: String,
        ownedBy: String? = nil,
        capability: AIModelCapability? = nil,
        isEnabled: Bool = true,
        isCustom: Bool = false,
        parameters: AIModelParameters? = nil
    ) {
        self.providerID = providerID
        self.name = name
        self.id = id ?? "\(providerID)::\(name)"
        self.ownedBy = ownedBy
        self.capability = capability ?? AIModelCapability.inferred(from: name)
        self.isEnabled = isEnabled
        self.isCustom = isCustom
        self.parameters = parameters
    }
}

/// 一个可调用的 AI 服务商配置。
struct AIProviderProfile: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var provider: AIServiceProvider
    var displayName: String
    var baseURL: String
    var isEnabled: Bool
    var models: [AIModelDescriptor]
    var lastTestedAt: String?
    var lastTestStatus: AIProviderTestStatus

    init(
        id: String = UUID().uuidString,
        provider: AIServiceProvider,
        displayName: String? = nil,
        baseURL: String? = nil,
        isEnabled: Bool = true,
        models: [AIModelDescriptor] = [],
        lastTestedAt: String? = nil,
        lastTestStatus: AIProviderTestStatus = .notTested
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName ?? provider.defaultProfileName
        self.baseURL = baseURL ?? provider.defaultBaseURL
        self.isEnabled = isEnabled
        self.models = models
        self.lastTestedAt = lastTestedAt
        self.lastTestStatus = lastTestStatus
    }

    /// 是否可作为正式 AI 服务商使用。
    ///
    /// `isEnabled` 表示用户是否启用该配置；`lastTestStatus.isSuccess` 表示这份配置至少
    /// 通过过一次模型列表测试。两者同时满足才进入第一行“已配置服务商”和任务模型下拉。
    var isVerifiedConfiguration: Bool {
        isEnabled && lastTestStatus.isSuccess
    }
}

/// Starcat 内置 AI 任务。
///
/// HOM-68 (2026-06-05) 追加 `.translation`：dong4j 反馈"摘要 / 推荐标签 / 向量 三类
/// 模型分别配置，那 README 翻译也需要独立一栏，让用户可选不同 provider/model"。
/// 翻译复用 chat capability，但参数（temperature / maxToken / timeout）独立于摘要，
/// 因为译文质量需要更低温度 + 更高 max tokens（长 README 翻译后体积可能涨 20–50%）。
///
/// 2026-06-14 v4 追加 `.chat`：对话路径之前直接复用 `aiSummaryTask` 的 model + 参数，
/// system prompt 在 `RepoAIInsightService.assembleChatSystemPrompt` 里硬编码拼接，
/// 用户没法编辑、Settings 看不见。本次让 chat 也走标准 task 配置 + 占位符模板路径
/// （6 占位符：`{outputLanguage}` / `{metadata}` / `{readme}` / `{codeContext}` /
/// `{summary}` / `{externalContext}`），跟其他 4 个任务一致。userPromptTemplate
/// 留空（跟 embedding 镜像）—— 用户消息直接走 `AIChatRequest.history` + `userMessage`，
/// 不需要模板包装。
enum AIModelTask: String, Codable, CaseIterable, Identifiable, Sendable {
    case summary
    case tags
    case embedding
    case translation
    case chat

    var id: String { rawValue }

    /// HOM-126 follow-up (dong4j 反馈 2026-06-07，「模型配置」/「Prompt」segmented picker 显得拥挤)：
    /// 任务名收紧为单字/双字，避免在 4 个 tab 横排的 segmented picker 里被截断。
    /// 业务语义对齐：摘要 = 仓库 AI 摘要；标签 = 自动推荐 + 应用标签；向量化 = embedding 索引；翻译 = README 翻译；对话 = 详情页 AI 助手。
    var displayName: String {
        switch self {
        case .summary:     return "摘要"
        case .tags:        return "标签"
        case .embedding:   return "向量化"
        case .translation: return "翻译"
        case .chat:        return "对话"
        }
    }

    var requiredCapability: AIModelCapability {
        switch self {
        case .summary, .tags, .translation, .chat: return .chat
        case .embedding:                           return .embedding
        }
    }
}

/// 单个 AI 任务的模型参数。
struct AIModelParameters: Codable, Equatable, Sendable {
    var temperature: Double
    var topP: Double
    var topK: Int
    var maxCompletionTokens: Int
    var timeoutSeconds: Double
    var streamEnabled: Bool

    // HOM-68 follow-up v3 (dong4j 反馈 2026-06-05 22:40)：把所有 chat 任务的
    // maxCompletionTokens 默认值统一上调到 128K（= 128 * 1024 = 131_072 tokens）。
    // 设置 UI 已经把"最大 Token"按 K 显示输入（131_072 / 1024 = 128 K），上限按
    // 现代 long-context 模型给到 512K，避免用户在 OpenAI / 通义千问 / Gemini 等
    // 不同 provider 间频繁手调。
    //
    // 这只影响首次启动的 seed 值，已有用户的 persisted 配置不会被覆盖。

    static let summaryDefault = AIModelParameters(
        temperature: 0.2,
        topP: 0.9,
        topK: 40,
        maxCompletionTokens: 128 * 1024,
        timeoutSeconds: 300,
        streamEnabled: true
    )

    static let tagsDefault = AIModelParameters(
        temperature: 0.1,
        topP: 0.8,
        topK: 40,
        maxCompletionTokens: 128 * 1024,
        timeoutSeconds: 180,
        streamEnabled: false
    )

    static let embeddingDefault = AIModelParameters(
        temperature: 0,
        topP: 1,
        topK: 0,
        maxCompletionTokens: 0,
        timeoutSeconds: 300,
        streamEnabled: false
    )

    /// HOM-68：README 翻译默认参数。
    /// - temperature 0.1：翻译需要稳定输出，不要"创造性发挥"；比摘要的 0.2 再低一档。
    /// - maxCompletionTokens 128K：README 译文体积可能比原文大 20-50%（中→英尤其明显），
    ///   翻译截断会破坏 HTML 结构（assertStructureNotBroken 直接拦截，用户会看到失败），
    ///   所以默认就给到 long-context 模型的上限段，避免按需手调。
    /// - timeoutSeconds 600：长 README 流式翻译可能超过 5 分钟，特别是本地 LM Studio / Ollama。
    /// - streamEnabled true：与摘要一致，给用户进度反馈，避免长时间无响应。
    static let translationDefault = AIModelParameters(
        temperature: 0.1,
        topP: 0.9,
        topK: 40,
        maxCompletionTokens: 128 * 1024,
        timeoutSeconds: 600,
        streamEnabled: true
    )

    /// HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：模型粒度参数引入后，
    /// `AIModelDescriptor.parameters == nil` 时需要一份"按能力分类"的默认参数兜底。
    /// chat / unknown 用 summaryDefault（128K maxToken / 0.2 温度 / 300s 超时 / 流式 on），
    /// embedding 用 embeddingDefault（不需要温度 / maxToken 等 chat 字段）。
    ///
    /// 历史的 `AIModelTaskConfiguration.parameters` 仍保留（作为 effectiveParameters
    /// 找不到 descriptor 时的二级 fallback），但 UI 已不再暴露任务粒度的参数编辑。
    static func defaults(for capability: AIModelCapability) -> AIModelParameters {
        switch capability {
        case .embedding: return .embeddingDefault
        case .chat, .unknown: return .summaryDefault
        }
    }
}

/// Prompt 配置。
///
/// **占位符渲染**（`render` 函数）：
/// - 入参 `placeholders` 是任务私有 dict（key 不带花括号），渲染时将
///   `{key}` 替换为 dict 中的 value；
/// - 每个任务的占位符**互不共享**——Tags 任务用的 `{repository.metadata}` /
///   `{tags.repo}` / `{output.language}` 等占位符是 Tags 任务局部命名空间，
///   Summary / Translation 等其它任务即便出现同名占位符也是各自局部语义；
/// - 模板中**未在 dict 中找到**的占位符**保留原文**，便于 LLM 直接看到字面量
///   反推用户写错了哪个 key（不静默吞 / 不替换为空字符串）。
struct AIPromptConfiguration: Codable, Equatable, Sendable {
    var systemPrompt: String
    var userPromptTemplate: String

    /// 用 `placeholders` dict 渲染 `userPromptTemplate`，把 `{key}` 替换为对应 value。
    func renderedUserPrompt(placeholders: [String: String]) -> String {
        Self.render(template: userPromptTemplate, placeholders: placeholders)
    }

    /// 用 `placeholders` dict 渲染 `systemPrompt`。
    /// 仅当任务有 system 层占位符（如 Tags 的 `{output.language}`）时由调用方使用。
    func renderedSystemPrompt(placeholders: [String: String]) -> String {
        Self.render(template: systemPrompt, placeholders: placeholders)
    }

    /// 通用模板渲染：把 `{key}` 替换为 dict 中对应 value。
    /// dict 中没有的 key 保留 `{key}` 原文（不替换为空字符串）。
    static func render(template: String, placeholders: [String: String]) -> String {
        var result = template
        for (key, value) in placeholders {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}

/// 单个任务的 provider/model/prompt/参数配置。
struct AIModelTaskConfiguration: Codable, Equatable, Sendable {
    var providerID: String
    var modelID: String
    var customModelName: String
    var useCustomModel: Bool
    var parameters: AIModelParameters
    var prompt: AIPromptConfiguration

    var resolvedModelName: String {
        useCustomModel ? customModelName : modelID
    }
}

/// AI Prompt 默认值集中地。
enum AIDefaultPrompts {
    /// Summary 任务占位符（dong4j 2026-06-14 v4.x 拍板，i18n 策略 C：全英文指令 + Locale 仅控输出语言）：
    ///
    /// **system 层**：
    /// - `{outputLanguage}`：跟 `Locale.current` 派发为 `Simplified Chinese` / `English` /
    ///   `Japanese` 等；驱动正文语言（技术英文专有名词除外）。
    ///
    /// **user 层**：
    /// - `{outputLanguage}`：复用同一个值；驱动章节标题语言（不再是硬编码中文 `## 一句话总结`）。
    /// - `{metadata}`：repo 元数据（fullName / description / language / topics / stars / license 等）；
    /// - `{readme}`：清洗 + 截断后的 README 纯文本；
    /// - `{codeContext}`：RepoContextPacker 生成的代码 XML（无则空字符串）；
    /// - `{externalContext}`：AnySearchContextProvider 生成的外部检索 markdown（带
    ///   `<external_context trust="untrusted">` 包裹，无则空字符串）。
    ///
    /// **2026-06-14 v4.x 重构**（dong4j 拍板）：
    /// 1. 砍掉旧 v3 的硬编码 `Use Simplified Chinese`，统一走 `{outputLanguage}` i18n 派发；
    /// 2. 把单一黑盒 `{context}` 拆成 4 个透明占位符（metadata / readme / codeContext /
    ///    externalContext），用户在 Settings 看得见、也能删；
    /// 3. 把"6 个固定 ## 章节强制必填"改成"7 个推荐章节 + 有信息则写、无信息则省"，
    ///    避免模型在无信息时硬编内容；唯一硬约束是「Overview」必须有内容（UI 端从摘要
    ///    开头提取项目预览，没内容会破坏卡片渲染）；
    /// 4. 加强 LLM 输出约束：禁 `<think>` / `<thinking>` 等推理痕迹 XML、禁外层
    ///    ``` 围栏整篇包裹、内部代码必须 fenced + 标语言、禁套话；
    /// 5. 输入材料（Input Materials）放在 user prompt 末尾，利用 LLM recency bias。
    ///
    /// **删占位符 = 不注入对应数据**：用户在 Settings 改默认 prompt 把某个占位符删掉，
    /// service 层就不渲染对应内容；改坏了点 Restore Default 还原。
    /// 占位符在 dict 中查不到时保留原文（让 LLM 看到字面量便于排错，不静默吞）。
    ///
    /// **`{externalContext}` 的 trust 处理**：AnySearch 来自互联网，可能含恶意 prompt
    /// injection；markdown 自带 `<external_context trust="untrusted">` 包裹和警告语
    /// （详见 `AnySearchContextProvider.swift`），prompt 模板这一层不再重复声明。
    static let summary = AIPromptConfiguration(
        systemPrompt: """
        You are Starcat's repository summary assistant, helping developers quickly understand a project and assess its value.

        # Output Format (STRICT)
        - Write the final answer in message.content only, using Markdown format (no plain text, no JSON).
        - Do NOT wrap the entire summary in an outer ``` fence; however, code examples, shell commands, configuration snippets, API calls, and similar within the summary MUST be wrapped in ``` fences with a language tag (e.g. ```bash, ```js, ```yaml, ```python, ```swift). Do not use indented code blocks or plain text to represent code.
        - Do NOT output reasoning, analysis traces, or thought processes.
        - Do NOT include <think>, <thinking>, <reasoning>, or other reasoning-trace XML tags; if your model has a thinking stage, return only the final answer.
        - Output language: {outputLanguage} (use this language for the body; technical English proper nouns are excluded — see the next constraint).

        # Factual Constraints
        - Do NOT fabricate facts beyond what is provided in the metadata, README, or code context.
        - Skip content that cannot be confirmed from the input materials. Do NOT write "unconfirmed" placeholders, and do NOT fabricate content just to fill out sections.
        - Preserve technical English proper nouns as-is (library names, command names, framework names, API names, version strings, commit hashes, etc.) — do not force-translate them.
        """,
        userPromptTemplate: """
        Generate a Markdown summary in {outputLanguage} based on the GitHub repository input materials below, helping developers quickly judge whether the project is worth further investigation.

        # Output Guidelines

        Output the following sections in order (use {outputLanguage} for section titles — the examples below are in English; write a section only when you have information for it, otherwise skip the entire section; you may add additional important sections as the context warrants):

        ## Overview
        Describe the project's positioning, goals, and the problem it solves. **This section MUST have content — the UI extracts the project preview from the beginning of the summary.**

        ## Core Capabilities
        Summarize the project's main features, capabilities, or technical strengths.

        ## Use Cases
        Describe what real-world problems the project addresses and which developers or teams it suits.

        ## Tech Ecosystem
        Describe the platforms, programming languages, frameworks, runtime environments, or related ecosystem the project uses.

        ## Strengths
        Summarize the project's highlights, distinctive features, or advantages over similar solutions.

        ## Risks & Limitations
        Describe known limitations, maintenance status, compatibility issues, or things to watch out for.

        ## Minimal Example
        Provide a minimal example only when a reliable one exists in the README or code context; otherwise omit this section. Code MUST be wrapped in ``` fences with a language tag.

        # Writing Requirements
        - Use natural, concise, professional technical language.
        - Do NOT copy entire passages from the README verbatim; paraphrase in your own words.
        - Do NOT fabricate information not present in the input materials; if something cannot be confirmed, simply omit it.
        - Do NOT close with boilerplate like "in summary", "to conclude", or similar.
        - Preserve technical terms, framework names, command names, and English proper nouns as-is.

        # Input Materials

        ## Metadata
        {metadata}

        ## README
        {readme}

        ## Code Context
        {codeContext}

        ## External References
        {externalContext}
        """
    )

    /// Tags 任务私有占位符（dong4j 2026-06-14 拍板，i18n 策略 C：全英文指令 + Locale 仅控输出语言）：
    ///
    /// **system 层**：
    /// - `{outputLanguage}`：跟 `Locale.current` 派发为 `Simplified Chinese` / `English` /
    ///   `Japanese` 等；驱动 Tag Style Rules 分支选择 + reason 字段语言。
    ///
    /// **user 层**：
    /// - `{metadata}`：repo 元数据（fullName / description / language / topics 等）；
    /// - `{readme}`：清洗 + 截断后的 README 纯文本；
    /// - `{codeContext}`：RepoContextPacker 生成的代码 XML（无则空字符串）；
    /// - `{repoTags}`：当前仓库已绑定标签（强信号，逗号分隔，不带 label）；
    /// - `{libraryTags}`：用户标签库高频前 30 个（弱信号，逗号分隔，不带 label）。
    ///
    /// **2026-06-14 v2 重命名**（dong4j 拍板，方案 C 全栈占位符归一化）：
    /// 旧两段点分式 `{output.language}` / `{repository.metadata}` / `{repository.readme}` /
    /// `{repository.code_context}` / `{tags.repo}` / `{tags.library}` 重命名为单段驼峰，
    /// 跟 Embedding / Translation / Summary 任务的命名风格统一。pre-launch 直接换名，
    /// 不做 backward compat。
    ///
    /// **删占位符 = 不注入对应数据**：用户在 Settings 改默认 prompt 把某个占位符删掉，
    /// service 层就不渲染对应内容；改坏了点 Restore Default 还原。
    /// 占位符在 dict 中查不到时保留原文（让 LLM 看到字面量便于排错，不静默吞）。
    static let tags = AIPromptConfiguration(
        systemPrompt: """
        You are Starcat's repository tagging assistant.

        # Output Format (STRICT)
        Return strict JSON only in message.content. NO prose, NO markdown fences, NO reasoning traces, NO explanations outside the JSON.

        Schema (failure to match this schema will cause the output to be rejected):
        {
          "suggestedTags": [
            {"name": "string", "confidence": 0.0, "reason": "string"}
          ]
        }

        Constraints:
        - "confidence" MUST be a number in the closed interval [0, 1].
        - "name" MUST be short (1-3 tokens), reusable, suitable for a local tag system.
        - "reason" should be one short sentence explaining why this tag fits this repository.
        - Generate 3 to 8 tags total. NO duplicates.

        # Tag Style Rules
        Apply ONLY the branch matching {outputLanguage}:

        - If {outputLanguage} is "Simplified Chinese" or "Traditional Chinese":
          - Tag names ≤ 4 characters; nouns or short technical terms only (e.g. 「向量检索」「编辑器」「机器学习」).
          - NEVER full sentences.
          - Well-known technical English terms (e.g. RAG, LLM, GitHub, API) MAY remain in English.

        - If {outputLanguage} is "English":
          - Tag names: a single domain word, abbreviation, or common technical term (e.g. RAG, LLM, DevOps, WebRTC, Editor).
          - NEVER compound phrases or full sentences.
          - Tag names MUST be in English; do NOT include non-ASCII characters.

        - Otherwise (Japanese / Korean / others):
          - Follow the same spirit: short nouns, no sentences. Well-known technical English terms may remain in English.

        Keep style consistent within one repository's tag set.

        # Tag Source Priority
        1. If "Existing tags on this repository" is provided in the user message, REUSE them whenever applicable — generating synonyms creates duplicate tags and pollutes the user's tag library.
        2. If "Other frequently-used tags in your library" is provided, use them as STYLE / GRANULARITY reference only — do NOT force-fit them onto unrelated repositories.
        3. If neither is provided, infer tags from the repository context using the style rules above.

        # Output Language
        The "reason" field MUST be written in {outputLanguage}.
        Tag "name" field follows the Tag Style Rules above (matched against {outputLanguage}).
        """,
        userPromptTemplate: """
        Suggest 3 to 8 tags for the GitHub repository described below.

        Repository metadata:
        {metadata}

        README:
        {readme}

        Code structure:
        {codeContext}

        Existing tags on this repository (strong hint, prefer reuse):
        {repoTags}

        Other frequently-used tags in your library (style hint, optional):
        {libraryTags}
        """
    )

    /// 向量嵌入（embedding）任务默认 prompt（dong4j 决策 2026-06-14）。
    ///
    /// **embedding API 不接受 system prompt**——所以 `systemPrompt` 留空，运行时也不会用到。
    /// 留这个字段是为了让 UI 跟其他任务保持一致的编辑控件结构（用户能看到"系统提示词为空"
    /// 这件事，理解 embedding 不需要 system prompt）。
    ///
    /// **占位符（仅 embedding 任务局部）**：
    /// - `{fullName}` — `owner/name`
    /// - `{description}` — repo 描述（空 → 空字符串）
    /// - `{language}` — 主语言
    /// - `{topics}` — `IndexedTextBuilder.normalizeTopics()` 处理后的逗号分隔列表
    /// - `{license}` — SPDX 标识
    /// - `{homepage}` — 主页 URL
    /// - `{body}` — 三级降级主体（AI 摘要 > README 纯文本 > description+topics 兜底）
    /// - `{notes}` — 用户私有笔记
    ///
    /// **删占位符 = 不注入对应数据**：dict 里有 key 但 value 是空字符串 → 替换为空；
    /// 模板中删掉占位符那行（连同 label）→ 输出根本不渲染对应内容。
    ///
    /// **`{body}` 不拆细的原因**：三级降级是稳定性兜底（dong4j 2026-06-12 决策 D）。
    /// 如果拆成 `{summary}` / `{readme}` 让用户控制，用户写 `{summary}` 但 repo
    /// 没生成过摘要 → 输入退化为只有元数据 → 搜索效果烂。
    ///
    /// **已知约束**：用户改 prompt template 后，老 vector 是用旧 template 喂出来的，
    /// 跟新 template 不可比；diff 判定（`IndexedTextDiff.shouldRebuild`）只看
    /// `snapshot_json` 不看 prompt → 老 vector 不会自动失效。pre-launch 不处理，
    /// 上线前需补 diff 维度（snapshot_json hash + prompt template hash 双判定）。
    static let embedding = AIPromptConfiguration(
        systemPrompt: "",
        userPromptTemplate: """
        Repository: {fullName}
        Description: {description}
        Language: {language}
        Topics: {topics}
        License: {license}
        Homepage: {homepage}

        {body}

        Notes:
        {notes}
        """
    )

    /// HOM-68 follow-up（2026-06-05 22:30；2026-06-14 v2 优化）：README 翻译默认 Prompt。
    ///
    /// 之前这套 prompt 写死在 `ReadmeTranslationService.systemPrompt(targetLanguage:)` /
    /// `userPrompt(...)` 静态函数里，导致用户无法在设置页调整。HOM-68 把它抽到这里，
    /// 统一通过 `AIModelTaskConfiguration.prompt` 走，运行时 Service 负责把
    /// `{targetLanguage}` 替换为 `ReadmeTranslationLanguage.promptName`、
    /// `{readmeHTML}` 替换为源 README HTML 片段。
    ///
    /// 设计上保留"结构保真"的强约束（9 条编号 STRICT RULES + `assertStructureNotBroken`
    /// + `stripFenceWrapping` 后处理）—— 即便用户改坏了 prompt，service 的结构校验
    /// 仍会拦截大幅破坏结构的输出并保留原 README，不会污染缓存。
    ///
    /// **占位符约定**（仅 translation 任务局部命名空间）：
    /// - `{targetLanguage}` —— 必须出现在 system 或 user prompt 至少一处（否则模型不知道
    ///   要翻译成哪种语言）；service 不强校验，但运行时如果两处都缺，等于让模型自己猜。
    /// - `{readmeHTML}` —— 只能出现在 user prompt（system prompt 出现也会被替换，但语义错误）。
    ///
    /// **2026-06-14 v2 关键变更**（dong4j 决策）：
    /// 1. `{context}` → `{readmeHTML}`：业务化命名，与 Tags / Embedding 重构对齐，同时与
    ///    user prompt 中的 `<README_FRAGMENT>` 标签呼应；pre-launch 直接换名，不做兼容。
    /// 2. STRICT RULES 由 8 条 bullet 改为 9 条编号：长 prompt 中编号比 bullet 遵守度更高。
    /// 3. 新增 RULE 4（HTML 实体 `&amp;`/`&lt;`/`&#x1F4A1;` + HTML 注释 `<!-- ... -->` 保真）：
    ///    踩过的坑——模型偶尔把 `&amp;` 直接渲染成 `&` 输出，破坏 HTML 合法性。
    /// 4. 扩展 RULE 5：除 `<code>`/`<pre>` 再加 `<kbd>`/`<samp>`，覆盖 README 里键盘快捷键
    ///    和命令示例输出标签。
    /// 5. 强化 RULE 6（proper noun）：举 6 个具体例子 + "regardless of `{targetLanguage}`"，
    ///    把抽象规则变具象，对 Qwen / GLM 等小模型遵守度提升明显。
    /// 6. 新增 EXAMPLE 段：1 条 EN→zh-Hans 综合示例，覆盖"`<a>` 链接保留 / proper noun
    ///    不译 / `<code>` 不译 / `——` 中文标点本地化"4 个易错点。
    static let translation = AIPromptConfiguration(
        systemPrompt: """
        You are Starcat's README translation engine.
        Translate the provided GitHub README HTML fragment into {targetLanguage}.

        STRICT RULES (failure to follow renders the output unusable):
        1. Output the translated HTML fragment ONLY. Do not add prose, comments, or explanations before or after the fragment.
        2. Do NOT wrap the result in markdown fences such as ```html ... ``` or ``` ... ```.
        3. Preserve every HTML tag, attribute, attribute value, id, class, href, src exactly as-is. Do not rename, reorder, or remove tags.
        4. Preserve HTML entities (e.g. &amp;, &lt;, &#x1F4A1;) and HTML comments (<!-- ... -->) verbatim. Do not translate, decode, or remove them.
        5. Do NOT translate text inside <code>, <pre>, <kbd>, <samp>, or anything that looks like source code, shell commands, file paths, environment variables, or URLs.
        6. Do NOT translate proper nouns: project / library / framework / company names (React, Vue, Next.js, Tailwind CSS, GitHub, OpenAI, etc.), API endpoints, branch names, version strings, commit hashes. Keep them in the original Latin script regardless of {targetLanguage}.
        7. Translate ONLY user-visible natural language text nodes (paragraphs, headings, list items, table cells, blockquotes, captions, button labels).
        8. Keep emoji and inline icons untouched.
        9. Keep the total number of HTML tags identical to the source. Do not split or merge tags.

        EXAMPLE (English → Simplified Chinese; the same proper-noun-preservation rule applies to all target languages):
        Source:  <p>Built with <a href="https://react.dev">React</a> and Tailwind CSS — run <code>npm install</code> first.</p>
        Target:  <p>基于 <a href="https://react.dev">React</a> 与 Tailwind CSS 构建 —— 先运行 <code>npm install</code>。</p>
        """,
        userPromptTemplate: """
        Translate the README fragment below into {targetLanguage}.
        Return the translated HTML fragment only.

        <README_FRAGMENT>
        {readmeHTML}
        </README_FRAGMENT>
        """
    )

    /// Chat 任务占位符（dong4j 2026-06-14 v4 拍板，i18n 策略 C：全英文指令 + Locale 仅控输出语言）：
    ///
    /// **system 层 6 占位符**：
    /// - `{outputLanguage}`：跟 `Locale.current` 派发为 `Simplified Chinese` / `English` /
    ///   `Japanese` 等；驱动正文语言 + 兜底句"无法从上下文确认"自然翻译；
    /// - `{metadata}`：repo 元数据（fullName / description / language / topics / license / stars / forks / homepage），
    ///   与 Summary / Tags 任务共用同一份元数据块；
    /// - `{readme}`：清洗 + 截断后的 README 纯文本；
    /// - `{codeContext}`：RepoContextPacker 生成的代码 XML（关闭或拉取失败时为空字符串）；
    /// - `{summary}`：缓存命中的 AI 摘要 markdown（未生成过摘要时为空字符串）；
    /// - `{externalContext}`：AnySearch 生成的外部网页检索 markdown（关闭或拉取失败时为空字符串）。
    ///
    /// **userPromptTemplate 留空**（与 embedding 镜像）：
    /// - embedding API 不接受 system prompt → systemPrompt 留空；
    /// - chat 任务用户消息直接通过 `AIChatRequest.history` + `userMessage` 走 messages 数组，
    ///   不需要"用户输入再嵌一层 prompt 模板"，所以 userPromptTemplate 留空。
    /// - Settings UI 渲染该字段时会显示 disabled hint，跟 embedding 同款。
    ///
    /// **2026-06-14 v4 重构**（之前 chat system prompt 硬编码在
    /// `RepoAIInsightService.assembleChatSystemPrompt` 静态函数里）：
    /// 1. 砍掉旧硬编码 `Reply in Simplified Chinese only`，统一走 `{outputLanguage}` i18n 派发；
    /// 2. 砍掉旧硬编码兜底中文 `"未从 README 或仓库元数据中确认"`，改成
    ///    `say so explicitly in {outputLanguage}` 让 LLM 自然翻译；
    /// 3. 把单一黑盒 sourceText 拆成 5 个透明 section 占位符（跟 Summary v4 对齐），用户在
    ///    Settings 看得见、也能删；
    /// 4. 加强 LLM 输出约束：禁 `<think>` / `<thinking>` / `<reasoning>` 推理痕迹 XML、
    ///    禁外层 ``` 围栏整篇包裹、内部代码必须 fenced + 标语言、显式禁开场白 / 收场套话；
    /// 5. 新增独有占位符 `{summary}`（chat 独有，其他任务没有），缓存命中的 AI 摘要作为参考；
    /// 6. 新增独有占位符 `{externalContext}`，AnySearch 内容（已去掉 trust=untrusted 标记，
    ///    详见 `AnySearchContextProvider` 注释）跟 README/metadata 平等参考。
    ///
    /// **删占位符 = 不注入对应数据**：用户在 Settings 改默认 prompt 把某个占位符删掉，
    /// service 层就不渲染对应内容；改坏了点 Restore Default 还原。
    /// 占位符在 dict 中查不到时保留原文（让 LLM 看到字面量便于排错，不静默吞）。
    ///
    /// **空 section 处理**：跟 Summary v4 同款——`{codeContext}` / `{summary}` /
    /// `{externalContext}` 在 service 端 build dict 时若无数据就传空串，
    /// 渲染出空 section header（LLM 自然忽略，token 浪费 < 5/section）。
    static let chat = AIPromptConfiguration(
        systemPrompt: """
        You are Starcat's repository chat assistant, helping developers explore and understand a specific GitHub repository through conversation.

        # Output Format (STRICT)
        - Reply in Markdown format only (no plain text envelope, no JSON wrapper).
        - Do NOT wrap the entire reply in an outer ``` fence; however, code examples, shell commands, configuration snippets, API calls, and similar within the reply MUST be wrapped in ``` fences with a language tag (e.g. ```bash, ```js, ```yaml, ```python, ```swift). Do not use indented code blocks or plain text to represent code.
        - Do NOT output reasoning, analysis traces, or thought processes.
        - Do NOT include <think>, <thinking>, <reasoning>, or other reasoning-trace XML tags; if your model has a thinking stage, return only the final answer.
        - Output language: {outputLanguage} (use this language for the reply; technical English proper nouns are excluded — see the next constraint).

        # Factual Constraints
        - Stay grounded in the provided repository context (metadata + README + optional code structure + optional AI summary + optional external references).
        - Do NOT fabricate APIs, commands, file paths, links, or version numbers that are not present in the context.
        - If a question cannot be answered from the available context, say so explicitly in {outputLanguage} — do not guess. Tell the user the answer cannot be confirmed from the available materials.
        - Preserve technical English proper nouns as-is (library names, command names, framework names, API names, version strings, commit hashes, etc.) — do not force-translate them.

        # Reply Style
        - Keep replies focused on what the user asked; no padding, no boilerplate openers ("Sure!", "Great question!"), no closing summaries ("In summary, ...", "Hope this helps!").
        - When citing repository context, prefer specific references (file names, exact commands from README) over vague phrasing.
        - For multi-part questions, answer each part briefly; do not over-elaborate parts the user did not ask about.

        # Repository Context

        ## Metadata
        {metadata}

        ## README
        {readme}

        ## Code Structure
        {codeContext}

        ## AI Summary
        {summary}

        ## External References
        {externalContext}
        """,
        userPromptTemplate: ""
    )
}

extension AIServiceProvider {
    /// 创建新 profile 时的默认显示名（用户可在设置页改）。
    ///
    /// 注意：与 `AIServiceProvider.displayName` 区别——前者是 LocalizedStringKey，
    /// 用于 picker 自动 i18n；这里返回纯 `String`，是 profile 持久化字段的初始值，
    /// 故走非本地化版本（已存在配置不会因为 App 系统语言切换而改变）。
    /// 中文服务商在中文 build / 用户场景里出现概率高，名称就直接给中文；英文服务商保留品牌原名。
    var defaultProfileName: String {
        switch self {
        case .openAICompatible: return "OpenAI Compatible"
        case .deepSeek:         return "DeepSeek"
        case .openRouter:       return "OpenRouter"
        case .ollama:           return "Ollama Local"
        case .lmStudio:         return "LM Studio Local"
        case .freeai:           return "FreeAI"
        case .nvidia:           return "NVIDIA"
        case .huggingface:      return "HuggingFace"
        case .cloudflare:       return "Cloudflare Workers AI"
        case .bedrock:          return "Amazon Bedrock"
        case .azureOpenAI:      return "Azure OpenAI"
        case .githubModels:     return "GitHub Models"
        case .mistral:          return "Mistral AI"
        case .doubao:           return "豆包"
        case .grok:             return "Grok"
        case .hunyuan:          return "混元"
        case .moonshot:         return "Moonshot"
        case .qianwen:          return "通义千问"
        case .siliconflow:      return "硅基流动"
        case .iflow:            return "IFlow"
        case .modelscope:       return "ModelScope"
        case .zhipu:            return "智谱 AI"
        case .zai:              return "Z.AI"
        }
    }

    /// 是否允许 API Key 为空（本地服务用）。
    var allowsEmptyAPIKey: Bool {
        switch self {
        case .ollama, .lmStudio:
            return true
        default:
            return false
        }
    }

    var fallbackAPIKey: String {
        allowsEmptyAPIKey ? "local-ai" : ""
    }
}
