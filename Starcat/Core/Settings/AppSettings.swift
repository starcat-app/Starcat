//
//  AppSettings.swift
//  Starcat
//
//  应用级用户偏好。
//
//  设计要点：
//  - 用 @Observable + UserDefaults 持久化，SwiftUI 端读偏好可自动响应
//  - 单例（.shared）模式，与 DatabaseManager / KeychainManager 一致
//  - 所有偏好键集中在 private Keys 枚举里，避免散落字符串
//  - 不打算在 App 内做 iCloud 偏好同步（macOS Settings 一般本机即可）
//
//  增加新偏好的流程：
//  1. Keys 里加 key
//  2. 加 @Observable 属性 + didSet 写 UserDefaults
//  3. 在 init 里读初始值
//  4. SettingsView 里加对应控件
//

import Foundation
import SwiftUI
import Observation

// MARK: - 外观主题(W4-5 D1,dong4j 2026-06-03 需求)

/// 应用外观主题。
///
/// 设计选型:
/// - 不强制走系统 — Starcat 整体视觉(暖橙 code 卡 + 卡片式 sheet)在深色下层次更分明,
///   所以默认 `.dark`,但保留 `.system` / `.light` 让用户自由切换
/// - 对应到 SwiftUI 的 `ColorScheme?`:`.system` → nil(跟随系统),其余 → 强制
/// - icon 用 SF Symbol 跟 macOS 系统"外观"设置的图标语言保持一致,
///   降低用户认知成本
enum AppearanceMode: String, CaseIterable, Identifiable {
    /// 跟随系统(macOS 系统设置切换"外观"时 Starcat 自动同步)
    case system
    /// 强制浅色
    case light
    /// 强制深色 — Starcat 默认值
    case dark

    var id: String { rawValue }

    /// 本地化显示名(供 Picker / Label 使用)。
    var displayName: LocalizedStringKey {
        switch self {
        case .system: return "settings.appearance.system"
        case .light:  return "settings.appearance.light"
        case .dark:   return "settings.appearance.dark"
        }
    }

    /// SF Symbol 图标。
    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon.fill"
        }
    }

    /// 映射到 SwiftUI 的 `ColorScheme?`。
    ///
    /// - `.system` → `nil`:`.preferredColorScheme(nil)` 即"不强制",回退到系统设置
    /// - `.light` → `.light` / `.dark` → `.dark`:强制覆盖系统外观
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

// MARK: - 列表排序（W4-4 D1）

/// 仓库列表排序选项。
///
/// 设计：把"字段 + 方向"合并成枚举 case，UI 用单层 Picker 就能列全，无需嵌套 Menu。
/// 默认 `.starredAtDesc` — 最近 star 的在最前，与之前隐式行为一致。
enum RepoSortOption: String, CaseIterable, Identifiable {
    /// 默认：最近 star 在前（All Stars / 星标列表）。
    case starredAtDesc
    /// 最早 star 在前。
    case starredAtAsc
    /// 最近加入知识库在前（`repo_notes.library_updated_at`；在库列表默认）。
    case libraryUpdatedAtDesc
    /// 名称 A→Z。
    case nameAsc
    /// 名称 Z→A。
    case nameDesc
    /// Stars 高→低。
    case starsDesc
    /// Stars 低→高。
    case starsAsc
    /// 最近 push（GitHub `pushed_at`）在前。命名采用"更新"对齐用户语义。
    case updatedDesc
    /// 最早 push 在前。
    case updatedAsc
    /// 创建时间新→旧。
    case createdDesc
    /// 创建时间旧→新。
    case createdAsc
    /// 健康分高→低；无健康分的仓库排到末尾。
    case healthScoreDesc
    /// OpenSSF Scorecard 高→低；无 OpenSSF 分数的仓库排到末尾。
    case openSSFScoreDesc

    var id: String { rawValue }

    /// Manage 列表实际展示的排序项。
    ///
    /// `starredAtDesc` 继续作为星标列表"默认"：按最近 star 排序，但不再把
    /// "最近星标/最早星标"暴露成独立产品概念。知识库相关排序紧随其后。
    static let manageOptions: [RepoSortOption] = [
        .starredAtDesc,
        .libraryUpdatedAtDesc,
        .starsDesc,
        .starsAsc,
        .updatedDesc,
        .updatedAsc,
        .createdDesc,
        .createdAsc,
        .nameAsc,
        .nameDesc,
        .healthScoreDesc,
        .openSSFScoreDesc
    ]

    var isManageSpecificSort: Bool {
        self == .healthScoreDesc || self == .openSSFScoreDesc
    }

    /// 本地化显示名（Picker 菜单项用 `Text(verbatim:)` 渲染，走 `String.l10n`）。
    var localizedTitle: String {
        switch self {
        case .starredAtDesc: return String.l10n("settings.sort.starredAtDesc")
        case .starredAtAsc:  return String.l10n("settings.sort.starredAtAsc")
        case .libraryUpdatedAtDesc: return String.l10n("settings.sort.libraryUpdatedAtDesc")
        case .nameAsc:       return String.l10n("settings.sort.nameAsc")
        case .nameDesc:      return String.l10n("settings.sort.nameDesc")
        case .starsDesc:     return String.l10n("settings.sort.starsDesc")
        case .starsAsc:      return String.l10n("settings.sort.starsAsc")
        case .updatedDesc:   return String.l10n("settings.sort.updatedDesc")
        case .updatedAsc:    return String.l10n("settings.sort.updatedAsc")
        case .createdDesc:   return String.l10n("settings.sort.createdDesc")
        case .createdAsc:    return String.l10n("settings.sort.createdAsc")
        case .healthScoreDesc: return String.l10n("settings.sort.healthScoreDesc")
        case .openSSFScoreDesc: return String.l10n("settings.sort.openSSFScoreDesc")
        }
    }

    /// 本地化显示名（SwiftUI `Label` / `LocalizedStringKey` 场景）。
    var displayName: LocalizedStringKey {
        switch self {
        case .starredAtDesc: return "settings.sort.starredAtDesc"
        case .starredAtAsc:  return "settings.sort.starredAtAsc"
        case .libraryUpdatedAtDesc: return "settings.sort.libraryUpdatedAtDesc"
        case .nameAsc:       return "settings.sort.nameAsc"
        case .nameDesc:      return "settings.sort.nameDesc"
        case .starsDesc:     return "settings.sort.starsDesc"
        case .starsAsc:      return "settings.sort.starsAsc"
        case .updatedDesc:   return "settings.sort.updatedDesc"
        case .updatedAsc:    return "settings.sort.updatedAsc"
        case .createdDesc:   return "settings.sort.createdDesc"
        case .createdAsc:    return "settings.sort.createdAsc"
        case .healthScoreDesc: return "settings.sort.healthScoreDesc"
        case .openSSFScoreDesc: return "settings.sort.openSSFScoreDesc"
        }
    }

    /// SF Symbol，用于 Menu Label 视觉提示。
    var systemImage: String {
        switch self {
        case .starredAtDesc:                return "sparkles"
        case .starredAtAsc:                 return "star"
        case .libraryUpdatedAtDesc:         return "books.vertical"
        case .nameAsc:                      return "a.square"
        case .nameDesc:                     return "z.square"
        case .starsDesc:                    return "star.fill"
        case .starsAsc:                     return "star"
        case .updatedDesc, .updatedAsc:     return "clock.arrow.circlepath"
        case .createdDesc:                  return "calendar.badge.plus"
        case .createdAsc:                   return "calendar"
        case .healthScoreDesc:              return "heart.text.square"
        case .openSSFScoreDesc:             return "checkmark.shield"
        }
    }

    /// 排序谓词。
    ///
    /// 实现策略：
    /// - 时间字段（starredAt / pushedAt）用 ISO8601 字符串字典序，与时间序一致(`String?`，nil 视作空串、排最后)
    /// - 名称按 `fullName` 大小写不敏感比较
    /// - Stars 数字直接比较
    ///
    /// 1801 条 in-memory sort 耗时 < 10ms，HomeViewModel 直接调，无需走数据库重查。
    func comparator(_ a: Repo, _ b: Repo) -> Bool {
        switch self {
        case .starredAtDesc:
            return (a.starredAt ?? "") > (b.starredAt ?? "")
        case .starredAtAsc:
            // 升序也要把 nil 推到末尾(否则空串会冒到最前面看不到内容)
            let av = a.starredAt ?? "\u{FFFD}"
            let bv = b.starredAt ?? "\u{FFFD}"
            return av < bv
        case .libraryUpdatedAtDesc:
            // 入库时间在 repo_notes，纯 Repo comparator 拿不到；知识库列表走 SQL。
            // 内存路径给稳定 fallback，避免搜索/缓存路径崩溃。
            return RepoSortOption.starredAtDesc.comparator(a, b)
        case .nameAsc:
            return a.fullName.localizedCaseInsensitiveCompare(b.fullName) == .orderedAscending
        case .nameDesc:
            return a.fullName.localizedCaseInsensitiveCompare(b.fullName) == .orderedDescending
        case .starsDesc:
            return a.starsCount > b.starsCount
        case .starsAsc:
            return a.starsCount < b.starsCount
        case .updatedDesc:
            return (a.pushedAt ?? "") > (b.pushedAt ?? "")
        case .updatedAsc:
            let av = a.pushedAt ?? "\u{FFFD}"
            let bv = b.pushedAt ?? "\u{FFFD}"
            return av < bv
        case .createdDesc:
            return (a.createdAt ?? "") > (b.createdAt ?? "")
        case .createdAsc:
            let av = a.createdAt ?? "\u{FFFD}"
            let bv = b.createdAt ?? "\u{FFFD}"
            return av < bv
        case .healthScoreDesc:
            // Health 排序依赖 repo_health_snapshots，纯 Repo comparator 拿不到分数。
            // 真正排序由 HomeViewModel / RepoRepository SQL 处理；这里给调用方一个稳定 fallback。
            return RepoSortOption.starredAtDesc.comparator(a, b)
        case .openSSFScoreDesc:
            // OpenSSF 排序依赖 open_ssf_scores，纯 Repo comparator 拿不到分数。
            // 真正排序由 HomeViewModel / RepoRepository SQL 处理；这里给调用方一个稳定 fallback。
            return RepoSortOption.starredAtDesc.comparator(a, b)
        }
    }
}

// MARK: - AI 设置

/// AI 服务商类型。
///
/// 设计选择：
/// - 当前第一阶段只落地 OpenAI-compatible 路线，**所有 case 都假定走 OpenAI Chat
///   Completions 协议**，由 `OpenAIClient` 统一适配。Anthropic Messages API（Claude
///   官方、`*_anthropic` 系列入口）暂未支持，故未列入；未来若新增 Anthropic 客户端
///   再扩展。
/// - 保留具体 provider 枚举不是为了锁死 SDK，而是给设置页提供"一键填好 base URL +
///   chat / embedding 默认值 + logo"的快捷选项。dong4j 仍然可以选 `.openAICompatible`
///   + 自填 URL 接入任何 OpenAI 兼容服务。
/// - 提供商清单与图标资源同步自 zeka-idea-plugin `AIProviderType.java`（2026-06-06
///   一次性导入），新增任何 case 必须同时：
///   1) 优先在 `Resources/Assets.xcassets/AIProviders` 新建对应 imageset（与
///      `iconAssetName` 返回值同名）；若上游没有可再分发的矢量品牌资源，则必须提供
///      明确的 `fallbackSystemImageName`，不能复制来源不明的网页位图；
///   2) 同步更新 `displayName` / `defaultBaseURL` / `defaultChatModel` /
///      `defaultEmbeddingModel` / `supportsEmbeddingEndpoint` / `allowsEmptyAPIKey` /
///      `iconAssetName` / `fallbackSystemImageName`；
///   3) `AIProviderIconView` 自动按 `iconAssetName` 渲染，缺失时改用 Provider fallback。
///
/// 已有用户偏好兼容性：早期版本仅有 5 个 case（`openAICompatible` / `deepSeek` /
/// `openRouter` / `ollama` / `lmStudio`），新增枚举值都追加在后面，原 rawValue 不动，
/// 老用户升级后已选 provider 仍然可正确解码。
enum AIServiceProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    // MARK: - 早期已有（不改 rawValue 以兼容旧持久化）
    case openAICompatible
    case deepSeek
    case openRouter
    case ollama
    case lmStudio

    // MARK: - 2026-06-06 批量新增（OpenAI Chat Completions 兼容）
    case freeai
    case nvidia
    case huggingface
    case cloudflare
    case bedrock
    case azureOpenAI
    case githubModels
    case mistral
    case doubao
    case grok
    case hunyuan
    case moonshot
    case qianwen
    case siliconflow
    case iflow
    case modelscope
    case zhipu
    case zai

    // MARK: - 2026-09-05 新增（OpenAI Chat Completions 兼容）
    // 继续追加在尾部，避免改动已有 rawValue 的持久化语义。
    case orcaRouter

    var id: String { rawValue }

    /// 设置页 picker 显示的服务商名（i18n key 复用 LocalizedStringKey 自动解析）。
    var displayName: LocalizedStringKey {
        switch self {
        case .openAICompatible: return "OpenAI Compatible"
        case .deepSeek:         return "DeepSeek"
        case .openRouter:       return "OpenRouter"
        case .ollama:           return "Ollama"
        case .lmStudio:         return "LM Studio"
        case .freeai:           return "FreeAI"
        case .nvidia:           return "NVIDIA"
        case .huggingface:      return "HuggingFace"
        case .cloudflare:       return "Cloudflare Workers AI"
        case .bedrock:          return "Amazon Bedrock"
        case .azureOpenAI:      return "Azure OpenAI"
        case .githubModels:     return "GitHub Models"
        case .mistral:          return "Mistral AI"
        case .doubao:           return "ai.provider.doubao"
        case .grok:             return "Grok"
        case .hunyuan:          return "ai.provider.hunyuan"
        case .moonshot:         return "Moonshot"
        case .qianwen:          return "ai.provider.qianwen"
        case .siliconflow:      return "ai.provider.siliconflow"
        case .iflow:            return "IFlow"
        case .modelscope:       return "ModelScope"
        case .zhipu:            return "ai.provider.zhipu"
        case .zai:              return "Z.AI"
        case .orcaRouter:       return "OrcaRouter"
        }
    }

    /// 对应 `Assets.xcassets/AIProviders` 下的 imageset 名（SVG 矢量图）。
    ///
    /// 命名规则：直接借用 zeka-idea-plugin `intelli-ai-engine/icons` 已有的图标 stem，
    /// 部分服务商共享视觉资源（如 OpenAI Compatible 复用 `chatgpt`，智谱 `chatglm`，
    /// 通义千问 `qwen`，Azure OpenAI `azureai`）。
    var iconAssetName: String {
        switch self {
        case .openAICompatible: return "chatgpt"   // OpenAI Compatible 复用 ChatGPT logo 作视觉代表
        case .deepSeek:         return "deepseek"
        case .openRouter:       return "openrouter"
        case .ollama:           return "ollama"
        case .lmStudio:         return "lmstudio"
        case .freeai:           return "freeai"
        case .nvidia:           return "nvidia"
        case .huggingface:      return "huggingface"
        case .cloudflare:       return "cloudflareai"
        case .bedrock:          return "bedrock"
        case .azureOpenAI:      return "azureai"
        case .githubModels:     return "githubmodels"
        case .mistral:          return "mistral"
        case .doubao:           return "doubao"
        case .grok:             return "grok"
        case .hunyuan:          return "hunyuan"
        case .moonshot:         return "moonshot"
        case .qianwen:          return "qwen"
        case .siliconflow:      return "siliconflow"
        case .iflow:            return "iflow"
        case .modelscope:       return "modelscope"
        case .zhipu:            return "chatglm"
        case .zai:              return "zai"
        case .orcaRouter:       return "orcarouter"
        }
    }

    /// 品牌 imageset 不可用时采用的中性 SF Symbol。
    ///
    /// OrcaRouter 官方文档当前只公开网页位图，没有可确认再分发的矢量品牌资源；先用
    /// 路由拓扑符号表达其网关定位，未来补官方矢量资源时无需改调用方。
    var fallbackSystemImageName: String {
        switch self {
        case .orcaRouter:
            return "point.3.connected.trianglepath.dotted"
        default:
            return "sparkles"
        }
    }

    /// 是否是"纯白单色 logo"——这些 SVG 的 `fill` 全部是 `#ffffff`，
    /// 直接渲染会有"明亮主题下完全不可见"的问题（dong4j 2026-06-06 截图反馈）。
    ///
    /// 设计：
    /// - `true` 的 provider，UI 层走 `.renderingMode(.template) + .foregroundStyle(.primary)`，
    ///   把非透明像素当 alpha mask 用，颜色由系统跟随 colorScheme 决定
    /// - `false` 的 provider（含彩色 / 渐变 logo）走 `.renderingMode(.original)` 保留品牌色
    ///
    /// 新增 provider 时如果引入的也是单色白 SVG（zeka 的 `*_32.svg` 以 `#ffffff` 居多），
    /// 必须在此 case 里追加；否则在 light mode 下用户看到一片空白。
    /// 判定来源：`rg -o 'fill="[^"]*"' Resources/Assets.xcassets/AIProviders/*/*.svg`。
    var iconIsMonochromeWhite: Bool {
        switch self {
        case .openAICompatible, .ollama, .lmStudio, .grok, .moonshot:
            return true
        default:
            return false
        }
    }

    /// 默认 Base URL（与 `AIProviderType.java` 对齐；含 `{YOUR_*}` 占位的需用户手填）。
    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .deepSeek:         return "https://api.deepseek.com"
        case .openRouter:       return "https://openrouter.ai/api/v1"
        case .ollama:           return "http://localhost:11434/v1"
        case .lmStudio:         return "http://localhost:1234/v1"
        case .freeai:           return "https://zekastack.dong4j.site/freeai/v1"
        case .nvidia:           return "https://integrate.api.nvidia.com/v1"
        case .huggingface:      return "https://router.huggingface.co/v1"
        case .cloudflare:       return "https://api.cloudflare.com/client/v4/accounts/{YOUR_ACCOUNT_ID}/ai/v1"
        case .bedrock:          return "https://bedrock-runtime.us-east-1.amazonaws.com/openai/v1"
        case .azureOpenAI:      return "https://{YOUR_RESOURCE_NAME}.openai.azure.com/openai/deployments/{YOUR_DEPLOYMENT_NAME}"
        case .githubModels:     return "https://models.github.ai/inference"
        case .mistral:          return "https://api.mistral.ai/v1"
        case .doubao:           return "https://ark.cn-beijing.volces.com/api/v3"
        case .grok:             return "https://api.x.ai/v1"
        case .hunyuan:          return "https://api.hunyuan.cloud.tencent.com/v1"
        case .moonshot:         return "https://api.moonshot.cn/v1"
        case .qianwen:          return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .siliconflow:      return "https://api.siliconflow.cn/v1"
        case .iflow:            return "https://apis.iflow.cn/v1"
        case .modelscope:       return "https://api-inference.modelscope.cn/v1"
        case .zhipu:            return "https://open.bigmodel.cn/api/paas/v4"
        case .zai:              return "https://api.z.ai/api/coding/paas/v4"
        case .orcaRouter:       return "https://api.orcarouter.ai/v1"
        }
    }

    /// 设置页“新增 provider”后预填的默认 chat 模型名（仅作占位提示，用户应改成自己开通的模型）。
    var defaultChatModel: String {
        switch self {
        case .openAICompatible: return "gpt-4o-mini"
        case .deepSeek:         return "deepseek-chat"
        case .openRouter:       return "openai/gpt-4o-mini"
        case .ollama:           return "llama3.2"
        case .lmStudio:         return "local-model"
        case .freeai:           return "glm-4.6"
        case .nvidia:           return "meta/llama-3.1-8b-instruct"
        case .huggingface:      return "meta-llama/Meta-Llama-3.1-8B-Instruct"
        case .cloudflare:       return "@cf/meta/llama-3.1-8b-instruct"
        case .bedrock:          return "openai.gpt-oss-120b-1:0"
        case .azureOpenAI:      return "gpt-4o-mini"
        case .githubModels:     return "openai/gpt-4o-mini"
        case .mistral:          return "mistral-small-latest"
        case .doubao:           return "doubao-1-5-pro-32k-250115"
        case .grok:             return "grok-3-mini"
        case .hunyuan:          return "hunyuan-pro"
        case .moonshot:         return "kimi-k2-0905-preview"
        case .qianwen:          return "qwen-plus"
        case .siliconflow:      return "Qwen/Qwen3-8B"
        case .iflow:            return "kimi-k2-0905"
        case .modelscope:       return "ZhipuAI/GLM-4.6"
        case .zhipu:            return "glm-4.6"
        case .zai:              return "glm-4.6"
        case .orcaRouter:       return "openai/gpt-4o-mini"
        }
    }

    /// 默认 embedding 模型；不暴露 embedding 的本地 / 远端 provider 此处仍给一个常见名占位。
    var defaultEmbeddingModel: String {
        switch self {
        case .openAICompatible, .openRouter, .githubModels, .azureOpenAI:
            return "text-embedding-3-small"
        case .deepSeek:
            return "text-embedding-3-small"
        case .ollama:
            return "nomic-embed-text"
        case .lmStudio:
            return "text-embedding-nomic-embed-text-v1.5"
        case .freeai:
            return "BAAI/bge-m3"
        case .nvidia:
            return "nvidia/nv-embed-v1"
        case .huggingface:
            return "BAAI/bge-large-en-v1.5"
        case .cloudflare:
            return "@cf/baai/bge-base-en-v1.5"
        case .bedrock:
            return "amazon.titan-embed-text-v2:0"
        case .mistral:
            return "mistral-embed"
        case .doubao:
            return "doubao-embedding-text-240715"
        case .grok:
            // xAI 目前未公开 embedding 模型，仍按 OpenAI 命名占位，由用户改写
            return "text-embedding-3-small"
        case .hunyuan:
            return "hunyuan-embedding"
        case .moonshot:
            // Moonshot 暂未提供 embedding，占位 OpenAI 命名
            return "text-embedding-3-small"
        case .qianwen:
            return "text-embedding-v3"
        case .siliconflow:
            return "BAAI/bge-m3"
        case .iflow:
            return "bge-m3"
        case .modelscope:
            return "iic/nlp_gte_sentence-embedding_chinese-base"
        case .zhipu:
            return "embedding-3"
        case .zai:
            return "embedding-3"
        case .orcaRouter:
            // OrcaRouter 2026-09-05 官方 OpenAPI 未定义 `/v1/embeddings`。
            // 空值只用于构造“模型列表测试”客户端；Embedding 任务由下方能力门禁拦截。
            return ""
        }
    }

    /// Provider 是否公开 OpenAI-compatible `/embeddings` 端点。
    ///
    /// 这是请求前硬门禁，不依赖模型名推断；否则用户填写自定义模型时会绕过 descriptor
    /// capability 校验，把 OrcaRouter 误用于当前并不存在的 Embedding API。
    var supportsEmbeddingEndpoint: Bool {
        switch self {
        case .orcaRouter:
            return false
        default:
            return true
        }
    }
}

/// 全局搜索模式。
///
/// 放在 Settings 层是因为该选择既影响 toolbar 的视觉状态，也影响 HomeViewModel
/// 的查询分支；后续 Search 工作区复用同一枚举即可。
enum SmartSearchMode: String, CaseIterable, Identifiable {
    case keyword
    case semantic

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .keyword:  return "search.mode.keyword"
        case .semantic: return "search.mode.semantic"
        }
    }

    var systemImage: String {
        switch self {
        case .keyword:  return "magnifyingglass"
        case .semantic: return "sparkles"
        }
    }
}

// MARK: - README 翻译目标语言（HOM-68）

/// README AI 翻译目标语言。
///
/// 设计：
/// - **raw 用 BCP-47 标签**（`zh-Hans` / `en` / `ja` 等）：与 `Locale.identifier` 兼容，
///   后续做"按 App 当前 locale 自动选默认目标"或写日志时可以直接传给 Locale；
/// - **菜单第一项是 `.auto`**：目标跟随 App 界面语言（`resolved()` →
///   `defaultForCurrentLocale()`），外加按段跳过同语种。用户选具体语言后锁定，
///   不再随界面变。首次启动 / 重置默认 `.auto`；已持久化的具体语言不迁移。
/// - **未知 locale 仍落到英文**（HOM-198）：`defaultForCurrentLocale()` 只返回
///   具体语言，不会再回到 `.auto`。英文是 README 原文最普遍的语言，比硬塞简体合理。
/// - 目标语言与 App 当前正式开放的 18 种显示语言保持同一组 BCP-47 identifier；
/// - `displayName` 使用“旗帜 + 母语名称”，不跟随当前界面语言翻译；
/// - `promptName` 是发给 LLM 的目标语言名称，固定走英文（`Simplified Chinese`），
///   避免不同 provider 对中文 prompt 关键词的解析差异，提示词中明确语言能更稳定。
///
/// **与 App UI 本地化语言（`Localizable.xcstrings`）解耦**：
/// 两者当前都开放 18 种语言，但仍是独立类型：README 翻译语言参与 Prompt、缓存 key
/// 和用户偏好；AppLocale 负责界面 Catalog 与布局方向，不能把两者合并成同一枚举。
enum ReadmeTranslationLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 目标语言跟随 App 界面语言；真正送给模型 / 写缓存前必须 `resolved()`。
    case auto = "auto"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case brazilianPortuguese = "pt-BR"
    case italian = "it"
    case russian = "ru"
    case dutch = "nl"
    case polish = "pl"
    case ukrainian = "uk"
    case turkish = "tr"
    case vietnamese = "vi"
    case indonesian = "id"
    case arabic = "ar"

    var id: String { rawValue }

    /// 菜单显示文案。具体语言用母语名；Auto 按当前 App 界面语言写短词，
    /// 避免为本项改 Localizable.xcstrings（该文件不能整文件插入）。
    var displayName: String {
        switch self {
        case .auto:
            // 🌐 和具体语言的国旗同一列，标明「跟界面语言走」而不是某个国家。
            let localized: String
            switch Self.defaultForCurrentLocale() {
            case .auto, .english:
                localized = "Auto"
            case .simplifiedChinese:
                localized = "自动"
            case .traditionalChinese:
                localized = "自動"
            case .japanese:
                localized = "自動"
            case .korean:
                localized = "자동"
            case .german, .dutch:
                localized = "Automatisch"
            case .french:
                localized = "Automatique"
            case .spanish, .brazilianPortuguese:
                localized = "Automático"
            case .italian:
                localized = "Automatico"
            case .russian:
                localized = "Авто"
            case .polish:
                localized = "Automatycznie"
            case .ukrainian:
                localized = "Автоматично"
            case .turkish:
                localized = "Otomatik"
            case .vietnamese:
                localized = "Tự động"
            case .indonesian:
                localized = "Otomatis"
            case .arabic:
                localized = "تلقائي"
            }
            return "🌐 \(localized)"
        case .simplifiedChinese:  return "🇨🇳 简体中文"
        case .traditionalChinese: return "🇨🇳 繁體中文"
        case .english:            return "🇺🇸 English"
        case .japanese:           return "🇯🇵 日本語"
        case .korean:             return "🇰🇷 한국어"
        case .german:             return "🇩🇪 Deutsch"
        case .french:             return "🇫🇷 Français"
        case .spanish:            return "🇪🇸 Español"
        case .brazilianPortuguese: return "🇧🇷 Português (Brasil)"
        case .italian:            return "🇮🇹 Italiano"
        case .russian:            return "🇷🇺 Русский"
        case .dutch:              return "🇳🇱 Nederlands"
        case .polish:             return "🇵🇱 Polski"
        case .ukrainian:          return "🇺🇦 Українська"
        case .turkish:            return "🇹🇷 Türkçe"
        case .vietnamese:         return "🇻🇳 Tiếng Việt"
        case .indonesian:         return "🇮🇩 Bahasa Indonesia"
        case .arabic:             return "🇸🇦 العربية"
        }
    }

    /// 发给 LLM 的目标语言名（固定英文，跨 provider 最稳定）。
    var promptName: String {
        resolved().concretePromptName
    }

    /// `auto` 解析成当前 App 界面语言；具体语言原样返回。缓存和 API 只吃具体语言。
    func resolved(
        appLocaleOverride: String? = UserDefaults.standard.string(forKey: "AppLocaleOverride")
    ) -> ReadmeTranslationLanguage {
        switch self {
        case .auto:
            return Self.defaultForCurrentLocale(appLocaleOverride: appLocaleOverride)
        default:
            return self
        }
    }

    private var concretePromptName: String {
        switch self {
        case .auto:
            return "English"
        case .simplifiedChinese:  return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        case .english:            return "English"
        case .japanese:           return "Japanese"
        case .korean:             return "Korean"
        case .german:             return "German"
        case .french:             return "French"
        case .spanish:            return "Spanish"
        case .brazilianPortuguese: return "Brazilian Portuguese"
        case .italian:            return "Italian"
        case .russian:            return "Russian"
        case .dutch:              return "Dutch"
        case .polish:             return "Polish"
        case .ukrainian:          return "Ukrainian"
        case .turkish:            return "Turkish"
        case .vietnamese:         return "Vietnamese"
        case .indonesian:         return "Indonesian"
        case .arabic:             return "Arabic"
        }
    }

    // MARK: - HOM-198：按 App 当前 locale 推断默认目标语言

    /// 按 App 当前 i18n locale 推断默认翻译目标语言。
    ///
    /// **取值来源刻意用 `Bundle.main.preferredLocalizations.first`** 而不是
    /// `Locale.current.identifier`：
    /// - `preferredLocalizations` 是 App "实际渲染" 使用的本地化（受 xcstrings
    ///   能匹配的语言限制，再按用户系统语言偏好排序），代表"用户看到的 App 界面"；
    /// - `Locale.current` 反映的是用户系统区域设置，可能 App 界面已经回落到英文
    ///   而系统 locale 仍是日文——那样默认翻译成日文会与 App 界面割裂。
    ///
    /// 极端 fallback：若 `preferredLocalizations` 为空（理论上不会发生，
    /// Bundle 至少会回到 development localization `zh-Hans`），再回退到
    /// `Locale.current.identifier`，最后还无法解析就走 `.english`。
    ///
/// 两处消费：① 存储值是 `.auto` 时每次 `resolved()`；② 历史上从未持久化过
/// 目标语言时的 init 回落。用户锁定具体语言后，这个函数不再影响目标。
    static func defaultForCurrentLocale(
        appLocaleOverride: String? = UserDefaults.standard.string(forKey: "AppLocaleOverride")
    ) -> ReadmeTranslationLanguage {
        // 用户显式选择的 App 显示语言优先于进程启动时确定的 Bundle localization。
        // `.system` 不是 BCP-47 identifier，仍需回到 Bundle / Locale 推断。
        let explicitIdentifier = appLocaleOverride.flatMap { $0 == "system" ? nil : $0 }
        let identifier = explicitIdentifier
            ?? Bundle.main.preferredLocalizations.first
            ?? Locale.current.identifier
        return defaultLanguage(forLocaleIdentifier: identifier)
    }

    /// 把 BCP-47 locale identifier 映射为翻译目标语言。
    ///
    /// 拆出来是为了**让单测能注入任意 identifier**（不依赖运行环境的
    /// Bundle / Locale），同时 `defaultForCurrentLocale()` 也复用同一份规则。
    ///
    /// 映射规则：
    /// - `zh-Hant` / `zh-TW` / `zh-HK` / `zh-MO` → `.traditionalChinese`；
    /// - 其余 `zh*`（含 `zh-Hans` / `zh-CN` / `zh-SG` / 裸 `zh`）→ `.simplifiedChinese`；
    /// - 其余 16 种目标语言按 language code 映射，其中 `pt*` 固定使用巴西葡萄牙语；
    /// - 未支持或无效 identifier → `.english`。
    ///
    /// 用 `Locale.Language` 而不是字符串 `hasPrefix` 比对：标准 API 会正确处理
    /// `zh_CN`（旧 POSIX 格式）/ `zh-Hans-CN`（带脚本和区域）/ 大小写差异等边角情形。
    static func defaultLanguage(forLocaleIdentifier identifier: String) -> ReadmeTranslationLanguage {
        let lang = Locale.Language(identifier: identifier)
        let code = lang.languageCode?.identifier ?? ""
        let script = lang.script?.identifier ?? ""
        let region = lang.region?.identifier ?? ""

        switch code {
        case "zh":
            // 脚本显式 Hant → 繁体；否则按地区判定（TW/HK/MO 繁体），其余落简体。
            if script == "Hant" || ["TW", "HK", "MO"].contains(region) {
                return .traditionalChinese
            }
            return .simplifiedChinese
        case "ja":
            return .japanese
        case "ko":
            return .korean
        case "de":
            return .german
        case "fr":
            return .french
        case "es":
            return .spanish
        case "pt":
            return .brazilianPortuguese
        case "it":
            return .italian
        case "ru":
            return .russian
        case "nl":
            return .dutch
        case "pl":
            return .polish
        case "uk":
            return .ukrainian
        case "tr":
            return .turkish
        case "vi":
            return .vietnamese
        case "id":
            return .indonesian
        case "ar":
            return .arabic
        default:
            return .english
        }
    }
}

// MARK: - AppSettings

/// 应用级偏好容器。
///
/// 通过 SwiftUI Environment 注入（见 `AppDependencies`），
/// 也可通过 `AppSettings.shared` 直接访问（与 KeychainManager 模式一致）。
@MainActor
@Observable
final class AppSettings {

    // MARK: - 单例

    static let shared = AppSettings()

    /// MCP 默认监听端口（设置页可改，有效范围 1024...65535）。
    static let defaultMCPServicePort = 5555

    /// README 阅读字号工具条允许的全局偏移范围，单位为 CSS px。
    static let readmeFontSizeAdjustmentRange = -2...4

    // MARK: - 偏好项

    /// 应用外观主题(W4-5 D1,dong4j 2026-06-03 需求)。
    /// 默认 `.dark` — Starcat 主视觉为深色,见 `AppearanceMode` 设计注释。
    /// 写入即落盘;UI 通过 @Observable 自动响应,
    /// `StarcatApp` 的 WindowGroup / Settings scene 各挂一个 `.preferredColorScheme(_:)` 应用。
    var appearanceMode: AppearanceMode {
        didSet { persist(key: Keys.appearanceMode, value: appearanceMode.rawValue) }
    }

    /// 应用内界面字号档位。默认 `.standard`。
    ///
    /// 设计约束：这是 Starcat 自己控制的信息密度档位，不等同于系统 Dynamic Type。
    /// 各页面需要逐步接入并验证布局，避免一次性全站缩放破坏三栏信息密度。
    var interfaceScale: InterfaceScale {
        didSet { persist(key: Keys.interfaceScale, value: interfaceScale.rawValue) }
    }

    /// README 渲染页的全局阅读字号偏移。
    ///
    /// 这是用户的阅读偏好，不绑定某个 repo。所有 `ReadmeWebView` 共享这个值，
    /// 避免切换仓库或进入 Activity / Weekly 等复用渲染页后重复调整。
    var readmeFontSizeAdjustment: Int {
        didSet { defaults.set(readmeFontSizeAdjustment, forKey: Keys.readmeFontSizeAdjustment) }
    }

    /// 仓库列表排序（W4-4 D1）。默认 `.starredAtDesc`。
    var repoSortOption: RepoSortOption {
        didSet { persist(key: Keys.repoSortOption, value: repoSortOption.rawValue) }
    }

    /// W4-4 D2：是否隐藏已 archived 的仓库（默认 false，全部显示）。
    var hideArchived: Bool {
        didSet { persistBool(key: Keys.hideArchived, value: hideArchived) }
    }

    /// W4-4 D2：是否隐藏 fork 的仓库（默认 false，全部显示）。
    var hideForks: Bool {
        didSet { persistBool(key: Keys.hideForks, value: hideForks) }
    }

    /// W4-4 D3：按阅读状态过滤。`nil` = 全部。
    /// 落盘用 RawValue("unread"...);为了"无过滤"也能持久化,
    /// 用空字符串占位代表 nil。
    var statusFilter: RepoStatus? {
        didSet {
            defaults.set(statusFilter?.rawValue ?? "", forKey: Keys.statusFilter)
        }
    }

    /// toolbar 全局 Star 状态筛选。`.all` 表示不过滤。
    var starFilter: RepoStarFilter {
        didSet { persist(key: Keys.starFilter, value: starFilter.rawValue) }
    }

    /// Manage 列表知识库筛选。`.all` 表示不过滤。
    var libraryFilter: RepoLibraryFilter {
        didSet { persist(key: Keys.libraryFilter, value: libraryFilter.rawValue) }
    }

    /// Manage 列表语言筛选。`.all` 表示不过滤。
    var repoLanguageFilter: RepoLanguageFilter {
        didSet { persist(key: Keys.repoLanguageFilter, value: repoLanguageFilter.persistedRawValue) }
    }

    /// 全局筛选菜单里的候选语言池。
    ///
    /// 这个偏好只决定 toolbar 语言筛选里展示哪些语言，不直接过滤列表。当前实际
    /// 生效的语言筛选仍由列表偏好保存，方便“重置列表偏好”只清空本次列表控制状态，
    /// 不清掉用户长期维护的兴趣语言集合。
    var interestedLanguages: [String] {
        didSet { persistJSON(key: Keys.interestedLanguages, value: Self.normalizedLanguageList(interestedLanguages)) }
    }

    /// toolbar 全局语言筛选当前选中的语言。空数组表示不过滤语言。
    var globalFilterLanguages: [String] {
        didSet { persistJSON(key: Keys.globalFilterLanguages, value: Self.normalizedLanguageList(globalFilterLanguages)) }
    }

    /// toolbar 全局 Wiki 状态筛选。
    var wikiAvailabilityFilter: RepoSignalAvailabilityFilter {
        didSet { persist(key: Keys.wikiAvailabilityFilter, value: wikiAvailabilityFilter.rawValue) }
    }

    /// toolbar 全局 Health 分数状态筛选。
    var healthAvailabilityFilter: RepoSignalAvailabilityFilter {
        didSet { persist(key: Keys.healthAvailabilityFilter, value: healthAvailabilityFilter.rawValue) }
    }

    /// toolbar 全局 OpenSSF 分数状态筛选。
    var openSSFAvailabilityFilter: RepoSignalAvailabilityFilter {
        didSet { persist(key: Keys.openSSFAvailabilityFilter, value: openSSFAvailabilityFilter.rawValue) }
    }

    /// 用户在 Manage 页最后选中的分类，用于跨启动恢复。
    ///
    /// 为什么存字符串而非 `SidebarItem`：
    /// - `SidebarItem` 含关联值（`.language(String?)` / `.tag(String)`），无法直接当 RawValue 落盘；
    /// - 为避免 AppSettings（Core 层）反向依赖 Home 功能层的 enum，这里只存"已编码字符串"，
    ///   具体编/解码由 `SidebarItem.persistedRawValue` / `init(persistedRawValue:)` 负责（Home 层）。
    /// - 空串表示"无记录"，解码时回落 `.allStars`。
    var lastManageSelectionRaw: String {
        didSet { persist(key: Keys.lastManageSelection, value: lastManageSelectionRaw) }
    }

    /// 用户在 Activity 页最后选中的分类，用于跨启动恢复。
    ///
    /// 和 `lastManageSelectionRaw` 一样只存字符串：ActivityCategory 属于 Feature 层，
    /// Core/Settings 不反向依赖具体 enum，编解码留给 Activity 模块处理。
    var lastActivityCategoryRaw: String {
        didSet { persist(key: Keys.lastActivityCategory, value: lastActivityCategoryRaw) }
    }

    /// 按 GitHub 账号隔离的列表偏好原始值。
    ///
    /// 这里只保存 `login:key -> rawValue` 字符串,不直接引用 Home / Explore / Weekly
    /// 的 Feature enum,避免 Core/Settings 反向依赖功能层类型。
    var listPreferenceValues: [String: String] {
        didSet { persistJSON(key: Keys.listPreferenceValues, value: listPreferenceValues) }
    }

    /// 切换列表分类后是否自动打开当前列表第一条详情。
    ///
    /// 默认 false：切分类只更新中栏列表，详情由用户显式点击触发，避免列表加载后继续加载详情。
    /// Smart Collections 右栏集合浏览面板不受此偏好影响，因为 nil selection 是产品入口。
    var openFirstDetailOnCategoryChange: Bool {
        didSet { persistBool(key: Keys.openFirstDetailOnCategoryChange, value: openFirstDetailOnCategoryChange) }
    }

    /// README 里的同仓 Markdown 链接是否在 App 内打开。
    ///
    /// 默认 false：保持「点击即进浏览器」的现有行为，避免用户在没看到开关前
    /// 被突然改掉的导航吓到。打开后才拦截当前仓库的 `.md` / `.markdown` 链接。
    var openRepositoryMarkdownInApp: Bool {
        didSet { persistBool(key: Keys.openRepositoryMarkdownInApp, value: openRepositoryMarkdownInApp) }
    }

    /// AI 服务商配置。API Key 不进 UserDefaults，单独走 KeychainManager 的加密文件。
    var aiProvider: AIServiceProvider {
        didSet { persist(key: Keys.aiProvider, value: aiProvider.rawValue) }
    }

    /// OpenAI-compatible Base URL，要求包含 `/v1`，如 `https://api.openai.com/v1`。
    var aiBaseURL: String {
        didSet { persist(key: Keys.aiBaseURL, value: aiBaseURL) }
    }

    /// 摘要 / 标签推荐使用的聊天模型。
    var aiChatModel: String {
        didSet { persist(key: Keys.aiChatModel, value: aiChatModel) }
    }

    /// 语义搜索向量化使用的 embedding 模型。
    var aiEmbeddingModel: String {
        didSet { persist(key: Keys.aiEmbeddingModel, value: aiEmbeddingModel) }
    }

    /// 多服务商 AI 配置。
    ///
    /// 为什么放 UserDefaults JSON：
    /// - profile / 模型启用状态 / Prompt 都属于本机偏好，不需要 SQLite 查询能力；
    /// - 第一版先避免数据库迁移风险；
    /// - API Key 不在这里，按 profile ID 存在 `KeychainManager` 的本地加密文件。
    var aiProviderProfiles: [AIProviderProfile] {
        didSet { persistJSON(key: Keys.aiProviderProfiles, value: aiProviderProfiles) }
    }

    /// 摘要任务模型配置。摘要与标签拆开，避免 JSON 标签失败拖垮摘要。
    var aiSummaryTask: AIModelTaskConfiguration {
        didSet { persistJSON(key: Keys.aiSummaryTask, value: aiSummaryTask) }
    }

    /// 推荐标签任务模型配置。
    var aiTagsTask: AIModelTaskConfiguration {
        didSet { persistJSON(key: Keys.aiTagsTask, value: aiTagsTask) }
    }

    /// Embedding 任务模型配置。
    var aiEmbeddingTask: AIModelTaskConfiguration {
        didSet { persistJSON(key: Keys.aiEmbeddingTask, value: aiEmbeddingTask) }
    }

    /// README 翻译任务模型配置（HOM-68 follow-up 2026-06-05）。
    ///
    /// 独立于 `aiSummaryTask`：摘要追求"通顺 + 结构化"（中温度 + 中 max tokens），
    /// 翻译追求"低温度 + 结构保真 + 大上下文"，两类参数差异明显，所以拆开存储 +
    /// 拆开在设置页配置。首次升级时 `init` 兜底逻辑会用与摘要相同的 provider+model 作
    /// 默认值，但参数走 `AIModelParameters.translationDefault`，用户可在设置页改。
    var aiTranslationTask: AIModelTaskConfiguration {
        didSet { persistJSON(key: Keys.aiTranslationTask, value: aiTranslationTask) }
    }

    /// README 全文翻译 Prompt。
    ///
    /// Provider、Model 与参数仍统一读取 `aiTranslationTask`；这里只单独保存全文模式
    /// 的 system/user Prompt，避免为了两个模板复制整套任务配置。
    var aiFullTranslationPrompt: AIPromptConfiguration {
        didSet { persistJSON(key: Keys.aiFullTranslationPrompt, value: aiFullTranslationPrompt) }
    }

    /// 对话任务模型配置（2026-06-14 v4 引入）。
    ///
    /// 之前对话路径直接复用 `aiSummaryTask` 的 model + 参数，system prompt 在
    /// `RepoAIInsightService.assembleChatSystemPrompt` 静态函数里硬编码拼接，
    /// 用户没法编辑。本字段把 chat 提到与其他 4 个任务平级，让 prompt + provider
    /// + model 都暴露给 Settings 页（详见 `AIDefaultPrompts.chat` 的注释）。
    ///
    /// 首次升级时 `init` 兜底逻辑会用与摘要相同的 provider+model + summaryDefault
    /// 参数（chat 与摘要场景接近：都是单仓上下文 + 流式生成 + 中等温度），用户可在
    /// 设置页改。
    var aiChatTask: AIModelTaskConfiguration {
        didSet { persistJSON(key: Keys.aiChatTask, value: aiChatTask) }
    }

    /// 知识库 RAG 的 keyword/vector 后端。默认 SQLite；Meilisearch/Qdrant 只在用户
    /// 自行部署并显式选择后启用，API key 另存 Keychain。
    var ragBackendConfiguration: RAGBackendConfiguration {
        didSet { persistJSON(key: Keys.ragBackendConfiguration, value: ragBackendConfiguration) }
    }

    /// RAG Generator / Planner 可编辑提示词；缺省为英文默认模板 + `{outputLanguage}`。
    var ragPromptSettings: RAGPromptSettings {
        didSet { persistJSON(key: Keys.ragPromptSettings, value: ragPromptSettings) }
    }

    /// RAG 检索的用户可调边界；只影响新建的问答 runtime，不改动已保存的会话分片快照。
    var ragRetrievalSettings: RAGRetrievalSettings {
        didSet { persistJSON(key: Keys.ragRetrievalSettings, value: ragRetrievalSettings.normalized()) }
    }

    /// Rerank 只影响问答/召回测试的候选排序，配置独立于 embedding 与检索后端。
    var ragRerankConfiguration: RAGRerankConfiguration {
        didSet { persistJSON(key: Keys.ragRerankConfiguration, value: ragRerankConfiguration.normalized) }
    }

    /// RAG 的文本推理后端。只切换 Planner / Generator / 压缩 / 标题，不影响
    /// Embedding、Rerank 和其它 AI 功能；CLI 的 Direct 渠道门禁由执行层再次校验。
    var ragInferenceBackend: RAGInferenceBackend {
        didSet { persist(key: Keys.ragInferenceBackend, value: ragInferenceBackend.rawValue) }
    }

    /// RAG 工作台上次选用的聊天模型 ID（`AIModelDescriptor.id`）。
    ///
    /// 空字符串表示从未选过，打开工作台时回退到 `aiChatTask` 对齐的模型。
    /// 只存工作台偏好，不改写全局 chat task，避免 RAG 换模型牵动 AI 助手默认配置。
    var ragWorkspaceSelectedModelID: String {
        didSet { persist(key: Keys.ragWorkspaceSelectedModelID, value: ragWorkspaceSelectedModelID) }
    }

    /// RAG 工作台「调试模式」开关。只持久化开关本身；debug 事件仍只活在当前窗口。
    var ragWorkspaceDebugModeEnabled: Bool {
        didSet { persistBool(key: Keys.ragWorkspaceDebugModeEnabled, value: ragWorkspaceDebugModeEnabled) }
    }

    /// AI 对话历史存储后端。默认 `.jsonFiles`，保留当前 metadata + chunks 写入路径；
    /// 选择 `.sqlite` 后，下一次创建 `DiskChatHistoryStore.shared` 会使用独立 SQLite 文件。
    ///
    /// 关键约束：运行中的 store 不做热切换，避免同一个会话窗口生命周期内一半写 JSON、
    /// 一半写 SQLite。切换设置后重启应用即可使用新后端；迁移以后做显式工具，不自动搬数据。
    var chatHistoryStorageKind: ChatHistoryStorageKind {
        didSet { persist(key: Keys.chatHistoryStorageKind, value: chatHistoryStorageKind.rawValue) }
    }

    /// 搜索栏当前模式。默认 keyword，避免用户未配置 AI 时误触发付费 API。
    var smartSearchMode: SmartSearchMode {
        didSet { persist(key: Keys.smartSearchMode, value: smartSearchMode.rawValue) }
    }

    /// `.all` scope 是否附带外部 Web 结果。
    var externalSearchIncludeInAll: Bool {
        didSet { persistBool(key: Keys.externalSearchIncludeInAll, value: externalSearchIncludeInAll) }
    }

    /// AI 功能是否允许拉取外部 Web 上下文。
    var externalContextEnabled: Bool {
        didSet { persistBool(key: Keys.externalContextEnabled, value: externalContextEnabled) }
    }

    /// 私有仓库是否允许使用外部上下文。
    ///
    /// 即使开启，External Context 也只能发送 repo full name，不能发送 README、notes、
    /// tags 或代码上下文；具体边界由 `ExternalSearchContextProvider` 执行。
    var externalSearchAllowPrivateRepos: Bool {
        didSet { persistBool(key: Keys.externalSearchAllowPrivateRepos, value: externalSearchAllowPrivateRepos) }
    }

    /// SearchCenter Web tab 初始 Provider 与 `.all` scope 使用的默认 Provider。
    var externalSearchDefaultProvider: ExternalSearchProviderID {
        didSet { persist(key: Keys.externalSearchDefaultProvider, value: externalSearchDefaultProvider.rawValue) }
    }

    /// AI External Context 的单 Provider / Automatic 选择。
    var externalContextProviderSelection: ExternalContextProviderSelection {
        didSet { persist(key: Keys.externalContextProviderSelection, value: externalContextProviderSelection.rawValue) }
    }

    /// AI External Context 聚合搜索偏好。
    ///
    /// 该值可被非 Pro 用户保存；真正发请求前仍由运行时 Pro gate 判断，避免订阅过期时
    /// 悄悄改写用户偏好。
    var aggregateExternalContextSearchEnabled: Bool {
        didSet { persistBool(key: Keys.aggregateExternalContextSearchEnabled, value: aggregateExternalContextSearchEnabled) }
    }

    /// 各 Provider 的本机开关、匿名模式、默认结果数和凭据验证标记。
    var externalSearchProviderSettings: [ExternalSearchProviderID: ExternalSearchProviderSettings] {
        didSet { persistJSON(key: Keys.externalSearchProviderSettings, value: externalSearchProviderSettings) }
    }

    // MARK: - AI 代码上下文（2026-06-13 引入，RepoContextPacker 客户端接入阶段 X1）
    //
    // 4 个偏好字段对应 RepoContextPacker 的运行期配置：
    //   1. aiRepoContextEnabled       —— 总开关（默认 true，启用 RepoContextPacker 注入 AI prompt）
    //   2. aiRepoContextTokenBudget   —— Token 预算（默认 8000，范围 4000-32000，控制 XML 体积）
    //   3. aiRepoContextTier1MaxLines —— 关键文件保留行数（默认 80，范围 40-200，对应 `TierTruncation.tier1MaxLines`）
    //   4. aiRepoContextMaximumArchiveMB —— 源码 ZIP 上限（默认 50MB，范围 1-500MB）
    //
    // 设计要点：
    //   - 字段独立于 `externalContextEnabled`（那个是 External Search 检索结果注入）；
    //     两个外部上下文源相互正交，用户可独立开关。
    //   - **不设「私有仓库」开关**：当前 Starcat 的 GitHub OAuth scope 是 `read:user` + `public_repo`，
    //     API 永远不会返回 isPrivate=true 的 repo（用户即便在 GitHub 上 star 了私有仓库，
    //     由于 scope 不含 `repo`，列表也拿不到）。Starcat 还没接管"私有仓库可见性"逻辑，
    //     增加一个永远走不到的开关只会污染设置页并误导用户。

    /// AI 代码上下文总开关。默认开启——这是 P0 价值卖点（让 AI"看到代码"）。
    /// 关闭后 `RepoAIInsightService.makeSource` 跳过 RepoContextPacker 调用，降级为 README-only。
    var aiRepoContextEnabled: Bool {
        didSet { persistBool(key: Keys.aiRepoContextEnabled, value: aiRepoContextEnabled) }
    }

    /// Token 预算上限。Pass 2 BudgetAllocator 严格遵守，Tier 1 超 budget 降级 pathOnly。
    /// 范围 4000-32000，默认 8000——经验值：小型仓库（< 50 文件）能装满，中型仓库（50-200 文件）核心覆盖。
    /// 用户在「关键文件被截断」场景可调大；在 LLM 上下文窗口紧张（gpt-4o-mini 128k 但要省钱）时调小。
    var aiRepoContextTokenBudget: Int {
        didSet { defaults.set(aiRepoContextTokenBudget, forKey: Keys.aiRepoContextTokenBudget) }
    }

    /// 关键文件（Tier 1）头部保留行数。默认 80，对应 `TierTruncation.tier1MaxLines`。
    /// 范围 40-200：40 行只够看 import + 一两个函数签名；200 行能看到中型文件的主结构。
    /// 用户调大会让 Tier 1 单文件估算 token 数翻倍（按 `byteCount × 0.27` 估算）。
    var aiRepoContextTier1MaxLines: Int {
        didSet { defaults.set(aiRepoContextTier1MaxLines, forKey: Keys.aiRepoContextTier1MaxLines) }
    }

    /// AI 代码上下文允许处理的源码 ZIP 上限。
    ///
    /// 单仓 AI 与知识库 RAG 共用该阈值；RepoContextPacker 解压前使用同一运行期上限，
    /// 避免“下载允许、打包仍按固定 100MB 拒绝”的伪配置。CodeFlow / CodebaseMemory
    /// 保留各自独立的安全上限，不读取此偏好。
    static let aiRepoContextMaximumArchiveMBRange = 1...500
    static let defaultAIRepoContextMaximumArchiveMB = 50

    var aiRepoContextMaximumArchiveMB: Int {
        didSet { defaults.set(aiRepoContextMaximumArchiveMB, forKey: Keys.aiRepoContextMaximumArchiveMB) }
    }

    /// 贡献草坪贪吃蛇玩法（HOM-SNAKE-MODES 2026-06-05）。
    /// 默认 `.off`；用户主动选择其他玩法后继续持久化其选择。
    /// 修改时 `ContributionGraphView` 会通过 `.onChange` 重建 animator。
    var snakeStyle: SnakeStyle {
        didSet { persist(key: Keys.snakeStyle, value: snakeStyle.rawValue) }
    }

    /// README / 通知翻译目标语言。
    /// `.auto` 跟随 App 界面语言；具体语言锁定后不再随界面变。
    /// 送给模型、写缓存时用 `effectiveReadmeTranslationLanguage`。
    var readmeTranslationLanguage: ReadmeTranslationLanguage {
        didSet { persist(key: Keys.readmeTranslationLanguage, value: readmeTranslationLanguage.rawValue) }
    }

    var effectiveReadmeTranslationLanguage: ReadmeTranslationLanguage {
        readmeTranslationLanguage.resolved()
    }

    /// README 翻译方式。默认分段翻译；用户可在详情页翻译下拉菜单切换。
    var readmeTranslationMode: ReadmeTranslationMode {
        didSet { persist(key: Keys.readmeTranslationMode, value: readmeTranslationMode.rawValue) }
    }

    /// Undo Star 历史保留天数（2026-07-05）。-1 = 永久不删。
    var undoStarRetentionDays: Int {
        didSet { defaults.set(undoStarRetentionDays, forKey: Keys.undoStarRetentionDays) }
    }

    // MARK: - 无障碍 / 动画（2026-06-15 dong4j 需求）

    /// 「关闭应用内动画」用户偏好。默认 `false`（动画全开）。
    ///
    /// 设计：通过 `AnimationOverrideModifier` 在 root view 上覆盖
    /// `accessibilityReduceMotion` 环境值，让全工程 30+ 个已实现
    /// `@Environment(\.starcatReduceMotion)` 兜底的视图零改动
    /// 自动尊重本设置。与系统「减少动态效果」是 OR 关系。
    /// 详见 `Shared/Components/AnimationOverrideModifier.swift` 文件头。
    ///
    /// **不影响**系统级动画（sheet 弹出 / 窗口切换 / Form 滚动惯性 /
    /// Picker 下拉），那些由 macOS AppKit 驱动 SwiftUI 不参与。
    var disableAnimations: Bool {
        didSet { persistBool(key: Keys.disableAnimations, value: disableAnimations) }
    }

    /// 隐藏 Dock 图标，让 Starcat 以菜单栏常驻入口为主。
    ///
    /// 默认 false：Starcat 仍是普通窗口应用，避免首次安装后用户找不到主入口。
    /// 开启后由 AppKit 切到 `.accessory`；菜单栏图标始终保留，作为恢复主窗口
    /// 和退出应用的固定入口。
    var hideDockIcon: Bool {
        didSet { persistBool(key: Keys.hideDockIcon, value: hideDockIcon) }
    }

    /// 是否允许 Starcat 把全部 starred repositories（含 private 与用户笔记）写入 Spotlight。
    ///
    /// 默认关闭，必须由用户在设置中明确授权。开关变化通过通知交给索引服务处理，
    /// AppSettings 本身不直接触碰 Core Spotlight，避免偏好层承担系统副作用。
    var spotlightSearchEnabled: Bool {
        didSet {
            persistBool(key: Keys.spotlightSearchEnabled, value: spotlightSearchEnabled)
            guard oldValue != spotlightSearchEnabled else { return }
            NotificationCenter.default.post(name: .spotlightSearchPreferenceDidChange, object: nil)
        }
    }

    /// 开启后 AI 多行输入必须按 Command+Return 才发送；普通 Return 始终换行。
    /// 这是输入行为偏好，不属于应用命令快捷键，不受下方总开关或逐项开关影响。
    var aiChatRequiresCommandReturn: Bool {
        didSet { persistBool(key: Keys.aiChatRequiresCommandReturn, value: aiChatRequiresCommandReturn) }
    }

    /// 应用命令快捷键总开关。关闭只停止键盘注册，菜单、toolbar 和详情按钮仍可使用。
    var keyboardShortcutsEnabled: Bool {
        didSet { persistBool(key: Keys.keyboardShortcutsEnabled, value: keyboardShortcutsEnabled) }
    }

    /// 全局搜索入口快捷键，默认 Command+K。值对象在写入设置页前已完成合法性校验。
    var globalSearchShortcut: KeyboardShortcutConfiguration {
        didSet { persistJSON(key: Keys.globalSearchShortcut, value: globalSearchShortcut) }
    }

    var globalSearchShortcutEnabled: Bool {
        didSet { persistBool(key: Keys.globalSearchShortcutEnabled, value: globalSearchShortcutEnabled) }
    }

    /// 列表 toolbar 常规搜索快捷键，默认 Shift+Command+F。展开 SmartSearchField 并聚焦输入框。
    var regularSearchShortcut: KeyboardShortcutConfiguration {
        didSet { persistJSON(key: Keys.regularSearchShortcut, value: regularSearchShortcut) }
    }

    var regularSearchShortcutEnabled: Bool {
        didSet { persistBool(key: Keys.regularSearchShortcutEnabled, value: regularSearchShortcutEnabled) }
    }

    /// README 页内查找快捷键，默认 Command+F。与列表常规搜索拆开，不再按焦点分流。
    var readmeFindShortcut: KeyboardShortcutConfiguration {
        didSet { persistJSON(key: Keys.readmeFindShortcut, value: readmeFindShortcut) }
    }

    var readmeFindShortcutEnabled: Bool {
        didSet { persistBool(key: Keys.readmeFindShortcutEnabled, value: readmeFindShortcutEnabled) }
    }

    /// 刷新当前中栏列表或右栏详情的快捷键，默认 Command+R。
    var refreshCurrentContentShortcut: KeyboardShortcutConfiguration {
        didSet { persistJSON(key: Keys.refreshCurrentContentShortcut, value: refreshCurrentContentShortcut) }
    }

    var refreshCurrentContentShortcutEnabled: Bool {
        didSet {
            persistBool(
                key: Keys.refreshCurrentContentShortcutEnabled,
                value: refreshCurrentContentShortcutEnabled
            )
        }
    }

    /// 打开知识库 RAG 工作台的快捷键，默认 Shift+Command+K。
    var knowledgeRAGShortcut: KeyboardShortcutConfiguration {
        didSet { persistJSON(key: Keys.knowledgeRAGShortcut, value: knowledgeRAGShortcut) }
    }

    var knowledgeRAGShortcutEnabled: Bool {
        didSet { persistBool(key: Keys.knowledgeRAGShortcutEnabled, value: knowledgeRAGShortcutEnabled) }
    }

    /// 打开当前详情仓库 AI 窗口的快捷键，默认 Shift+Command+A。
    var selectedRepoAIShortcut: KeyboardShortcutConfiguration {
        didSet { persistJSON(key: Keys.selectedRepoAIShortcut, value: selectedRepoAIShortcut) }
    }

    var selectedRepoAIShortcutEnabled: Bool {
        didSet { persistBool(key: Keys.selectedRepoAIShortcutEnabled, value: selectedRepoAIShortcutEnabled) }
    }

    // MARK: - 通知（2026-06-20）

    /// 系统通知总开关。只控制 Starcat 主动发出的 macOS 通知，不影响 App 内状态面板。
    var notificationsEnabled: Bool {
        didSet { persistBool(key: Keys.notificationsEnabled, value: notificationsEnabled) }
    }

    /// Release 订阅发现新版本时通知。默认开启，沿用 HOM-47 既有行为。
    var releaseNotificationsEnabled: Bool {
        didSet { persistBool(key: Keys.releaseNotificationsEnabled, value: releaseNotificationsEnabled) }
    }

    /// GitHub 通知 inbox 的高信号系统通知（mention / assign / review / security）。默认开启。
    var githubInboxNotificationsEnabled: Bool {
        didSet { persistBool(key: Keys.githubInboxNotificationsEnabled, value: githubInboxNotificationsEnabled) }
    }

    /// 批量 AI 队列整批结束时通知。单个 repo 完成不通知，避免刷屏。
    var batchAINotificationsEnabled: Bool {
        didSet { persistBool(key: Keys.batchAINotificationsEnabled, value: batchAINotificationsEnabled) }
    }

    /// 同步进入需要用户处理的失败态时通知。普通完成和短暂失败不通知。
    var syncIssueNotificationsEnabled: Bool {
        didSet { persistBool(key: Keys.syncIssueNotificationsEnabled, value: syncIssueNotificationsEnabled) }
    }

    /// MCP Service 启动失败时通知。正常启动 / 停止不通知。
    var mcpIssueNotificationsEnabled: Bool {
        didSet { persistBool(key: Keys.mcpIssueNotificationsEnabled, value: mcpIssueNotificationsEnabled) }
    }

    // MARK: - 活动（2026-08-23）

    /// 通知详情是否混入 GitHub Issue 事件。默认关闭，只显示评论。
    var githubIssueEventTimelineEnabled: Bool {
        didSet { persistBool(key: Keys.githubIssueEventTimelineEnabled, value: githubIssueEventTimelineEnabled) }
    }

    // MARK: - 诊断 / 匿名遥测（2026-06-30）

    /// 是否允许发送匿名使用数据与性能摘要。默认关闭。
    ///
    /// Starcat 是本地优先工具，本开关只放行 allowlist 事件和粗粒度分桶；仓库名、
    /// 搜索词、README、笔记、AI prompt/response、token、API key、本地路径都不允许进入
    /// `TelemetryEvent` schema。MetricKit 首版也只写本地诊断摘要，不上传原始 payload。
    var telemetryEnabled: Bool {
        didSet { persistBool(key: Keys.telemetryEnabled, value: telemetryEnabled) }
    }

    // MARK: - MCP Service（2026-06-20）

    /// 本机 MCP Service 总开关。
    ///
    /// 这里只保存用户意图，真实放行仍必须经过 `EntitlementGate.requirePro(.mcpService)`。
    /// 这样订阅过期时不会因为旧的 UserDefaults 值继续开放本地 agent 入口。
    var mcpServiceEnabled: Bool {
        didSet { persistBool(key: Keys.mcpServiceEnabled, value: mcpServiceEnabled) }
    }

    /// MCP HTTP 监听端口。默认 `defaultMCPServicePort`（5555）。
    var mcpServicePort: Int {
        didSet { defaults.set(mcpServicePort, forKey: Keys.mcpServicePort) }
    }

    /// 是否允许已配对设备从可信网络连接。
    ///
    /// 默认关闭并仅监听 loopback；开启后必须切换为 TLS listener，禁止把现有明文
    /// Bearer endpoint 直接绑定到局域网地址。
    var mcpAllowRemoteConnections: Bool {
        didSet { persistBool(key: Keys.mcpAllowRemoteConnections, value: mcpAllowRemoteConnections) }
    }

    /// 是否允许 MCP 读取用户私有笔记。
    ///
    /// 默认 false：repo 元数据和 README 是低敏只读上下文，私有笔记属于用户主动写入的
    /// 私人数据，必须显式开启才暴露给 agent。
    var mcpExposePrivateNotes: Bool {
        didSet { persistBool(key: Keys.mcpExposePrivateNotes, value: mcpExposePrivateNotes) }
    }

    /// 是否允许 MCP 工具写入本地用户数据（notes / status / tags）。
    ///
    /// 读取与写入分开授权：用户可能愿意让 agent 整理标签和写新笔记，但不希望它读取
    /// 已有私有笔记内容。具体工具仍会在 facade 层做二次校验和审计。
    var mcpAllowLocalWrites: Bool {
        didSet { persistBool(key: Keys.mcpAllowLocalWrites, value: mcpAllowLocalWrites) }
    }

    /// 是否允许 MCP 批量写入。
    ///
    /// P0 先作为权限边界落地；批量工具后续接入时必须走这个开关和单次数量限制。
    var mcpAllowBatchWrites: Bool {
        didSet { persistBool(key: Keys.mcpAllowBatchWrites, value: mcpAllowBatchWrites) }
    }

    /// 是否允许 MCP 执行替换式写入（例如 set_repo_tags）。
    ///
    /// 替换式操作会删除未出现在新集合里的旧关联，比 add/remove 更容易被 agent 误用，
    /// 因此单独开关且默认关闭。
    var mcpAllowDestructiveWrites: Bool {
        didSet { persistBool(key: Keys.mcpAllowDestructiveWrites, value: mcpAllowDestructiveWrites) }
    }

    /// Pro 权益状态镜像（HOM-151 起源于 StoreKit，后续扩展到 Direct License）。
    ///
    /// 真实权益接入后，聚合后的 `CompositeProEntitlementProvider` 是单一真相源，
    /// 本字段只作为 UI 读模型：
    /// - 用户头像右下角 PRO 标识
    /// - 分享卡 / 关于页等不需要直接依赖 StoreKit 的轻量展示
    /// 不允许设置页或功能入口直接写入，避免本地模拟状态绕过真实订阅。
    private(set) var isProUser: Bool {
        didSet { persistBool(key: Keys.isProUser, value: isProUser) }
    }

    // MARK: - AI 向量索引（2026-06-12 引入，决策 C2 / G / E3 落地）
    //
    // 5 个偏好字段对应 `docs/3-设计/详细设计/26-向量搜索改进.md` § 5：
    //   1. aiReadmeTruncateLength —— README 清洗后截断长度（决策 C2，默认 12000，范围 2000-32000）
    //   2. aiIndexPreset           —— 阈值预设（严格 / 标准 / 宽松 / 自定义，决策 G）
    //   3. aiIndexBodyDiffRatio    —— 主体行级 diff 阈值（默认 0.10 = 10%）
    //   4. aiIndexNotesDiffRatio   —— 笔记行级 diff 阈值（默认 0.20 = 20%）
    //   5. aiIndexAutoPrefetchEnabled —— 是否启用后台慢速预拉（默认 false：避免无声烧 API）
    //
    // 设计要点：
    //   - 预设和具体数字独立持久化：用户在 Settings 折叠区改具体数字后，preset 自动设为 `.custom`，
    //     避免"显示『标准』但实际数字不是标准值"的混乱（详见 `applyPresetIfNeeded` 注释）；
    //   - 单一信任源：`thresholds` 计算属性按 `aiIndexPreset` + `aiIndexBodyDiffRatio` /
    //     `aiIndexNotesDiffRatio` 返回最终 `DiffThresholds`，调用方（SemanticSearchService /
    //     SemanticIndexBuilder）只读这个 computed 属性，不直接读字段。

    /// README 清洗后用于 embedding 的最大字符长度（决策 C2）。
    /// 默认 12000；Settings UI 滑杆范围 2000-32000，步进 1000。
    /// 字段直接写入 UserDefaults Int 即可；不需要 JSON 编码。
    var aiReadmeTruncateLength: Int {
        didSet { defaults.set(aiReadmeTruncateLength, forKey: Keys.aiReadmeTruncateLength) }
    }

    /// AI 索引阈值预设（决策 G：严格 / 标准 / 宽松 / 自定义）。
    /// 写入时不会自动覆盖 body / notes 具体数字 —— 由 UI 层在用户主动切换预设时调
    /// `applyPreset(_:)` 完成"预设 → 具体数字"的同步。
    var aiIndexPreset: AIIndexPreset {
        didSet { persist(key: Keys.aiIndexPreset, value: aiIndexPreset.rawValue) }
    }

    /// 主体行级 diff 阈值（0.0 - 1.0）。
    /// 由 UI 折叠区直接编辑；编辑后 `aiIndexPreset` 自动切到 `.custom`。
    var aiIndexBodyDiffRatio: Double {
        didSet { defaults.set(aiIndexBodyDiffRatio, forKey: Keys.aiIndexBodyDiffRatio) }
    }

    /// 笔记行级 diff 阈值（0.0 - 1.0）。同上。
    var aiIndexNotesDiffRatio: Double {
        didSet { defaults.set(aiIndexNotesDiffRatio, forKey: Keys.aiIndexNotesDiffRatio) }
    }

    /// 是否启用后台慢速预拉（决策 E3）。
    /// 默认 **false**：首次切换全量重建代价大，用户应主动在 Settings 启动；
    /// 旧向量保留可读，搜索不中断。
    var aiIndexAutoPrefetchEnabled: Bool {
        didSet { persistBool(key: Keys.aiIndexAutoPrefetchEnabled, value: aiIndexAutoPrefetchEnabled) }
    }

    /// 最近一次向量索引预拉 / 全量重建的时间和计数。
    ///
    /// `SemanticIndexBuilder` 进程内状态关设置页就会回到 idle；设置页要靠这份快照
    /// 显示「上次拉取」时间和记录。暂停不写，只有跑完或整轮失败才更新。
    var semanticIndexLastPrefetch: SemanticIndexPrefetchLastRun? {
        didSet {
            if let semanticIndexLastPrefetch {
                persistJSON(key: Keys.semanticIndexLastPrefetch, value: semanticIndexLastPrefetch)
            } else {
                defaults.removeObject(forKey: Keys.semanticIndexLastPrefetch)
            }
        }
    }

    /// 是否启用 README 后台预拉。
    ///
    /// 默认开启：该任务只处理本地已 star 仓库，单轮限量 + 串行 + 退避冷却，不参与 AI 向量索引，
    /// 目标是让详情页命中本地 HTML / Markdown 缓存，减少用户点开 repo 时的等待。
    var readmePrefetchEnabled: Bool {
        didSet { persistBool(key: Keys.readmePrefetchEnabled, value: readmePrefetchEnabled) }
    }

    /// AI 语义搜索结果过滤阈值（2026-06-13 dong4j 需求 HOM-197）。
    ///
    /// 语义搜索命中分数低于此阈值的 repo 不在列表展示——
    /// 默认 0.75，UI 滑杆范围 0.10 - 1.00、步进 0.01。
    ///
    /// **2026-06-14 单位迁移**：dong4j 决策——判定字段从原始 cosine 改成
    /// `SemanticSearchHit.displayScore`（A 重标定后的经验区间归一值），让
    /// "滑杆 75%" 与 "结果列表 75%" 视觉单位一致。原始 cosine 0.75 ≈
    /// displayScore 0.692，新单位下默认 0.75 实际比旧版稍严，但配合 B 字面 boost / C
    /// FTS 加权后好结果不会被滤掉。
    ///
    /// **生效路径**：`HomeViewModel.applyView()` 在 `isSemanticSearching` 分支里
    /// 对 `view` 做 `removeAll { (semanticHitMap[$0.id]?.displayScore ?? 0) < threshold }`，
    /// 与 hideArchived / hideForks / statusFilter 同串行过滤。
    ///
    /// **为什么不在 SemanticSearchService.search() 里过滤**：拖滑杆改阈值要即时
    /// 生效，但每改一次都重调 embedding API 既慢又烧钱。把过滤放 view 层让
    /// `semanticHitMap` 保留全量 hits，纯本地 re-filter 不动 API。
    ///
    /// 类型为 Double 保持与 `aiIndexBodyDiffRatio` / `aiIndexNotesDiffRatio` 同款，
    /// 持久化也走 UserDefaults double 直存（无需 JSON 编码）。
    var aiSemanticSearchScoreThreshold: Double {
        didSet { defaults.set(aiSemanticSearchScoreThreshold, forKey: Keys.aiSemanticSearchScoreThreshold) }
    }

    /// 计算属性：当前生效的 `DiffThresholds`（单一信任源）。
    ///
    /// - 预设 != `.custom` → 用预设的固定阈值（5/10、10/20、20/30）
    /// - 预设 == `.custom` → 用 body / notes 字段的具体数字
    ///
    /// `SemanticSearchService.ensureIndexed` / `SemanticIndexBuilder` 都通过这里取阈值，
    /// 避免在多个文件里重复"判断预设 + 取阈值"逻辑。
    var aiIndexThresholds: DiffThresholds {
        if aiIndexPreset == .custom {
            return DiffThresholds(
                bodyDiffRatio: aiIndexBodyDiffRatio,
                notesDiffRatio: aiIndexNotesDiffRatio
            )
        }
        return aiIndexPreset.thresholds
    }

    /// 把预设切换到 `preset`，同时同步 body / notes 具体数字字段（保证 Settings UI
    /// 折叠区的数字与预设一致）。`custom` 时不改具体字段。
    func applyAIIndexPreset(_ preset: AIIndexPreset) {
        aiIndexPreset = preset
        if preset != .custom {
            let t = preset.thresholds
            aiIndexBodyDiffRatio = t.bodyDiffRatio
            aiIndexNotesDiffRatio = t.notesDiffRatio
        }
    }

    /// HOM-126：自动后台 AI 整理偏好 + 运行态。
    ///
    /// 走 UserDefaults JSON 持久化（与 `aiSummaryTask` 同款）；任何字段变更（开关、阈值、
    /// 排序、运行结果回写）触发整体重写。设计取舍：
    /// - **不拆字段**：自动整理是一个高度耦合的小集合（开关 + 触发 + 范围 + 操作 + 阈值
    ///   + 运行态），把它们拆成 10 个独立 didSet 字段会让 `AutoTidyScheduler` 与 UI
    ///   订阅路径凌乱；统一在 `AutoTidySettings` 结构体里，写入一次完成同步。
    /// - **每次 didSet 都写整段 JSON**：偏好结构体很小（几十字节），重写代价可忽略；
    ///   换来的好处是任何字段变更都不会与并发写入产生半截状态。
    ///
    /// 调度器 `AutoTidyScheduler` 在结束一轮时也走这个 setter 回写 `lastRunAt /
    /// lastRunStats`，让设置页「运行状态」只读区实时更新。
    var autoTidySettings: AutoTidySettings {
        didSet { persistJSON(key: Keys.autoTidySettings, value: autoTidySettings) }
    }

    /// GitHub Lists 后台自动分组偏好。它会触发 GitHub 远端写入，因此必须与仅写本地
    /// 标签/摘要的 `autoTidySettings` 使用不同 key，避免一个 Toggle 改动另一项能力。
    var githubStarListAutoGroupingSettings: GitHubStarListAutoGroupingSettings {
        didSet {
            persistJSON(
                key: Keys.githubStarListAutoGroupingSettings,
                value: githubStarListAutoGroupingSettings
            )
        }
    }

    // MARK: - 第三方服务自定义 URL（2026-06-08 新增）

    /// 第三方后端服务（Trending / Weekly / Sharing / Wiki）的用户自定义 URL 字典。
    ///
    /// 设计要点：
    /// - 键 = `ThirdPartyService.rawValue`（"trending" / "weekly" / "sharing" / "wiki"）。
    ///   用字符串而非直接用枚举做键是为了兼容 `Codable` 持久化 + 让 UserDefaults 直接吃
    ///   `[String: String]`；同时未来新增 service 不需要做迁移。
    /// - 值 = 用户填入的 URL 原始字符串（已通过 `ThirdPartyService.validate` 校验）。
    ///   存原始字符串而不是 `URL` 是因为：① UserDefaults 不直接支持 URL 字典；
    ///   ② 用户填的可能在写入时合法、未来某次升级 URL 解析规则变严就读不出来——
    ///   存原始字符串至少能让设置页"显示出原值给用户修复"。
    /// - **缺省 / 空字符串 / 不存在键 = 走 production 默认 URL**（见 `AppEndpoints`）。
    ///
    /// 任何写入都触发整段 JSON 重写——字典本身极小（3-5 条 KV），重写成本可忽略。
    /// 写入路径只走 `setCustomURL(_:for:)` / `resetCustomURL(for:)` 两个方法，**不要**
    /// 直接 mutate 字典（didSet 会触发，但语义不直观）。
    private(set) var customServiceURLs: [String: String] {
        didSet { persistJSON(key: Keys.customServiceURLs, value: customServiceURLs) }
    }

    /// 读取某服务当前的用户自定义 URL 字符串；未配置返回 nil（让上层回退到默认）。
    func customServiceURL(for service: ThirdPartyService) -> String? {
        let raw = customServiceURLs[service.rawValue]
        // 把空字符串也当作未配置——避免"用户把输入清空但 didSet 留下个空串"留下歧义。
        return (raw?.isEmpty == false) ? raw : nil
    }

    /// 写入某服务的自定义 URL。传 nil 或空字符串等价于调 `resetCustomURL(for:)`。
    ///
    /// 调用方应该是 `AppDependencies.setServiceURL(_:for:)`，它会同时：
    /// ① 把字符串写到这里持久化；② 把规范化后的 `URL` 推送到对应 API actor 的
    /// `updateBaseURL`，让"修改即生效"无需重启。
    func setCustomURL(_ url: String?, for service: ThirdPartyService) {
        let trimmed = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        var copy = customServiceURLs
        if let trimmed, !trimmed.isEmpty {
            copy[service.rawValue] = trimmed
        } else {
            copy.removeValue(forKey: service.rawValue)
        }
        customServiceURLs = copy
    }

    /// 清空某服务的自定义 URL（回退到 production 默认）。
    func resetCustomURL(for service: ThirdPartyService) {
        setCustomURL(nil, for: service)
    }

    // MARK: - 第三方服务 API Key（R-01 v1.2 2026-06-09 引入 / 2026-06-10 迁 Keychain）
    //
    // 自建后端（trending / weekly / sharing / wiki / recommend）改造后强制 Bearer Token 鉴权，前端
    // 必须在 Authorization 头里塞 `Bearer <api-key>`，否则任何 /api/v1/* 请求 401。
    //
    // 持久化方式（**2026-06-10 已迁 Keychain**）：
    //   - **真值**：`KeychainManaging.storeServiceAPIKey(_:forService:)` 加密本地文件
    //     （`Starcat/Core/Keychain/KeychainManager.swift`，AES-GCM）
    //   - **内存缓存**：`customServiceAPIKeysCache` 字典让 `customServiceAPIKey(for:)`
    //     同步读不抛错（@Observable 字段 + 高频调用：API actor 注入 / Resolver 解析 /
    //     UI 设置页 binding 双向都需要同步访问）
    //   - **启动期一次性迁移**：init 时检测 UserDefaults 旧 key（`Keys.customServiceAPIKeys`），
    //     如有值则逐个写入 Keychain → 删 UserDefaults 旧 key → 内存缓存填充
    //
    // 设计要点：
    //   - 新写入路径绝不再走 UserDefaults（`persistJSON` 调用已删除）
    //   - 读取顺序：内存缓存优先 → 缓存 miss 时回退 Keychain（迁移完成后理论上不会 miss，
    //     但保险起见保留以应对「测试期手动写 Keychain 后未刷缓存」场景）

    /// 内存缓存：service rawValue → API key（已 trim 后非空字符串；空字符串等价不存在键）。
    ///
    /// `@Observable` 触发：本字段是 var 但不直接赋值，由 `setCustomAPIKey` 内部走 mutating
    /// 路径触发观察者。读取入口是 `customServiceAPIKey(for:)`（同步方法）。
    private var customServiceAPIKeysCache: [String: String] = [:]

    /// 读取某服务当前的用户自定义 API Key；未配置返回 nil（让上层回退到 production 默认）。
    ///
    /// - 内存缓存命中 → 直接返回（典型路径，零 keychain I/O）
    /// - 内存缓存 miss → 尝试从 Keychain 读，命中即填回缓存（应付测试期外部直接写 Keychain
    ///   或 init 期迁移失败的边角场景）
    func customServiceAPIKey(for service: ThirdPartyService) -> String? {
        if let cached = customServiceAPIKeysCache[service.rawValue], !cached.isEmpty {
            return cached
        }
        // miss 路径：从 keychain 拉 + 回填缓存。任何 throw / nil 都视为「未配置」。
        guard let raw = try? keychain.loadServiceAPIKey(forService: service.rawValue),
              !raw.isEmpty else {
            return nil
        }
        customServiceAPIKeysCache[service.rawValue] = raw
        return raw
    }

    /// 写入某服务的自定义 API Key。传 nil 或空字符串等价于调 `resetCustomAPIKey(for:)`。
    ///
    /// 双写：先更新 Keychain（持久化），再更新内存缓存（让本 @Observable 字段触发 view 更新）。
    /// Keychain 写失败 → 缓存不变 + 走 AppLog 记录；UI 侧仍能从旧值读到，避免「点击保存看似成功
    /// 但下次启动消失」的更糟体验。
    func setCustomAPIKey(_ key: String?, for service: ThirdPartyService) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmed, !trimmed.isEmpty {
            do {
                try keychain.storeServiceAPIKey(trimmed, forService: service.rawValue)
                customServiceAPIKeysCache[service.rawValue] = trimmed
            } catch {
                AppLog.keychain.error("setCustomAPIKey store failed for \(service.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        } else {
            do {
                try keychain.deleteServiceAPIKey(forService: service.rawValue)
                customServiceAPIKeysCache.removeValue(forKey: service.rawValue)
            } catch {
                AppLog.keychain.error("setCustomAPIKey delete failed for \(service.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 清空某服务的自定义 API Key（回退到 production 默认）。
    func resetCustomAPIKey(for service: ThirdPartyService) {
        setCustomAPIKey(nil, for: service)
    }

    /// 全部已配置 BYOK 服务 ID 列表（仅供 UI 调试 / 设置页快速浏览用）。
    var configuredCustomAPIKeyServiceIDs: [String] {
        Array(customServiceAPIKeysCache.keys)
    }

    // MARK: - 初始化

    private let defaults: UserDefaults
    private let keychain: any KeychainManaging

    /// - Parameters:
    ///   - defaults: 注入点，便于测试用 `UserDefaults(suiteName:)` 隔离。
    ///   - keychain: 安全存储后端，用于持久化 BYOK API Key（R-01 v1.2 2026-06-10 引入）。
    ///     默认 `KeychainManager.shared`；测试可注入 `InMemoryKeychain` 避免污染本地文件。
    init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainManaging = KeychainManager.shared
    ) {
        self.defaults = defaults
        self.keychain = keychain

        // W4-5 D1:外观主题。dong4j 2026-06-03 决定默认深色(`.dark`),
        // 历史用户(首次升级到本版)若无落盘值,也会落到 `.dark`,跟新用户一致。
        let appearanceRaw = defaults.string(forKey: Keys.appearanceMode)
        self.appearanceMode = appearanceRaw.flatMap(AppearanceMode.init(rawValue:)) ?? .dark

        let interfaceScaleRaw = defaults.string(forKey: Keys.interfaceScale)
        self.interfaceScale = interfaceScaleRaw.flatMap(InterfaceScale.init(rawValue:)) ?? .standard
        self.readmeFontSizeAdjustment = Self.clampedReadmeFontSizeAdjustment(
            defaults.object(forKey: Keys.readmeFontSizeAdjustment) as? Int ?? 0
        )

        // R-01 §3.1.1（2026-06-10 P1）：RepoListDensity 已删除，无需读取
        // settings.repoListDensity（旧持久化值在升级后会被 UserDefaults 自然忽略）。

        let sortRaw = defaults.string(forKey: Keys.repoSortOption)
        self.repoSortOption = sortRaw.flatMap(RepoSortOption.init(rawValue:)) ?? .starredAtDesc

        // Bool 默认值用 object(forKey:) 判 nil；防止 `bool(forKey:)` 把缺失也当 false
        self.hideArchived = defaults.object(forKey: Keys.hideArchived) as? Bool ?? false
        self.hideForks = defaults.object(forKey: Keys.hideForks) as? Bool ?? false

        // W4-4 D3：空字符串表示 nil(无过滤);非空字符串走 RepoStatus.parse(lenient),
        // v1 旧值 reading/deprecated 自动回落到 .read，老用户重启后过滤不丢失。
        let statusRaw = defaults.string(forKey: Keys.statusFilter) ?? ""
        self.statusFilter = statusRaw.isEmpty ? nil : RepoStatus.parse(statusRaw)

        let starRaw = defaults.string(forKey: Keys.starFilter)
        self.starFilter = RepoStarFilter.parse(starRaw)

        let libraryRaw = defaults.string(forKey: Keys.libraryFilter)
        self.libraryFilter = RepoLibraryFilter.parse(libraryRaw)

        let languageRaw = defaults.string(forKey: Keys.repoLanguageFilter)
        self.repoLanguageFilter = RepoLanguageFilter.parse(languageRaw)

        self.interestedLanguages = Self.decodeJSON(
            [String].self,
            key: Keys.interestedLanguages,
            defaults: defaults
        ).map(Self.normalizedLanguageList) ?? []
        self.globalFilterLanguages = Self.decodeJSON(
            [String].self,
            key: Keys.globalFilterLanguages,
            defaults: defaults
        ).map(Self.normalizedLanguageList) ?? []
        self.wikiAvailabilityFilter = defaults.string(forKey: Keys.wikiAvailabilityFilter)
            .flatMap(RepoSignalAvailabilityFilter.init(rawValue:)) ?? .unknown
        self.healthAvailabilityFilter = defaults.string(forKey: Keys.healthAvailabilityFilter)
            .flatMap(RepoSignalAvailabilityFilter.init(rawValue:)) ?? .unknown
        self.openSSFAvailabilityFilter = defaults.string(forKey: Keys.openSSFAvailabilityFilter)
            .flatMap(RepoSignalAvailabilityFilter.init(rawValue:)) ?? .unknown

        // 上次 Manage 分类：缺失则空串，由 SidebarItem 解码时回落 allStars
        self.lastManageSelectionRaw = defaults.string(forKey: Keys.lastManageSelection) ?? ""

        // 上次 Activity 分类：缺失则空串，由 ActivityCategory 解码时回落 all
        self.lastActivityCategoryRaw = defaults.string(forKey: Keys.lastActivityCategory) ?? ""

        self.listPreferenceValues = Self.decodeJSON(
            [String: String].self,
            key: Keys.listPreferenceValues,
            defaults: defaults
        ) ?? [:]

        self.openFirstDetailOnCategoryChange = defaults.object(
            forKey: Keys.openFirstDetailOnCategoryChange
        ) as? Bool ?? false
        self.openRepositoryMarkdownInApp = defaults.object(
            forKey: Keys.openRepositoryMarkdownInApp
        ) as? Bool ?? false

        let aiProviderRaw = defaults.string(forKey: Keys.aiProvider)
        let resolvedAIProvider = aiProviderRaw.flatMap(AIServiceProvider.init(rawValue:)) ?? .openAICompatible
        let resolvedAIBaseURL = defaults.string(forKey: Keys.aiBaseURL) ?? resolvedAIProvider.defaultBaseURL
        let resolvedAIChatModel = defaults.string(forKey: Keys.aiChatModel) ?? resolvedAIProvider.defaultChatModel
        let resolvedAIEmbeddingModel = defaults.string(forKey: Keys.aiEmbeddingModel) ?? resolvedAIProvider.defaultEmbeddingModel
        self.aiProvider = resolvedAIProvider
        self.aiBaseURL = resolvedAIBaseURL
        self.aiChatModel = resolvedAIChatModel
        self.aiEmbeddingModel = resolvedAIEmbeddingModel
        let defaultProfile = Self.makeDefaultAIProviderProfile(
            provider: resolvedAIProvider,
            baseURL: resolvedAIBaseURL,
            chatModel: resolvedAIChatModel,
            embeddingModel: resolvedAIEmbeddingModel
        )
        let profiles = Self.decodeJSON([AIProviderProfile].self, key: Keys.aiProviderProfiles, defaults: defaults) ?? []
        self.aiProviderProfiles = profiles.isEmpty ? [defaultProfile] : profiles
        let defaultSummaryTask = Self.makeDefaultTask(
            task: .summary,
            profileID: defaultProfile.id,
            modelName: resolvedAIChatModel
        )
        let defaultTagsTask = Self.makeDefaultTask(
            task: .tags,
            profileID: defaultProfile.id,
            modelName: resolvedAIChatModel
        )
        let defaultEmbeddingTask = Self.makeDefaultTask(
            task: .embedding,
            profileID: defaultProfile.id,
            modelName: resolvedAIEmbeddingModel
        )
        let persistedSummaryTask = Self.decodeJSON(
            AIModelTaskConfiguration.self,
            key: Keys.aiSummaryTask,
            defaults: defaults
        ) ?? defaultSummaryTask
        self.aiSummaryTask = Self.migrateLegacyDefaultSummaryPromptIfNeeded(
            persistedSummaryTask,
            defaults: defaults
        )
        let persistedTagsTask = Self.decodeJSON(
            AIModelTaskConfiguration.self,
            key: Keys.aiTagsTask,
            defaults: defaults
        ) ?? defaultTagsTask
        self.aiTagsTask = Self.migrateLegacyDefaultTagsPromptIfNeeded(
            persistedTagsTask,
            defaults: defaults
        )
        self.aiEmbeddingTask = Self.decodeJSON(AIModelTaskConfiguration.self, key: Keys.aiEmbeddingTask, defaults: defaults) ?? defaultEmbeddingTask
        // HOM-68 follow-up：翻译任务首次升级时与摘要使用同一 provider+model，
        // 参数走 translationDefault（低温度 + 高 maxToken），用户可在设置页改。
        let defaultTranslationTask = Self.makeDefaultTask(
            task: .translation,
            profileID: defaultProfile.id,
            modelName: resolvedAIChatModel
        )
        let persistedTranslationTask = Self.decodeJSON(
            AIModelTaskConfiguration.self,
            key: Keys.aiTranslationTask,
            defaults: defaults
        ) ?? defaultTranslationTask
        self.aiTranslationTask = Self.migrateLegacyDefaultTranslationPromptIfNeeded(
            persistedTranslationTask,
            defaults: defaults
        )
        self.aiFullTranslationPrompt = Self.decodeJSON(
            AIPromptConfiguration.self,
            key: Keys.aiFullTranslationPrompt,
            defaults: defaults
        ) ?? AIDefaultPrompts.fullTranslation
        // 2026-06-14 v4：对话任务首次升级时与摘要使用同一 provider+model + summaryDefault
        // 参数（chat 跟摘要场景接近，参数没必要再分一套）。老用户没有 aiChatTask key →
        // decode 失败 fallback 到默认值，行为跟之前"复用 aiSummaryTask"基本等价（model 一致），
        // 唯一区别是 system prompt 现在走 AIDefaultPrompts.chat 模板（用户可在设置页改）。
        let defaultChatTask = Self.makeDefaultTask(
            task: .chat,
            profileID: defaultProfile.id,
            modelName: resolvedAIChatModel
        )
        let persistedChatTask = Self.decodeJSON(
            AIModelTaskConfiguration.self,
            key: Keys.aiChatTask,
            defaults: defaults
        ) ?? defaultChatTask
        self.aiChatTask = Self.migrateLegacyDefaultChatPromptIfNeeded(
            persistedChatTask,
            defaults: defaults
        )
        self.ragBackendConfiguration = Self.decodeJSON(
            RAGBackendConfiguration.self,
            key: Keys.ragBackendConfiguration,
            defaults: defaults
        ) ?? RAGBackendConfiguration()
        self.ragPromptSettings = Self.decodeJSON(
            RAGPromptSettings.self,
            key: Keys.ragPromptSettings,
            defaults: defaults
        ) ?? .default
        self.ragRetrievalSettings = (Self.decodeJSON(
            RAGRetrievalSettings.self,
            key: Keys.ragRetrievalSettings,
            defaults: defaults
        ) ?? .balanced).normalized()
        self.ragRerankConfiguration = (Self.decodeJSON(
            RAGRerankConfiguration.self,
            key: Keys.ragRerankConfiguration,
            defaults: defaults
        ) ?? RAGRerankConfiguration()).normalized
        self.ragInferenceBackend = defaults.string(forKey: Keys.ragInferenceBackend)
            .flatMap(RAGInferenceBackend.init(rawValue:)) ?? .api
        self.ragWorkspaceSelectedModelID = defaults.string(forKey: Keys.ragWorkspaceSelectedModelID) ?? ""
        self.ragWorkspaceDebugModeEnabled = defaults.object(forKey: Keys.ragWorkspaceDebugModeEnabled) as? Bool ?? false
        let chatHistoryStorageRaw = defaults.string(forKey: Keys.chatHistoryStorageKind)
        self.chatHistoryStorageKind = chatHistoryStorageRaw.flatMap(ChatHistoryStorageKind.init(rawValue:)) ?? .jsonFiles
        let searchModeRaw = defaults.string(forKey: Keys.smartSearchMode)
        self.smartSearchMode = searchModeRaw.flatMap(SmartSearchMode.init(rawValue:)) ?? .keyword
        self.externalSearchIncludeInAll = defaults.object(forKey: Keys.externalSearchIncludeInAll) as? Bool ?? false
        self.externalContextEnabled = defaults.object(forKey: Keys.externalContextEnabled) as? Bool ?? false
        self.externalSearchAllowPrivateRepos = defaults.object(forKey: Keys.externalSearchAllowPrivateRepos) as? Bool ?? false
        let externalDefaultProviderRaw = defaults.string(forKey: Keys.externalSearchDefaultProvider)
        self.externalSearchDefaultProvider = externalDefaultProviderRaw
            .flatMap(ExternalSearchProviderID.init(rawValue:)) ?? .anySearch
        let externalContextSelectionRaw = defaults.string(forKey: Keys.externalContextProviderSelection)
        self.externalContextProviderSelection = externalContextSelectionRaw
            .flatMap(ExternalContextProviderSelection.init(rawValue:)) ?? .automatic
        self.aggregateExternalContextSearchEnabled = defaults.object(
            forKey: Keys.aggregateExternalContextSearchEnabled
        ) as? Bool ?? false
        self.externalSearchProviderSettings = Self.normalizedExternalSearchProviderSettings(
            Self.decodeJSON(
                [ExternalSearchProviderID: ExternalSearchProviderSettings].self,
                key: Keys.externalSearchProviderSettings,
                defaults: defaults
            )
        )
        // RepoContextPacker 客户端配置：
        // 总开关默认 true；token budget 默认 8000 / Tier 1 行数默认 80 / ZIP 上限默认 50MB
        // 与 RepoContextPacker `PackInput.tokenBudget` / `TierTruncation.tier1MaxLines` 缺省值对齐。
        self.aiRepoContextEnabled = defaults.object(forKey: Keys.aiRepoContextEnabled) as? Bool ?? true
        self.aiRepoContextTokenBudget = defaults.object(forKey: Keys.aiRepoContextTokenBudget) as? Int ?? 8000
        self.aiRepoContextTier1MaxLines = defaults.object(forKey: Keys.aiRepoContextTier1MaxLines) as? Int ?? 80
        let storedMaximumArchiveMB = defaults.object(forKey: Keys.aiRepoContextMaximumArchiveMB) as? Int
            ?? Self.defaultAIRepoContextMaximumArchiveMB
        self.aiRepoContextMaximumArchiveMB = min(
            max(storedMaximumArchiveMB, Self.aiRepoContextMaximumArchiveMBRange.lowerBound),
            Self.aiRepoContextMaximumArchiveMBRange.upperBound
        )

        let snakeStyleRaw = defaults.string(forKey: Keys.snakeStyle)
        self.snakeStyle = snakeStyleRaw.flatMap(SnakeStyle.init(rawValue:)) ?? SnakeStyle.default

        // 老用户已有持久化值（含具体语言）→ 保留；首次启动 → `.auto`（跟随界面语言）。
        let translationLangRaw = defaults.string(forKey: Keys.readmeTranslationLanguage)
        self.readmeTranslationLanguage = translationLangRaw
            .flatMap(ReadmeTranslationLanguage.init(rawValue:))
            ?? .auto
        let translationModeRaw = defaults.string(forKey: Keys.readmeTranslationMode)
        self.readmeTranslationMode = translationModeRaw
            .flatMap(ReadmeTranslationMode.init(rawValue:))
            ?? .segmented

        let retentionDays = defaults.integer(forKey: Keys.undoStarRetentionDays)
        self.undoStarRetentionDays = retentionDays == 0 ? 7 : retentionDays  // 首次默认 7 天

        self.isProUser = defaults.object(forKey: Keys.isProUser) as? Bool ?? false

        // 2026-06-15:无障碍——「关闭应用内动画」用户偏好。
        // 缺失值时默认 false(动画全开),老用户首启不受影响。
        self.disableAnimations = defaults.object(forKey: Keys.disableAnimations) as? Bool ?? false
        self.hideDockIcon = defaults.object(forKey: Keys.hideDockIcon) as? Bool ?? false
        self.spotlightSearchEnabled = defaults.object(forKey: Keys.spotlightSearchEnabled) as? Bool ?? false
        self.aiChatRequiresCommandReturn = defaults.object(forKey: Keys.aiChatRequiresCommandReturn) as? Bool ?? false
        self.keyboardShortcutsEnabled = defaults.object(forKey: Keys.keyboardShortcutsEnabled) as? Bool ?? true
        self.globalSearchShortcutEnabled = defaults.object(forKey: Keys.globalSearchShortcutEnabled) as? Bool ?? true
        self.regularSearchShortcutEnabled = defaults.object(forKey: Keys.regularSearchShortcutEnabled) as? Bool ?? true
        self.readmeFindShortcutEnabled = defaults.object(forKey: Keys.readmeFindShortcutEnabled) as? Bool ?? true
        self.refreshCurrentContentShortcutEnabled = defaults.object(
            forKey: Keys.refreshCurrentContentShortcutEnabled
        ) as? Bool ?? true
        self.knowledgeRAGShortcutEnabled = defaults.object(forKey: Keys.knowledgeRAGShortcutEnabled) as? Bool ?? true
        self.selectedRepoAIShortcutEnabled = defaults.object(forKey: Keys.selectedRepoAIShortcutEnabled) as? Bool ?? true

        let storedSearchShortcut = Self.decodeJSON(
            KeyboardShortcutConfiguration.self,
            key: Keys.globalSearchShortcut,
            defaults: defaults
        )
        let storedRegularSearchShortcut = Self.decodeJSON(
            KeyboardShortcutConfiguration.self,
            key: Keys.regularSearchShortcut,
            defaults: defaults
        )
        let storedReadmeFindShortcut = Self.decodeJSON(
            KeyboardShortcutConfiguration.self,
            key: Keys.readmeFindShortcut,
            defaults: defaults
        )
        let storedRefreshShortcut = Self.decodeJSON(
            KeyboardShortcutConfiguration.self,
            key: Keys.refreshCurrentContentShortcut,
            defaults: defaults
        )
        let storedKnowledgeRAGShortcut = Self.decodeJSON(
            KeyboardShortcutConfiguration.self,
            key: Keys.knowledgeRAGShortcut,
            defaults: defaults
        )
        let storedSelectedRepoAIShortcut = Self.decodeJSON(
            KeyboardShortcutConfiguration.self,
            key: Keys.selectedRepoAIShortcut,
            defaults: defaults
        )

        let resolvedSearchShortcut = storedSearchShortcut.flatMap {
            $0.validationError == nil ? $0 : nil
        } ?? .globalSearchDefault
        let resolvedRegularSearchShortcut: KeyboardShortcutConfiguration = {
            guard let stored = storedRegularSearchShortcut, stored.validationError == nil else {
                return .regularSearchDefault
            }
            // 旧默认是 ⌘F。拆出 README 搜索后列表搜索改成 ⌘⇧F；仍存着旧默认的用户视为未自定义，
            // 否则会和新的 README ⌘F 撞车，把六项一起重置。
            if stored == KeyboardShortcutConfiguration.legacyRegularSearchDefault {
                return .regularSearchDefault
            }
            return stored
        }()
        let resolvedReadmeFindShortcut = storedReadmeFindShortcut.flatMap {
            $0.validationError == nil ? $0 : nil
        } ?? StarcatShortcutCatalog.readmeFindDefault
        let resolvedRefreshShortcut = storedRefreshShortcut.flatMap {
            $0.validationError == nil ? $0 : nil
        } ?? StarcatShortcutCatalog.refreshCurrentContentDefault
        let resolvedKnowledgeRAGShortcut = storedKnowledgeRAGShortcut.flatMap {
            $0.validationError == nil ? $0 : nil
        } ?? StarcatShortcutCatalog.openKnowledgeRAGDefault
        let resolvedSelectedRepoAIShortcut = storedSelectedRepoAIShortcut.flatMap {
            $0.validationError == nil ? $0 : nil
        } ?? StarcatShortcutCatalog.openSelectedRepoAIDefault

        let resolvedShortcuts = [
            resolvedSearchShortcut,
            resolvedRegularSearchShortcut,
            resolvedReadmeFindShortcut,
            resolvedRefreshShortcut,
            resolvedKnowledgeRAGShortcut,
            resolvedSelectedRepoAIShortcut
        ]

        // 六项应用命令始终保持唯一，即使某项暂时关闭也不能占用另一项键位。
        // 这样重新开启时不会突然产生两个命令竞争；遇到手工篡改或旧版本重复值时，
        // 六项一起恢复默认，比静默偏袒其中一个动作更可预测。
        if Set(resolvedShortcuts).count != resolvedShortcuts.count {
            self.globalSearchShortcut = .globalSearchDefault
            self.regularSearchShortcut = .regularSearchDefault
            self.readmeFindShortcut = StarcatShortcutCatalog.readmeFindDefault
            self.refreshCurrentContentShortcut = StarcatShortcutCatalog.refreshCurrentContentDefault
            self.knowledgeRAGShortcut = StarcatShortcutCatalog.openKnowledgeRAGDefault
            self.selectedRepoAIShortcut = StarcatShortcutCatalog.openSelectedRepoAIDefault
        } else {
            self.globalSearchShortcut = resolvedSearchShortcut
            self.regularSearchShortcut = resolvedRegularSearchShortcut
            self.readmeFindShortcut = resolvedReadmeFindShortcut
            self.refreshCurrentContentShortcut = resolvedRefreshShortcut
            self.knowledgeRAGShortcut = resolvedKnowledgeRAGShortcut
            self.selectedRepoAIShortcut = resolvedSelectedRepoAIShortcut
        }
        self.notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        self.releaseNotificationsEnabled = defaults.object(forKey: Keys.releaseNotificationsEnabled) as? Bool ?? true
        self.githubInboxNotificationsEnabled = defaults.object(forKey: Keys.githubInboxNotificationsEnabled) as? Bool ?? true
        self.batchAINotificationsEnabled = defaults.object(forKey: Keys.batchAINotificationsEnabled) as? Bool ?? true
        self.syncIssueNotificationsEnabled = defaults.object(forKey: Keys.syncIssueNotificationsEnabled) as? Bool ?? true
        self.mcpIssueNotificationsEnabled = defaults.object(forKey: Keys.mcpIssueNotificationsEnabled) as? Bool ?? true
        self.githubIssueEventTimelineEnabled = defaults.object(forKey: Keys.githubIssueEventTimelineEnabled) as? Bool ?? false
        self.telemetryEnabled = defaults.object(forKey: Keys.telemetryEnabled) as? Bool ?? false
        self.mcpServiceEnabled = defaults.object(forKey: Keys.mcpServiceEnabled) as? Bool ?? false
        let storedMCPPort = defaults.object(forKey: Keys.mcpServicePort) as? Int ?? Self.defaultMCPServicePort
        self.mcpServicePort = (1024...65535).contains(storedMCPPort) ? storedMCPPort : Self.defaultMCPServicePort
        self.mcpAllowRemoteConnections = defaults.object(forKey: Keys.mcpAllowRemoteConnections) as? Bool ?? false
        self.mcpExposePrivateNotes = defaults.object(forKey: Keys.mcpExposePrivateNotes) as? Bool ?? false
        self.mcpAllowLocalWrites = defaults.object(forKey: Keys.mcpAllowLocalWrites) as? Bool ?? false
        self.mcpAllowBatchWrites = defaults.object(forKey: Keys.mcpAllowBatchWrites) as? Bool ?? false
        self.mcpAllowDestructiveWrites = defaults.object(forKey: Keys.mcpAllowDestructiveWrites) as? Bool ?? false

        // HOM-126：自动整理偏好。缺失时回落到 `AutoTidySettings.default`（总开关关 +
        // 启动/同步触发 + 50 个 + 最近 star + 仅标签 + 90% 阈值），与任务描述一致。
        self.autoTidySettings = Self.decodeJSON(AutoTidySettings.self, key: Keys.autoTidySettings, defaults: defaults) ?? .default
        let storedGroupingSettings = Self.decodeJSON(
            GitHubStarListAutoGroupingSettings.self,
            key: Keys.githubStarListAutoGroupingSettings,
            defaults: defaults
        )
        let migratedGroupingSettings = GitHubStarListAutoGroupingSettings.migratedFromLegacyAutoTidyJSON(
            defaults.string(forKey: Keys.autoTidySettings)
        )
        let resolvedGroupingSettings = storedGroupingSettings
            ?? migratedGroupingSettings
            ?? .default
        self.githubStarListAutoGroupingSettings = resolvedGroupingSettings
        // 迁移只写新 key，不回写旧 AutoTidy JSON；新类型解码本来就会忽略遗留字段。
        if storedGroupingSettings == nil,
           let data = try? JSONEncoder().encode(resolvedGroupingSettings) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Keys.githubStarListAutoGroupingSettings)
        }

        // AI 向量索引（2026-06-12）：截断长度 / 阈值预设 / 主体阈值 / 笔记阈值 / 自动预拉。
        // 缺失值兜底：截断 12000、预设 .standard、body 10%、notes 20%、自动预拉 false。
        let truncRaw = defaults.object(forKey: Keys.aiReadmeTruncateLength) as? Int
        self.aiReadmeTruncateLength = truncRaw ?? ReadmePreprocessor.defaultMaxLength
        let presetRaw = defaults.string(forKey: Keys.aiIndexPreset)
        self.aiIndexPreset = presetRaw.flatMap(AIIndexPreset.init(rawValue:)) ?? .standard
        let bodyRatioRaw = defaults.object(forKey: Keys.aiIndexBodyDiffRatio) as? Double
        self.aiIndexBodyDiffRatio = bodyRatioRaw ?? DiffThresholds.default.bodyDiffRatio
        let notesRatioRaw = defaults.object(forKey: Keys.aiIndexNotesDiffRatio) as? Double
        self.aiIndexNotesDiffRatio = notesRatioRaw ?? DiffThresholds.default.notesDiffRatio
        self.aiIndexAutoPrefetchEnabled = defaults.object(forKey: Keys.aiIndexAutoPrefetchEnabled) as? Bool ?? false
        self.semanticIndexLastPrefetch = Self.decodeJSON(
            SemanticIndexPrefetchLastRun.self,
            key: Keys.semanticIndexLastPrefetch,
            defaults: defaults
        )
        self.readmePrefetchEnabled = defaults.object(forKey: Keys.readmePrefetchEnabled) as? Bool ?? true
        // HOM-197：语义搜索过滤阈值默认 0.75；老用户首启缺 key 走默认。
        let semScoreRaw = defaults.object(forKey: Keys.aiSemanticSearchScoreThreshold) as? Double
        self.aiSemanticSearchScoreThreshold = semScoreRaw ?? 0.75

        // 第三方服务自定义 URL（2026-06-08）：缺失或解码失败时为空字典，
        // 所有服务都走 `AppEndpoints.production(for:)` 默认值。
        self.customServiceURLs = Self.decodeJSON([String: String].self, key: Keys.customServiceURLs, defaults: defaults) ?? [:]

        // 第三方服务自定义 API Key（R-01 v1.2 2026-06-09 引入 / 2026-06-10 迁 Keychain）：
        //   1. 先尝试一次性迁移：UserDefaults 旧字典 → Keychain → 删 UserDefaults 旧 key
        //   2. 然后从 Keychain 把所有已知 service ID 的值预加载到内存缓存
        //
        // 迁移只跑一次：UserDefaults 旧 key 删除后，下次启动 legacyDict 为 nil 走 else 分支。
        // 测试场景：mock keychain + 隔离 UserDefaults，迁移路径 / 纯 Keychain 路径都走得通。
        if let legacyDict = Self.decodeJSON([String: String].self, key: Keys.customServiceAPIKeys, defaults: defaults),
           !legacyDict.isEmpty {
            // 迁移：把 UserDefaults 字典逐项写入 Keychain
            for (serviceID, apiKey) in legacyDict where !apiKey.isEmpty {
                do {
                    try keychain.storeServiceAPIKey(apiKey, forService: serviceID)
                    customServiceAPIKeysCache[serviceID] = apiKey
                } catch {
                    AppLog.keychain.error("Migrate customServiceAPIKey to keychain failed for \(serviceID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            // 删 UserDefaults 旧 key（迁移完成标志，下次启动跳过本分支）
            defaults.removeObject(forKey: Keys.customServiceAPIKeys)
            AppLog.keychain.info("Migrated customServiceAPIKeys to Keychain: \(legacyDict.count, privacy: .public) keys")
        } else {
            // 纯 Keychain 模式：迭代已知 ThirdPartyService case 预热缓存
            for service in ThirdPartyService.allCases {
                if let key = try? keychain.loadServiceAPIKey(forService: service.rawValue),
                   !key.isEmpty {
                    customServiceAPIKeysCache[service.rawValue] = key
                }
            }
        }
    }

    /// 由订阅权益链路更新 Pro 镜像。
    ///
    /// StoreKit 的 `Transaction.currentEntitlements` / `Transaction.updates` 与 Direct
    /// License 快照都会先进入聚合 provider；AppSettings 只负责把最终布尔值持久化给
    /// 头像标识等轻量 UI 使用。把写入口收口到一个方法里，是为了避免再次出现
    /// HOM-151 阶段设置页直接改 `isProUser` 的临时路径。
    func updateProEntitlementMirror(isPro: Bool) {
        guard isProUser != isPro else { return }
        isProUser = isPro
    }

    /// 将 Starcat 本机配置恢复为首次安装默认值。
    ///
    /// 使用场景是 Storage 页“清空所有数据”：它的产品语义是本机恢复出厂，
    /// 所以这里会同时清 UserDefaults 偏好与加密凭据文件里的 AI / 服务 / MCP Key。
    /// 不会访问 GitHub、CloudKit、App Store 或 License API，也不会修改远端购买记录；
    /// `isProUser` 只是本机 UI 镜像，重启后仍由聚合权益链路重新刷新。
    func resetToDefaults() throws {
        for key in Keys.resettableKeys {
            defaults.removeObject(forKey: key)
        }
        try keychain.deleteAllCredentials()
        customServiceAPIKeysCache.removeAll()

        appearanceMode = .dark
        interfaceScale = .standard
        readmeFontSizeAdjustment = 0
        repoSortOption = .starredAtDesc
        hideArchived = false
        hideForks = false
        statusFilter = nil
        starFilter = .all
        libraryFilter = .all
        repoLanguageFilter = .all
        interestedLanguages = []
        globalFilterLanguages = []
        wikiAvailabilityFilter = .unknown
        healthAvailabilityFilter = .unknown
        openSSFAvailabilityFilter = .unknown
        lastManageSelectionRaw = ""
        lastActivityCategoryRaw = ""
        listPreferenceValues = [:]
        openFirstDetailOnCategoryChange = false
        openRepositoryMarkdownInApp = false

        let provider = AIServiceProvider.openAICompatible
        let baseURL = provider.defaultBaseURL
        let chatModel = provider.defaultChatModel
        let embeddingModel = provider.defaultEmbeddingModel
        let defaultProfile = Self.makeDefaultAIProviderProfile(
            provider: provider,
            baseURL: baseURL,
            chatModel: chatModel,
            embeddingModel: embeddingModel
        )
        aiProvider = provider
        aiBaseURL = baseURL
        aiChatModel = chatModel
        aiEmbeddingModel = embeddingModel
        aiProviderProfiles = [defaultProfile]
        aiSummaryTask = Self.makeDefaultTask(task: .summary, profileID: defaultProfile.id, modelName: chatModel)
        aiTagsTask = Self.makeDefaultTask(task: .tags, profileID: defaultProfile.id, modelName: chatModel)
        aiEmbeddingTask = Self.makeDefaultTask(task: .embedding, profileID: defaultProfile.id, modelName: embeddingModel)
        aiTranslationTask = Self.makeDefaultTask(task: .translation, profileID: defaultProfile.id, modelName: chatModel)
        aiFullTranslationPrompt = AIDefaultPrompts.fullTranslation
        aiChatTask = Self.makeDefaultTask(task: .chat, profileID: defaultProfile.id, modelName: chatModel)
        ragBackendConfiguration = RAGBackendConfiguration()
        ragPromptSettings = .default
        ragRetrievalSettings = .balanced
        ragRerankConfiguration = RAGRerankConfiguration()
        ragInferenceBackend = .api
        ragWorkspaceSelectedModelID = ""
        ragWorkspaceDebugModeEnabled = false

        chatHistoryStorageKind = .jsonFiles
        smartSearchMode = .keyword
        externalSearchIncludeInAll = false
        externalContextEnabled = false
        externalSearchAllowPrivateRepos = false
        externalSearchDefaultProvider = .anySearch
        externalContextProviderSelection = .automatic
        aggregateExternalContextSearchEnabled = false
        externalSearchProviderSettings = ExternalSearchProviderSettings.defaultsByProvider()
        aiRepoContextEnabled = true
        aiRepoContextTokenBudget = 8_000
        aiRepoContextTier1MaxLines = 80
        aiRepoContextMaximumArchiveMB = Self.defaultAIRepoContextMaximumArchiveMB
        snakeStyle = SnakeStyle.default
        readmeTranslationLanguage = .auto
        readmeTranslationMode = .segmented
        disableAnimations = false
        hideDockIcon = false
        spotlightSearchEnabled = false
        aiChatRequiresCommandReturn = false
        keyboardShortcutsEnabled = true
        globalSearchShortcut = .globalSearchDefault
        globalSearchShortcutEnabled = true
        regularSearchShortcut = .regularSearchDefault
        regularSearchShortcutEnabled = true
        readmeFindShortcut = StarcatShortcutCatalog.readmeFindDefault
        readmeFindShortcutEnabled = true
        refreshCurrentContentShortcut = StarcatShortcutCatalog.refreshCurrentContentDefault
        refreshCurrentContentShortcutEnabled = true
        knowledgeRAGShortcut = StarcatShortcutCatalog.openKnowledgeRAGDefault
        knowledgeRAGShortcutEnabled = true
        selectedRepoAIShortcut = StarcatShortcutCatalog.openSelectedRepoAIDefault
        selectedRepoAIShortcutEnabled = true
        notificationsEnabled = true
        releaseNotificationsEnabled = true
        githubInboxNotificationsEnabled = true
        batchAINotificationsEnabled = true
        syncIssueNotificationsEnabled = true
        mcpIssueNotificationsEnabled = true
        githubIssueEventTimelineEnabled = false
        telemetryEnabled = false
        mcpServiceEnabled = false
        mcpServicePort = Self.defaultMCPServicePort
        mcpAllowRemoteConnections = false
        mcpExposePrivateNotes = false
        mcpAllowLocalWrites = false
        mcpAllowBatchWrites = false
        mcpAllowDestructiveWrites = false
        isProUser = false
        autoTidySettings = .default
        githubStarListAutoGroupingSettings = .default
        aiReadmeTruncateLength = ReadmePreprocessor.defaultMaxLength
        applyAIIndexPreset(.standard)
        aiIndexAutoPrefetchEnabled = false
        semanticIndexLastPrefetch = nil
        readmePrefetchEnabled = true
        aiSemanticSearchScoreThreshold = 0.75
        customServiceURLs = [:]
    }

    func listPreferenceValue(for key: String, login: String?) -> String? {
        guard let scopedKey = scopedListPreferenceKey(key, login: login) else { return nil }
        let raw = listPreferenceValues[scopedKey]
        return raw?.isEmpty == true ? nil : raw
    }

    func setListPreferenceValue(_ value: String?, for key: String, login: String?) {
        guard let scopedKey = scopedListPreferenceKey(key, login: login) else { return }
        var copy = listPreferenceValues
        if let value, !value.isEmpty {
            copy[scopedKey] = value
        } else {
            copy.removeValue(forKey: scopedKey)
        }
        listPreferenceValues = copy
    }

    func resetListPreferences(login: String?) {
        guard let login = normalizedListPreferenceLogin(login) else { return }
        let prefix = "\(login):"
        listPreferenceValues = listPreferenceValues.filter { !$0.key.hasPrefix(prefix) }
    }

    private func scopedListPreferenceKey(_ key: String, login: String?) -> String? {
        guard let login = normalizedListPreferenceLogin(login) else { return nil }
        return "\(login):\(key)"
    }

    private func normalizedListPreferenceLogin(_ login: String?) -> String? {
        guard let login = login?.trimmingCharacters(in: .whitespacesAndNewlines),
              !login.isEmpty else {
            return nil
        }
        return login.lowercased()
    }

    static func normalizedLanguageList(_ languages: [String]) -> [String] {
        var seen = Set<String>()
        let unique = languages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { language in
                let key = language.lowercased()
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
        return unique.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func clampedReadmeFontSizeAdjustment(_ value: Int) -> Int {
        min(max(value, readmeFontSizeAdjustmentRange.lowerBound), readmeFontSizeAdjustmentRange.upperBound)
    }

    // MARK: - 内部

    private func persist(key: String, value: String) {
        defaults.set(value, forKey: key)
    }

    private func persistBool(key: String, value: Bool) {
        defaults.set(value, forKey: key)
    }

    private func persistJSON<T: Encodable>(key: String, value: T) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            defaults.set(String(decoding: data, as: UTF8.self), forKey: key)
        } catch {
            AppLog.general.error("persistJSON failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            DiagnosticLogStore.record(
                level: .error,
                visibility: .issue,
                category: "settings",
                operation: "settings.persistJSON",
                message: "A settings value could not be encoded",
                underlying: DiagnosticEvent.summarize(error),
                context: ["key": key]
            )
        }
    }

    func externalSearchSettings(for provider: ExternalSearchProviderID) -> ExternalSearchProviderSettings {
        externalSearchProviderSettings[provider] ?? ExternalSearchProviderSettings.defaultSettings(for: provider)
    }

    func setExternalSearchSettings(
        _ settings: ExternalSearchProviderSettings,
        for provider: ExternalSearchProviderID
    ) {
        var next = externalSearchProviderSettings
        next[provider] = settings
        externalSearchProviderSettings = Self.normalizedExternalSearchProviderSettings(next)
    }

    func markExternalSearchCredentialVerified(
        for provider: ExternalSearchProviderID,
        at date: Date = Date()
    ) {
        var settings = externalSearchSettings(for: provider)
        settings.credentialVerifiedAt = date
        settings.isEnabled = true
        setExternalSearchSettings(settings, for: provider)
    }

    func clearExternalSearchCredentialVerification(for provider: ExternalSearchProviderID) {
        var settings = externalSearchSettings(for: provider)
        settings.credentialVerifiedAt = nil
        setExternalSearchSettings(settings, for: provider)
    }

    func externalSearchAPIKey(for provider: ExternalSearchProviderID) -> String? {
        try? keychain.loadServiceAPIKey(forService: provider.keychainServiceID)
    }

    func setExternalSearchAPIKey(_ value: String?, for provider: ExternalSearchProviderID) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            if trimmed.isEmpty {
                try keychain.deleteServiceAPIKey(forService: provider.keychainServiceID)
            } else {
                try keychain.storeServiceAPIKey(trimmed, forService: provider.keychainServiceID)
            }
            // Key 内容变化后，旧的 verified marker 已不再可信，必须重新 Test。
            clearExternalSearchCredentialVerification(for: provider)
        } catch {
            AppLog.keychain.error("External Search API key update failed: provider=\(provider.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func normalizedExternalSearchProviderSettings(
        _ value: [ExternalSearchProviderID: ExternalSearchProviderSettings]?
    ) -> [ExternalSearchProviderID: ExternalSearchProviderSettings] {
        var settings = value ?? [:]
        for provider in ExternalSearchProviderID.allCases where settings[provider] == nil {
            settings[provider] = ExternalSearchProviderSettings.defaultSettings(for: provider)
        }
        // 迁移：Firecrawl 首版集成时默认 anonymousMode=false（当时尚未支持 keyless 免密），
        // 后来默认改为 true。这里把「从未配置过」的 firecrawl（未启用、未验证、匿名关）
        // 迁移到新默认，避免旧缓存让启用开关置灰、用户陷入「无法启用也无法开匿名」的死锁。
        if var firecrawl = settings[.firecrawl],
           !firecrawl.isEnabled,
           !firecrawl.anonymousMode,
           firecrawl.credentialVerifiedAt == nil {
            firecrawl.anonymousMode = true
            settings[.firecrawl] = firecrawl
        }
        return settings
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        key: String,
        defaults: UserDefaults
    ) -> T? {
        guard let raw = defaults.string(forKey: key),
              let data = raw.data(using: .utf8)
        else {
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.general.error("decodeJSON failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            DiagnosticLogStore.record(
                level: .error,
                visibility: .issue,
                category: "settings",
                operation: "settings.decodeJSON",
                message: "A persisted settings value could not be decoded",
                underlying: DiagnosticEvent.summarize(error),
                context: ["key": key]
            )
            return nil
        }
    }

    /// 只升级仍等于已发布旧默认值的标签 Prompt，保留用户选择的 Provider / Model / 参数。
    ///
    /// 标签任务整份配置持久化在同一个 JSON key 下；若仅修改 `AIDefaultPrompts.tags`，
    /// 老用户会永久继续使用“每次生成 3...8 个”的旧 Prompt。反过来，直接覆盖整份配置
    /// 又会破坏用户自定义 Prompt。本迁移用完整值相等判断区分两者，并在命中时只替换
    /// `prompt` 字段。编码失败时返回内存中的新值，下次启动仍可重试持久化。
    private static func migrateLegacyDefaultTagsPromptIfNeeded(
        _ task: AIModelTaskConfiguration,
        defaults: UserDefaults
    ) -> AIModelTaskConfiguration {
        guard task.prompt == AIDefaultPrompts.legacyTagsV1 else { return task }

        var migrated = task
        migrated.prompt = AIDefaultPrompts.tags
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Keys.aiTagsTask)
        }
        return migrated
    }

    /// 只为仍使用旧默认值的摘要任务补上 `{insightsContext}`，保留自定义 Prompt。
    private static func migrateLegacyDefaultSummaryPromptIfNeeded(
        _ task: AIModelTaskConfiguration,
        defaults: UserDefaults
    ) -> AIModelTaskConfiguration {
        migrateLegacyDefaultPrompt(
            task,
            legacy: AIDefaultPrompts.legacySummaryWithoutInsights,
            current: AIDefaultPrompts.summary,
            key: Keys.aiSummaryTask,
            defaults: defaults
        )
    }

    /// 只为仍使用旧默认值的仓库对话任务补上 `{insightsContext}`，保留自定义 Prompt。
    private static func migrateLegacyDefaultChatPromptIfNeeded(
        _ task: AIModelTaskConfiguration,
        defaults: UserDefaults
    ) -> AIModelTaskConfiguration {
        migrateLegacyDefaultPrompt(
            task,
            legacy: AIDefaultPrompts.legacyChatWithoutInsights,
            current: AIDefaultPrompts.chat,
            key: Keys.aiChatTask,
            defaults: defaults
        )
    }

    /// 默认 Prompt 的窄迁移：完整相等才替换 prompt，其余 Provider / Model / 参数原样保留。
    private static func migrateLegacyDefaultPrompt(
        _ task: AIModelTaskConfiguration,
        legacy: AIPromptConfiguration,
        current: AIPromptConfiguration,
        key: String,
        defaults: UserDefaults
    ) -> AIModelTaskConfiguration {
        guard task.prompt == legacy else { return task }

        var migrated = task
        migrated.prompt = current
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: key)
        }
        return migrated
    }

    /// 只迁移仍等于已发布“整份 HTML 翻译”默认值的 Prompt。
    ///
    /// Provider、Model 与参数全部保留；用户自定义 Prompt 不覆盖。旧自定义模板中的
    /// `{readmeHTML}` 仍由 Service 作为段落 JSON 别名替换，避免升级后直接失效。
    private static func migrateLegacyDefaultTranslationPromptIfNeeded(
        _ task: AIModelTaskConfiguration,
        defaults: UserDefaults
    ) -> AIModelTaskConfiguration {
        guard task.prompt == AIDefaultPrompts.legacyTranslationHTMLV1 else { return task }

        var migrated = task
        migrated.prompt = AIDefaultPrompts.translation
        if let data = try? JSONEncoder().encode(migrated) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: Keys.aiTranslationTask)
        }
        return migrated
    }

    /// HOM-68 follow-up v9 (dong4j 反馈 2026-06-05 23:35)：
    /// 解析一个任务在调用时实际生效的 AI 参数。
    ///
    /// 解析顺序（先命中即返回）：
    /// 1. 任务绑定的 (providerID, modelID) descriptor 找到了 → 用 descriptor.parameters，
    ///    若 descriptor.parameters 为 nil 走 `AIModelParameters.defaults(for: capability)`；
    /// 2. 找不到 descriptor（model 被删 / providerID 不再存在 / 老 build 升级中途）→
    ///    回退到 task 持久化的 legacy parameters，保住老用户的体验不被破坏。
    ///
    /// UI 已不再暴露任务粒度的"模型参数"编辑（v9 改成模型粒度的齿轮按钮），
    /// 但 task.parameters 字段保留作为 二级 fallback，避免数据迁移阻塞发布。
    func effectiveParameters(for task: AIModelTaskConfiguration) -> AIModelParameters {
        if let profile = aiProviderProfiles.first(where: { $0.id == task.providerID }),
           let model = profile.models.first(where: { $0.name == task.modelID }) {
            return model.parameters ?? AIModelParameters.defaults(for: model.capability)
        }
        return task.parameters
    }

    private static func makeDefaultAIProviderProfile(
        provider: AIServiceProvider,
        baseURL: String,
        chatModel: String,
        embeddingModel: String
    ) -> AIProviderProfile {
        let profileID = "legacy-\(provider.rawValue)"
        return AIProviderProfile(
            id: profileID,
            provider: provider,
            displayName: provider.defaultProfileName,
            baseURL: baseURL,
            models: [
                AIModelDescriptor(
                    providerID: profileID,
                    name: chatModel,
                    capability: .chat,
                    isEnabled: true,
                    isCustom: true
                ),
                AIModelDescriptor(
                    providerID: profileID,
                    name: embeddingModel,
                    capability: .embedding,
                    isEnabled: true,
                    isCustom: true
                )
            ]
        )
    }

    private static func makeDefaultTask(
        task: AIModelTask,
        profileID: String,
        modelName: String
    ) -> AIModelTaskConfiguration {
        AIModelTaskConfiguration(
            providerID: profileID,
            modelID: modelName,
            customModelName: modelName,
            useCustomModel: false,
            parameters: {
                switch task {
                case .summary:     return .summaryDefault
                case .tags:        return .tagsDefault
                case .embedding:   return .embeddingDefault
                case .translation: return .translationDefault
                case .chat:        return .summaryDefault  // chat 场景接近摘要，复用同一份参数（128K maxToken / 0.2 温度 / 流式 on）
                }
            }(),
            prompt: {
                switch task {
                case .summary:     return AIDefaultPrompts.summary
                case .tags:        return AIDefaultPrompts.tags
                case .embedding:   return AIDefaultPrompts.embedding
                case .translation: return AIDefaultPrompts.translation
                case .chat:        return AIDefaultPrompts.chat
                }
            }()
        )
    }

    /// 全部偏好键集中地，避免字符串散落。
    /// UserDefaults key 命名空间。
    ///
    /// 暴露为 internal（去掉 private）让 @testable 测试访问 `Keys.customServiceAPIKeys`
    /// 验证迁移路径。生产代码外部不应引用本枚举（语义对齐 SPM target 的 internal）。
    enum Keys {
        static let appearanceMode = "settings.appearanceMode"  // W4-5 D1
        static let interfaceScale = "settings.general.interfaceScale.v1"  // 2026-06-30
        static let readmeFontSizeAdjustment = "settings.readme.fontSizeAdjustment.v1"
        // R-01 §3.1.1（2026-06-10 P1）：repoListDensity key 已删除（RepoListDensity 枚举随 P1 整体清零）
        static let repoSortOption = "settings.repoSortOption"
        static let hideArchived = "settings.hideArchived"
        static let hideForks = "settings.hideForks"
        static let statusFilter = "settings.statusFilter"
        static let starFilter = "settings.filters.global.starStatus.v1"
        static let libraryFilter = "settings.libraryFilter"
        static let repoLanguageFilter = "settings.repoLanguageFilter"
        static let interestedLanguages = "settings.filters.interestedLanguages.v1"
        static let globalFilterLanguages = "settings.filters.global.languages.v1"
        static let wikiAvailabilityFilter = "settings.filters.global.wikiAvailability.v1"
        static let healthAvailabilityFilter = "settings.filters.global.healthAvailability.v1"
        static let openSSFAvailabilityFilter = "settings.filters.global.openSSFAvailability.v1"
        static let lastManageSelection = "settings.lastManageSelection"
        static let lastActivityCategory = "settings.lastActivityCategory"
        static let listPreferenceValues = "settings.listPreferences.values.v1"
        static let openFirstDetailOnCategoryChange = "settings.detail.openFirstOnCategoryChange.v1"
        static let openRepositoryMarkdownInApp = "settings.readme.openRepositoryMarkdownInApp.v1"
        static let aiProvider = "settings.ai.provider"
        static let aiBaseURL = "settings.ai.baseURL"
        static let aiChatModel = "settings.ai.chatModel"
        static let aiEmbeddingModel = "settings.ai.embeddingModel"
        static let aiProviderProfiles = "settings.ai.providerProfiles.v2"
        static let aiSummaryTask = "settings.ai.task.summary.v2"
        static let aiTagsTask = "settings.ai.task.tags.v2"
        static let aiEmbeddingTask = "settings.ai.task.embedding.v2"
        static let aiTranslationTask = "settings.ai.task.translation.v2"  // HOM-68 follow-up
        static let aiFullTranslationPrompt = "settings.ai.prompt.translation.full.v1"
        static let aiChatTask = "settings.ai.task.chat.v1"  // 2026-06-14 v4 占位符化（chat 提到 task 平级）
        static let ragBackendConfiguration = "settings.ai.rag.backends.v1"
        static let ragPromptSettings = "settings.rag.prompts.v1"
        static let ragRetrievalSettings = "settings.rag.retrieval.v1"
        static let ragRerankConfiguration = "settings.rag.rerank.v1"
        static let ragInferenceBackend = "settings.rag.inference.backend.v1"
        static let ragWorkspaceSelectedModelID = "settings.rag.workspace.selectedModelID.v1"
        static let ragWorkspaceDebugModeEnabled = "settings.rag.workspace.debugModeEnabled.v1"
        static let chatHistoryStorageKind = "settings.ai.chatHistory.storageKind.v1"
        static let smartSearchMode = "settings.search.mode"
        static let externalSearchIncludeInAll = "settings.externalSearch.includeInAll.v1"
        static let externalContextEnabled = "settings.externalSearch.context.enabled.v1"
        static let externalSearchAllowPrivateRepos = "settings.externalSearch.context.allowPrivate.v1"
        static let externalSearchDefaultProvider = "settings.externalSearch.defaultProvider.v1"
        static let externalContextProviderSelection = "settings.externalSearch.context.providerSelection.v1"
        static let aggregateExternalContextSearchEnabled = "settings.externalSearch.context.aggregate.enabled.v1"
        static let externalSearchProviderSettings = "settings.externalSearch.providerSettings.v1"
        static let snakeStyle = "settings.contribution.snakeStyle"  // HOM-SNAKE-MODES
        static let readmeTranslationLanguage = "settings.readme.translation.language"  // HOM-68
        static let readmeTranslationMode = "settings.readme.translation.mode.v1"
        static let undoStarRetentionDays = "settings.undoStar.retentionDays"  // 2026-07-05
        static let isProUser = "settings.pro.isProUser"  // HOM-151
        static let disableAnimations = "settings.general.disableAnimations.v1"  // 2026-06-15
        static let hideDockIcon = "settings.general.hideDockIcon.v1"  // 2026-07-02
        static let spotlightSearchEnabled = "settings.general.spotlightSearch.enabled.v1"
        static let aiChatRequiresCommandReturn = "settings.general.shortcuts.aiCommandReturn.v1"
        static let keyboardShortcutsEnabled = "settings.general.shortcuts.enabled.v1"
        static let globalSearchShortcut = "settings.general.shortcuts.globalSearch.v1"
        static let globalSearchShortcutEnabled = "settings.general.shortcuts.globalSearch.enabled.v1"
        static let regularSearchShortcut = "settings.general.shortcuts.regularSearch.v1"
        static let regularSearchShortcutEnabled = "settings.general.shortcuts.regularSearch.enabled.v1"
        static let readmeFindShortcut = "settings.general.shortcuts.readmeFind.v1"
        static let readmeFindShortcutEnabled = "settings.general.shortcuts.readmeFind.enabled.v1"
        static let refreshCurrentContentShortcut = "settings.general.shortcuts.refreshCurrentContent.v1"
        static let refreshCurrentContentShortcutEnabled = "settings.general.shortcuts.refreshCurrentContent.enabled.v1"
        static let knowledgeRAGShortcut = "settings.general.shortcuts.knowledgeRAG.v1"
        static let knowledgeRAGShortcutEnabled = "settings.general.shortcuts.knowledgeRAG.enabled.v1"
        static let selectedRepoAIShortcut = "settings.general.shortcuts.selectedRepoAI.v1"
        static let selectedRepoAIShortcutEnabled = "settings.general.shortcuts.selectedRepoAI.enabled.v1"
        static let notificationsEnabled = "settings.notifications.enabled.v1"
        static let releaseNotificationsEnabled = "settings.notifications.release.enabled.v1"
        static let githubInboxNotificationsEnabled = "settings.notifications.githubInbox.enabled.v1"
        static let batchAINotificationsEnabled = "settings.notifications.batchAI.enabled.v1"
        static let syncIssueNotificationsEnabled = "settings.notifications.syncIssues.enabled.v1"
        static let mcpIssueNotificationsEnabled = "settings.notifications.mcpIssues.enabled.v1"
        static let githubIssueEventTimelineEnabled = "settings.activity.issueEvents.enabled.v1"
        static let telemetryEnabled = "settings.telemetry.enabled.v1"
        static let mcpServiceEnabled = "settings.mcp.enabled.v1"
        static let mcpServicePort = "settings.mcp.port.v1"
        static let mcpAllowRemoteConnections = "settings.mcp.allowRemoteConnections.v1"
        static let mcpExposePrivateNotes = "settings.mcp.exposePrivateNotes.v1"
        static let mcpAllowLocalWrites = "settings.mcp.allowLocalWrites.v1"
        static let mcpAllowBatchWrites = "settings.mcp.allowBatchWrites.v1"
        static let mcpAllowDestructiveWrites = "settings.mcp.allowDestructiveWrites.v1"
        static let autoTidySettings = "settings.ai.autoTidy.v1"  // HOM-126
        static let githubStarListAutoGroupingSettings = "settings.ai.githubStarListAutoGrouping.v1"
        static let customServiceURLs = "settings.services.customURLs.v1"  // 2026-06-08
        // R-01 v1.2 2026-06-09 引入；2026-06-10 迁 Keychain。
        // 本 key 仅作「启动期一次性迁移识别」用，迁移完成后会被 init 内的 removeObject 清空。
        // 新写入路径不再走 UserDefaults，详见 setCustomAPIKey(_:for:) 注释。
        static let customServiceAPIKeys = "settings.services.customAPIKeys.v1"
        // 2026-06-12 向量索引改进（5 个字段）
        static let aiReadmeTruncateLength = "settings.ai.index.readmeTruncateLength.v1"
        static let aiIndexPreset = "settings.ai.index.preset.v1"
        static let aiIndexBodyDiffRatio = "settings.ai.index.bodyDiffRatio.v1"
        static let aiIndexNotesDiffRatio = "settings.ai.index.notesDiffRatio.v1"
        static let aiIndexAutoPrefetchEnabled = "settings.ai.index.autoPrefetchEnabled.v1"
        static let semanticIndexLastPrefetch = "settings.ai.index.lastPrefetch.v1"
        static let readmePrefetchEnabled = "settings.readme.prefetch.enabled.v1"
        // HOM-197（2026-06-13 dong4j）：AI 语义搜索过滤阈值，默认 0.75。
        static let aiSemanticSearchScoreThreshold = "settings.ai.semanticSearch.scoreThreshold.v1"
        // 2026-06-13 RepoContextPacker 客户端接入（3 个字段，§0.3 X1）
        static let aiRepoContextEnabled = "settings.ai.repoContext.enabled.v1"
        static let aiRepoContextTokenBudget = "settings.ai.repoContext.tokenBudget.v1"
        static let aiRepoContextTier1MaxLines = "settings.ai.repoContext.tier1MaxLines.v1"
        static let aiRepoContextMaximumArchiveMB = "settings.ai.repoContext.maximumArchiveMB.v1"

        static let resettableKeys: [String] = [
            appearanceMode,
            interfaceScale,
            readmeFontSizeAdjustment,
            repoSortOption,
            hideArchived,
            hideForks,
            statusFilter,
            starFilter,
            libraryFilter,
            repoLanguageFilter,
            interestedLanguages,
            globalFilterLanguages,
            wikiAvailabilityFilter,
            healthAvailabilityFilter,
            openSSFAvailabilityFilter,
            lastManageSelection,
            lastActivityCategory,
            listPreferenceValues,
            openFirstDetailOnCategoryChange,
            openRepositoryMarkdownInApp,
            aiProvider,
            aiBaseURL,
            aiChatModel,
            aiEmbeddingModel,
            aiProviderProfiles,
            aiSummaryTask,
            aiTagsTask,
            aiEmbeddingTask,
            aiTranslationTask,
            aiFullTranslationPrompt,
            aiChatTask,
            ragBackendConfiguration,
            ragPromptSettings,
            ragRetrievalSettings,
            ragRerankConfiguration,
            ragInferenceBackend,
            ragWorkspaceSelectedModelID,
            ragWorkspaceDebugModeEnabled,
            chatHistoryStorageKind,
            smartSearchMode,
            externalSearchIncludeInAll,
            externalContextEnabled,
            externalSearchAllowPrivateRepos,
            externalSearchDefaultProvider,
            externalContextProviderSelection,
            aggregateExternalContextSearchEnabled,
            externalSearchProviderSettings,
            snakeStyle,
            readmeTranslationLanguage,
            readmeTranslationMode,
            isProUser,
            disableAnimations,
            hideDockIcon,
            aiChatRequiresCommandReturn,
            keyboardShortcutsEnabled,
            globalSearchShortcut,
            globalSearchShortcutEnabled,
            regularSearchShortcut,
            regularSearchShortcutEnabled,
            readmeFindShortcut,
            readmeFindShortcutEnabled,
            refreshCurrentContentShortcut,
            refreshCurrentContentShortcutEnabled,
            knowledgeRAGShortcut,
            knowledgeRAGShortcutEnabled,
            selectedRepoAIShortcut,
            selectedRepoAIShortcutEnabled,
            notificationsEnabled,
            releaseNotificationsEnabled,
            githubInboxNotificationsEnabled,
            batchAINotificationsEnabled,
            syncIssueNotificationsEnabled,
            mcpIssueNotificationsEnabled,
            githubIssueEventTimelineEnabled,
            telemetryEnabled,
            mcpServiceEnabled,
            mcpServicePort,
            mcpAllowRemoteConnections,
            mcpExposePrivateNotes,
            mcpAllowLocalWrites,
            mcpAllowBatchWrites,
            mcpAllowDestructiveWrites,
            autoTidySettings,
            githubStarListAutoGroupingSettings,
            customServiceURLs,
            customServiceAPIKeys,
            aiReadmeTruncateLength,
            aiIndexPreset,
            aiIndexBodyDiffRatio,
            aiIndexNotesDiffRatio,
            aiIndexAutoPrefetchEnabled,
            semanticIndexLastPrefetch,
            readmePrefetchEnabled,
            aiSemanticSearchScoreThreshold,
            aiRepoContextEnabled,
            aiRepoContextTokenBudget,
            aiRepoContextTier1MaxLines,
            aiRepoContextMaximumArchiveMB
        ]
    }
}
