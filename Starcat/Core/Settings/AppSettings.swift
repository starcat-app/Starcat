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

// MARK: - 列表密度

/// 仓库列表的视觉密度。
enum RepoListDensity: String, CaseIterable, Identifiable {
    /// 单行紧凑：一行内显示 name / lang / stars。
    case compact
    /// 卡片多行：头像 + full_name + description + 属性条。
    case card

    var id: String { rawValue }

    /// 本地化显示名。
    var displayName: LocalizedStringKey {
        switch self {
        case .compact: return "settings.listDensity.compact"
        case .card:    return "settings.listDensity.card"
        }
    }
}

// MARK: - 列表排序（W4-4 D1）

/// 仓库列表排序选项。
///
/// 设计：把"字段 + 方向"合并成枚举 case，UI 用单层 Picker 就能列全，无需嵌套 Menu。
/// 默认 `.starredAtDesc` — 最近 star 的在最前，与之前隐式行为一致。
enum RepoSortOption: String, CaseIterable, Identifiable {
    /// 默认：最近 star 在前。
    case starredAtDesc
    /// 最早 star 在前。
    case starredAtAsc
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

    var id: String { rawValue }

    /// 本地化显示名。
    var displayName: LocalizedStringKey {
        switch self {
        case .starredAtDesc: return "settings.sort.starredAtDesc"
        case .starredAtAsc:  return "settings.sort.starredAtAsc"
        case .nameAsc:       return "settings.sort.nameAsc"
        case .nameDesc:      return "settings.sort.nameDesc"
        case .starsDesc:     return "settings.sort.starsDesc"
        case .starsAsc:      return "settings.sort.starsAsc"
        case .updatedDesc:   return "settings.sort.updatedDesc"
        case .updatedAsc:    return "settings.sort.updatedAsc"
        }
    }

    /// SF Symbol，用于 Menu Label 视觉提示。
    var systemImage: String {
        switch self {
        case .starredAtDesc, .starredAtAsc: return "star"
        case .nameAsc, .nameDesc:           return "textformat"
        case .starsDesc, .starsAsc:         return "star.fill"
        case .updatedDesc, .updatedAsc:     return "clock.arrow.circlepath"
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
        }
    }
}

// MARK: - AI 设置

/// AI 服务商类型。
///
/// 设计选择：
/// - 当前第一阶段只落地 OpenAI-compatible 路线，OpenAI / DeepSeek / OpenRouter /
///   Ollama / LM Studio 都可以通过 Base URL + API Key 表达。
/// - 保留具体 provider 枚举不是为了锁死 SDK，而是为了给设置页提供合理默认值。
enum AIServiceProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case openAICompatible
    case deepSeek
    case openRouter
    case ollama
    case lmStudio

    var id: String { rawValue }

    var displayName: LocalizedStringKey {
        switch self {
        case .openAICompatible: return "OpenAI Compatible"
        case .deepSeek:         return "DeepSeek"
        case .openRouter:       return "OpenRouter"
        case .ollama:           return "Ollama"
        case .lmStudio:         return "LM Studio"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .deepSeek:         return "https://api.deepseek.com"
        case .openRouter:       return "https://openrouter.ai/api/v1"
        case .ollama:           return "http://localhost:11434/v1"
        case .lmStudio:         return "http://localhost:1234/v1"
        }
    }

    var defaultChatModel: String {
        switch self {
        case .openAICompatible: return "gpt-4o-mini"
        case .deepSeek:         return "deepseek-chat"
        case .openRouter:       return "openai/gpt-4o-mini"
        case .ollama:           return "llama3.2"
        case .lmStudio:         return "local-model"
        }
    }

    var defaultEmbeddingModel: String {
        switch self {
        case .openAICompatible, .openRouter:
            return "text-embedding-3-small"
        case .deepSeek:
            return "text-embedding-3-small"
        case .ollama:
            return "nomic-embed-text"
        case .lmStudio:
            return "text-embedding-nomic-embed-text-v1.5"
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
///   后续如果要做"按系统语言自动选默认目标"或写日志时可以直接传给 Locale；
/// - 默认 `.simplifiedChinese`：HOM-68 明确要求默认中文；
/// - 第一版只列 5 个主流语言；后续按用户反馈追加。
/// - `displayName` 走本地化（菜单显示的是「简体中文 / English / 日本語」之类用户母语标签）；
/// - `promptName` 是发给 LLM 的目标语言名称，固定走英文（`Simplified Chinese`），
///   避免不同 provider 对中文 prompt 关键词的解析差异，提示词中明确语言能更稳定。
enum ReadmeTranslationLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    /// 菜单显示文案（本地化）。
    /// 直接返回原生语言名而不是走 xcstrings：菜单里通常用「目标语言的母语写法」
    /// 比"Simplified Chinese / 简体中文"双语对照更短更清晰。
    var displayName: String {
        switch self {
        case .simplifiedChinese:  return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .english:            return "English"
        case .japanese:           return "日本語"
        case .korean:             return "한국어"
        }
    }

    /// 发给 LLM 的目标语言名（固定英文，跨 provider 最稳定）。
    var promptName: String {
        switch self {
        case .simplifiedChinese:  return "Simplified Chinese"
        case .traditionalChinese: return "Traditional Chinese"
        case .english:            return "English"
        case .japanese:           return "Japanese"
        case .korean:             return "Korean"
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

    // MARK: - 偏好项

    /// 应用外观主题(W4-5 D1,dong4j 2026-06-03 需求)。
    /// 默认 `.dark` — Starcat 主视觉为深色,见 `AppearanceMode` 设计注释。
    /// 写入即落盘;UI 通过 @Observable 自动响应,
    /// `StarcatApp` 的 WindowGroup / Settings scene 各挂一个 `.preferredColorScheme(_:)` 应用。
    var appearanceMode: AppearanceMode {
        didSet { persist(key: Keys.appearanceMode, value: appearanceMode.rawValue) }
    }

    /// 仓库列表行密度。
    /// 写入即落盘；UI 通过 @Observable 自动响应。
    var listDensity: RepoListDensity {
        didSet { persist(key: Keys.repoListDensity, value: listDensity.rawValue) }
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

    /// 搜索栏当前模式。默认 keyword，避免用户未配置 AI 时误触发付费 API。
    var smartSearchMode: SmartSearchMode {
        didSet { persist(key: Keys.smartSearchMode, value: smartSearchMode.rawValue) }
    }

    /// 贡献草坪贪吃蛇玩法（HOM-SNAKE-MODES 2026-06-05）。
    /// 默认 `.greedy`（snk 同款），让"草坪 + 蛇"的卖点立刻直观可感。
    /// 修改时 `ContributionGraphView` 会通过 `.onChange` 重建 animator。
    var snakeStyle: SnakeStyle {
        didSet { persist(key: Keys.snakeStyle, value: snakeStyle.rawValue) }
    }

    /// README 翻译目标语言（HOM-68）。
    /// 默认简体中文，符合 HOM-68 验收要求；用户可在详情页翻译按钮的下拉菜单里切换，
    /// 选择后即时落盘，下次进入详情页直接命中本地翻译缓存（按 `(repo_id, language)` 查表）。
    var readmeTranslationLanguage: ReadmeTranslationLanguage {
        didSet { persist(key: Keys.readmeTranslationLanguage, value: readmeTranslationLanguage.rawValue) }
    }

    // MARK: - 初始化

    private let defaults: UserDefaults

    /// - Parameter defaults: 注入点，便于测试用 UserDefaults(suiteName:) 隔离。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // W4-5 D1:外观主题。dong4j 2026-06-03 决定默认深色(`.dark`),
        // 历史用户(首次升级到本版)若无落盘值,也会落到 `.dark`,跟新用户一致。
        let appearanceRaw = defaults.string(forKey: Keys.appearanceMode)
        self.appearanceMode = appearanceRaw.flatMap(AppearanceMode.init(rawValue:)) ?? .dark

        // 读取或回落到默认值
        let densityRaw = defaults.string(forKey: Keys.repoListDensity)
        self.listDensity = densityRaw.flatMap(RepoListDensity.init(rawValue:)) ?? .card

        let sortRaw = defaults.string(forKey: Keys.repoSortOption)
        self.repoSortOption = sortRaw.flatMap(RepoSortOption.init(rawValue:)) ?? .starredAtDesc

        // Bool 默认值用 object(forKey:) 判 nil；防止 `bool(forKey:)` 把缺失也当 false
        self.hideArchived = defaults.object(forKey: Keys.hideArchived) as? Bool ?? false
        self.hideForks = defaults.object(forKey: Keys.hideForks) as? Bool ?? false

        // W4-4 D3：空字符串表示 nil(无过滤);非空字符串尝试匹配 RepoStatus,失败也回落 nil
        let statusRaw = defaults.string(forKey: Keys.statusFilter) ?? ""
        self.statusFilter = statusRaw.isEmpty ? nil : RepoStatus(rawValue: statusRaw)

        // 上次 Manage 分类：缺失则空串，由 SidebarItem 解码时回落 allStars
        self.lastManageSelectionRaw = defaults.string(forKey: Keys.lastManageSelection) ?? ""

        // 上次 Activity 分类：缺失则空串，由 ActivityCategory 解码时回落 all
        self.lastActivityCategoryRaw = defaults.string(forKey: Keys.lastActivityCategory) ?? ""

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
        self.aiSummaryTask = Self.decodeJSON(AIModelTaskConfiguration.self, key: Keys.aiSummaryTask, defaults: defaults) ?? defaultSummaryTask
        self.aiTagsTask = Self.decodeJSON(AIModelTaskConfiguration.self, key: Keys.aiTagsTask, defaults: defaults) ?? defaultTagsTask
        self.aiEmbeddingTask = Self.decodeJSON(AIModelTaskConfiguration.self, key: Keys.aiEmbeddingTask, defaults: defaults) ?? defaultEmbeddingTask
        let searchModeRaw = defaults.string(forKey: Keys.smartSearchMode)
        self.smartSearchMode = searchModeRaw.flatMap(SmartSearchMode.init(rawValue:)) ?? .keyword

        let snakeStyleRaw = defaults.string(forKey: Keys.snakeStyle)
        self.snakeStyle = snakeStyleRaw.flatMap(SnakeStyle.init(rawValue:)) ?? SnakeStyle.default

        // HOM-68：README 翻译目标语言。默认简体中文。
        let translationLangRaw = defaults.string(forKey: Keys.readmeTranslationLanguage)
        self.readmeTranslationLanguage = translationLangRaw
            .flatMap(ReadmeTranslationLanguage.init(rawValue:)) ?? .simplifiedChinese
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
        }
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
            return nil
        }
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
                case .summary:   return .summaryDefault
                case .tags:      return .tagsDefault
                case .embedding: return .embeddingDefault
                }
            }(),
            prompt: {
                switch task {
                case .summary:   return AIDefaultPrompts.summary
                case .tags:      return AIDefaultPrompts.tags
                case .embedding: return AIDefaultPrompts.embedding
                }
            }()
        )
    }

    /// 全部偏好键集中地，避免字符串散落。
    private enum Keys {
        static let appearanceMode = "settings.appearanceMode"  // W4-5 D1
        static let repoListDensity = "settings.repoListDensity"
        static let repoSortOption = "settings.repoSortOption"
        static let hideArchived = "settings.hideArchived"
        static let hideForks = "settings.hideForks"
        static let statusFilter = "settings.statusFilter"
        static let lastManageSelection = "settings.lastManageSelection"
        static let lastActivityCategory = "settings.lastActivityCategory"
        static let aiProvider = "settings.ai.provider"
        static let aiBaseURL = "settings.ai.baseURL"
        static let aiChatModel = "settings.ai.chatModel"
        static let aiEmbeddingModel = "settings.ai.embeddingModel"
        static let aiProviderProfiles = "settings.ai.providerProfiles.v2"
        static let aiSummaryTask = "settings.ai.task.summary.v2"
        static let aiTagsTask = "settings.ai.task.tags.v2"
        static let aiEmbeddingTask = "settings.ai.task.embedding.v2"
        static let smartSearchMode = "settings.search.mode"
        static let snakeStyle = "settings.contribution.snakeStyle"  // HOM-SNAKE-MODES
        static let readmeTranslationLanguage = "settings.readme.translation.language"  // HOM-68
    }
}
