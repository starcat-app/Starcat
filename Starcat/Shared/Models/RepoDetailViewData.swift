//
//  RepoDetailViewData.swift
//  Starcat
//
//  R-01「三场景共用架构」详情页视图数据（适配层）。
//
//  设计意图（详细设计 §3.2 + §4.5）：
//  - `RepoDetailScaffold` 作为「通用骨架」（Hero header + trailing actions + 翻译浮动
//    + 刷新浮动 + 折叠面板 + README 滚动监听），各场景只需要构造一份本类型 + 一个
//    自己的 `XxxDetailContent` 插槽 view，无需自写 hero / 状态管理 / 浮动按钮。
//  - **没有 DetailSections 配置**（v1.1 dong4j review）：
//    「该不该显示 tags 段」由各 ContentView 内部判断（resolution.isLocalHit），
//    Scaffold 不参与 sections 决策。这是避免「god view」腐烂路径的关键设计。
//

import Foundation

// MARK: - RepoDetailHero

/// 详情页 Hero header 的数据载体。
///
/// 字段层级与 `Repo` / `StarcatRepoCardDTO` 不同：
/// - 这里是 view-ready 数据（`URL?` / `Date?` 已解析），不再让 view 做字符串解析
/// - 包含 `isStarred` 决定 ⭐/☆ chip 视觉
/// - `ghRepoId` 可空：极少数 minimal fallback 场景下没有 repo id（chain 兜底
///   `MinimalRepoSource` 用 owner/name 构造），此时 star chip 应禁用
struct RepoDetailHero: Sendable {

    /// GitHub 数字 id；nil 时禁用 star chip（Minimal fallback 场景）。
    let ghRepoId: Int64?

    /// `owner/repo` 全名（用于显示 + GitHub 跳转）。
    let fullName: String
    let owner: String
    let repo: String

    /// 头像 URL（owner 头像）。
    let avatarURL: URL?

    /// 描述。
    let description: String?

    /// 主要编程语言。
    let language: String?

    /// Stars 数（star 成功后 N4 决策：用 GitHub `/repos` 最新值覆盖）。
    let starsCount: Int

    /// Forks 数。
    let forksCount: Int

    /// Watchers / Subscribers。后端不一定都有，nil 时 UI 不渲染对应 chip。
    let watchersCount: Int?
    let subscribersCount: Int?

    /// Topics 列表（chip 行）。
    let topics: [String]

    /// SPDX license（如 `MIT` / `Apache-2.0`）。
    let licenseSpdx: String?

    /// 时间字段（已解析）。原始 ISO8601 字符串解析失败时为 nil。
    let updatedAt: Date?
    let createdAt: Date?
    let pushedAt: Date?

    let isArchived: Bool
    let isFork: Bool
    let isPrivate: Bool

    /// 当前用户是否已 star（驱动 ⭐/☆ chip 视觉）。
    let isStarred: Bool

    /// GitHub 网页 URL（外链按钮用）。
    let htmlUrl: URL?

    /// homepage URL（如有）。
    let homepage: URL?
}

// MARK: - Repo → RepoDetailHero

extension RepoDetailHero {

    /// 从本地 `Repo` 构造 view-ready hero 数据（Manage / Activity-repo-backed 路径）。
    ///
    /// 解析时间字段时容错：上游 `Repo.updatedAt/createdAt/pushedAt` 是 ISO8601 字符串，
    /// 解析失败时回退为 nil（hero UI 已经为 nil 时间字段做了 fallback 渲染）。
    init(repo: Repo) {
        self.ghRepoId = repo.id
        self.fullName = repo.fullName
        self.owner = repo.owner
        self.repo = repo.name
        self.avatarURL = URL(string: RepoAvatarURL.from(owner: repo.owner))
        self.description = repo.description
        self.language = repo.language
        self.starsCount = repo.starsCount
        self.forksCount = repo.forksCount
        self.watchersCount = repo.watchersCount
        // Repo 当前无 subscribersCount 字段（GitHub watchers/subscribers 字段名混淆历史问题）；
        // hero 渲染时此 chip 为 nil 即不显示，与现状一致。
        self.subscribersCount = nil
        self.topics = repo.topicsArray
        self.licenseSpdx = repo.license
        self.updatedAt = Self.parseISO8601(repo.updatedAt)
        self.createdAt = Self.parseISO8601(repo.createdAt)
        self.pushedAt = Self.parseISO8601(repo.pushedAt)
        self.isArchived = repo.isArchived
        self.isFork = repo.isFork
        self.isPrivate = repo.isPrivate
        self.isStarred = repo.isStarred
        self.htmlUrl = URL(string: repo.htmlUrl)
        self.homepage = repo.homepage.flatMap { URL(string: $0) }
    }

    /// 从 `StarcatRepoCardDTO` 构造 hero 数据（Trending / Weekly 路径，资源未命中本地）。
    init(dto: StarcatRepoCardDTO, isStarred: Bool) {
        self.ghRepoId = dto.ghRepoId
        self.fullName = dto.fullName
        self.owner = dto.owner
        self.repo = dto.repo
        self.avatarURL = dto.ownerAvatar ?? URL(string: RepoAvatarURL.from(owner: dto.owner))
        self.description = dto.description
        self.language = dto.language
        self.starsCount = dto.stars
        self.forksCount = dto.forks
        self.watchersCount = dto.watchers
        self.subscribersCount = dto.subscribers
        self.topics = dto.topics
        self.licenseSpdx = dto.licenseSpdx
        self.updatedAt = Self.parseISO8601(dto.updatedAt)
        self.createdAt = Self.parseISO8601(dto.createdAt)
        self.pushedAt = Self.parseISO8601(dto.pushedAt)
        self.isArchived = dto.isArchived
        self.isFork = dto.isFork
        self.isPrivate = dto.isPrivate
        self.isStarred = isStarred
        self.htmlUrl = dto.htmlUrl ?? GitHubURLs.repo(owner: dto.owner, repo: dto.repo)
        self.homepage = dto.homepage
    }

    /// ISO8601 字符串 → Date。解析失败返回 nil。
    /// 与 `Repo` 内部时间解析行为对齐——`.withInternetDateTime` 包含 `Z`/offset 处理。
    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

// MARK: - RepoDetailAction

/// 详情页右上 trailing actions（按渲染顺序排）。
///
/// 各场景自由组合：
/// - Manage: `[.share, .ai]`
/// - Trending: `[.share, .ai]`
/// - Weekly: `[.weeklyIssue, .share, .ai]`
/// - Activity-repo-backed: `[.share, .ai]`
///
/// **不**在这里加 `.star` —— star/unstar 触发点是 hero stats 行的 ⭐/☆ chip
/// （v1.0 §3.2.3 决策：避免 trailing actions 与 hero chip 双重入口造成混乱）。
enum RepoDetailAction: Identifiable {

    /// 分享按钮（→ AI 摘要 + 分享卡）。
    ///
    /// Scaffold 内部用 `RepoShareButton(repo:)` 渲染，业务状态（progress / alert）
    /// 由该组件自治。各场景**不需要**自己提供 handler——分享行为对所有 repo 一致。
    case share

    /// AI 窗口按钮（摘要 / 标签 / 对话三段）。
    ///
    /// Scaffold 内部用 `RepoAIOpenButton(repo:)` 渲染，复用现有 AI 窗口控制器。
    case ai

    /// Weekly 场景独有：跳到该期周刊原文。
    case weeklyIssue(number: Int, url: URL)

    /// 自定义 action（未来扩展用）。
    case custom(id: String, label: String, systemImage: String, handler: @MainActor () -> Void)

    var id: String {
        switch self {
        case .share: return "share"
        case .ai: return "ai"
        case .weeklyIssue: return "weeklyIssue"
        case .custom(let id, _, _, _): return "custom-\(id)"
        }
    }
}

// MARK: - ReadmeTranslationContext

/// 翻译浮动按钮的上下文。
///
/// 占位类型 —— 具体字段在 Step 4.3（RepoDetailScaffold 实现）填充。
/// 当前 R-01 范围内只需要类型存在，避免依赖循环：详情页可传 `nil` 表示
/// 不渲染翻译浮动按钮（如 Activity-announcement / release / following）。
///
/// 未来填充内容（参考 `ReadmeTranslationViewModel`）：
/// - `viewModel: ReadmeTranslationViewModel`（VM 由父级注入）
/// - 是否启用翻译 / 当前目标语言 / 错误状态等
struct ReadmeTranslationContext: Sendable {
    /// owner/repo 全名（VM 通过此键查缓存 + 触发翻译）。
    let fullName: String

    /// 占位 init —— 后续 Step 4.3 实现 Scaffold 时按需扩展字段。
    init(fullName: String) {
        self.fullName = fullName
    }
}

// MARK: - RepoDetailViewData

/// 详情页输入给 `RepoDetailScaffold` 的视图数据汇总。
///
/// **不再**有 DetailSections 配置（v1.1 关键决策）：「该不该显示 tags 段」由各
/// ContentView 内部判断 `resolution.isLocalHit` 决定，Scaffold 只渲染 hero / actions
/// / 翻译 / 刷新 / 折叠面板等通用骨架部分。
struct RepoDetailViewData {

    /// Hero header 输入数据。
    let hero: RepoDetailHero

    /// 右上 trailing actions（按显示顺序排）。
    let trailingActions: [RepoDetailAction]

    /// 翻译数据源；nil 时不渲染翻译浮动按钮。
    let translation: ReadmeTranslationContext?

    /// 各场景可选传入的「列表 hint DTO」，给 `RepoResolver` chain 用。
    /// 仅 Trending / Weekly 详情会传非 nil（Manage 详情来自本地 SQLite，不需要 hint）。
    let backendHint: StarcatRepoCardDTO?

    init(
        hero: RepoDetailHero,
        trailingActions: [RepoDetailAction] = [],
        translation: ReadmeTranslationContext? = nil,
        backendHint: StarcatRepoCardDTO? = nil
    ) {
        self.hero = hero
        self.trailingActions = trailingActions
        self.translation = translation
        self.backendHint = backendHint
    }
}
