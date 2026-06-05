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
}

/// Starcat 内置 AI 任务。
///
/// HOM-68 (2026-06-05) 追加 `.translation`：dong4j 反馈"摘要 / 推荐标签 / 向量 三类
/// 模型分别配置，那 README 翻译也需要独立一栏，让用户可选不同 provider/model"。
/// 翻译复用 chat capability，但参数（temperature / maxToken / timeout）独立于摘要，
/// 因为译文质量需要更低温度 + 更高 max tokens（长 README 翻译后体积可能涨 20–50%）。
enum AIModelTask: String, Codable, CaseIterable, Identifiable, Sendable {
    case summary
    case tags
    case embedding
    case translation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .summary:     return "AI 摘要"
        case .tags:        return "推荐标签"
        case .embedding:   return "Embedding"
        case .translation: return "README 翻译"
        }
    }

    var requiredCapability: AIModelCapability {
        switch self {
        case .summary, .tags, .translation: return .chat
        case .embedding:                    return .embedding
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
struct AIPromptConfiguration: Codable, Equatable, Sendable {
    var systemPrompt: String
    var userPromptTemplate: String

    func renderedUserPrompt(context: String) -> String {
        userPromptTemplate.replacingOccurrences(of: "{context}", with: context)
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
    static let summary = AIPromptConfiguration(
        systemPrompt: """
        You are Starcat's repository summary assistant.
        Write the final answer in message.content only.
        Return Markdown only.
        Do not write reasoning, analysis traces, outer markdown fences, or JSON.
        Use Simplified Chinese.
        Do not invent facts not present in the provided metadata or README.
        """,
        userPromptTemplate: """
        请阅读下面的 GitHub 仓库上下文，生成一份适合开发者快速判断价值的中文 Markdown 摘要。

        输出要求：
        - 必须按下面的二级标题顺序输出，不要新增其它顶级章节。
        - 每个章节都要有内容；如果上下文无法确认，请明确写“未从 README 或元数据中确认”。
        - 保留技术英文名、命令名和框架名。
        - “最小示例”只有在 README 或元数据中能确认时才写代码块；不能确认时写一句说明，不要编造示例。
        - 不要输出 JSON，不要用 markdown 代码围栏包裹整篇内容。

        必须包含的 Markdown 结构：

        ## 一句话总结
        用 1 句话说明这个项目是什么，以及它解决什么问题。

        ## 这个项目是什么
        用 2-4 个短段落说明核心用途、主要能力、和同类工具相比的定位。

        ## 平台 / 生态
        - 列出语言、框架、运行平台、依赖生态或集成对象。

        ## 适合场景
        - 列出 3-6 个适合使用这个项目的场景。

        ## 优点
        - 列出 3-6 个优点或亮点。

        ## 风险与注意点
        - 列出 2-5 个风险、限制、维护状态、学习成本或接入成本。

        ## 最小示例
        给出 README 中能确认的最小使用方式；如无可靠信息，写“未从 README 或元数据中确认”。

        Repository context:
        {context}
        """
    )

    static let tags = AIPromptConfiguration(
        systemPrompt: """
        You are Starcat's repository tagging assistant.
        Return strict JSON only in message.content.
        Do not write reasoning, analysis traces, markdown fences, or explanations.
        Suggested tags must be short, reusable, and suitable for a local tag system.
        """,
        userPromptTemplate: """
        请基于下面的 GitHub 仓库上下文推荐 3 到 8 个中文或技术英文标签。

        只返回 JSON，结构必须匹配：
        {
          "suggestedTags": [
            {"name": "Swift", "confidence": 0.91, "reason": "为什么推荐这个标签"}
          ]
        }

        规则：
        - confidence 必须在 0 到 1 之间。
        - name 必须短，可复用，适合本地标签系统。
        - 不要返回 markdown。

        Repository context:
        {context}
        """
    )

    static let embedding = AIPromptConfiguration(systemPrompt: "", userPromptTemplate: "{context}")

    /// HOM-68 follow-up（2026-06-05 22:30）：README 翻译默认 Prompt。
    ///
    /// 之前这套 prompt 写死在 `ReadmeTranslationService.systemPrompt(targetLanguage:)` /
    /// `userPrompt(...)` 静态函数里，导致用户无法在设置页调整。本次按摘要 / 标签的
    /// 模式抽到这里，统一通过 `AIModelTaskConfiguration.prompt` 走，运行时 Service
    /// 负责把 `{targetLanguage}` 替换为 `ReadmeTranslationLanguage.promptName`、
    /// `{context}` 替换为源 README HTML 片段。
    ///
    /// 设计上仍然保留"结构保真"的强约束（5 条 STRICT RULES + `assertStructureNotBroken`
    /// + `stripFenceWrapping` 后处理）—— 即便用户改坏了 prompt，service 的结构校验
    /// 仍会拦截大幅破坏结构的输出并保留原 README，不会污染缓存。占位符约定：
    /// - `{targetLanguage}` 必须出现在 system 或 user prompt 至少一处（否则模型不知道
    ///   要翻译成哪种语言）；service 不强校验，但运行时如果两处都缺，等于让模型自己猜。
    /// - `{context}` 只能出现在 user prompt（system prompt 出现也会被替换，但语义错误）。
    static let translation = AIPromptConfiguration(
        systemPrompt: """
        You are Starcat's README translation engine.
        Translate the provided GitHub README HTML fragment into {targetLanguage}.

        STRICT RULES (failure to follow renders the output unusable):
        - Output the translated HTML fragment ONLY. Do not add prose, comments, or explanations before or after.
        - Do NOT wrap the result in markdown fences such as ```html ... ``` or ``` ... ```.
        - Preserve every HTML tag, attribute, attribute value, id, class, href, src exactly as-is. Do not rename, reorder, or remove tags.
        - Do NOT translate text inside <code>, <pre>, or anything that looks like source code, shell commands, file paths, environment variables, or URLs.
        - Do NOT translate proper nouns: project names, library names, API endpoints, branch names, version strings.
        - Translate ONLY user-visible natural language text nodes (paragraphs, headings, list items, table cells, blockquotes, captions, button labels).
        - Keep emoji and inline icons untouched.
        - Keep the total number of HTML tags identical to the source.
        """,
        userPromptTemplate: """
        Translate the README fragment below into {targetLanguage}.
        Return the translated HTML fragment only.

        <README_FRAGMENT>
        {context}
        </README_FRAGMENT>
        """
    )
}

extension AIServiceProvider {
    var defaultProfileName: String {
        switch self {
        case .openAICompatible: return "OpenAI Compatible"
        case .deepSeek:         return "DeepSeek"
        case .openRouter:       return "OpenRouter"
        case .ollama:           return "Ollama Local"
        case .lmStudio:         return "LM Studio Local"
        }
    }

    var allowsEmptyAPIKey: Bool {
        switch self {
        case .ollama, .lmStudio:
            return true
        case .openAICompatible, .deepSeek, .openRouter:
            return false
        }
    }

    var fallbackAPIKey: String {
        allowsEmptyAPIKey ? "local-ai" : ""
    }
}
