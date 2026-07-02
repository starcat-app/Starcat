//
//  RepoCardViewData.swift
//  Starcat
//
//  R-01「三场景共用架构」卡片视图数据（适配层）。
//
//  设计意图（详细设计 §4.4）：
//  - 所有 repo-backed 场景的卡片 view（Manage / Trending / Weekly / Activity-repo-backed）
//    只依赖此类型，不直接依赖 `Repo` / `StarcatRepoCardDTO`
//  - 解决 D-17：4 处 row surface 视觉骨架 95% 相同但模型不同的痛点
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⚠️ id 用 Int64 (ghRepoId) 而非 fullName（v1.1 dong4j review）
//  ────────────────────────────────────────────────────────────────────────────
//
//  GitHub repo rename 后 fullName 变 → SwiftUI `List(selection:)` / ForEach diff
//  会把「旧卡片消失 + 新卡片出现」当成两个事件，selection 丢失 + 列表闪烁。
//
//  gh_repo_id 永不变（即使改名也是同一个 id），是唯一可靠的稳定主键。
//  N5 决策已保证 enricher 未补全的 repo 后端不返回（trending / weekly 列表里
//  100% 有 gh_repo_id），因此本类型 `id: Int64` 不需要 optional 或者 fallback。
//
//  ────────────────────────────────────────────────────────────────────────────
//  Activity 非 repo-backed 卡片不走本类型
//  ────────────────────────────────────────────────────────────────────────────
//
//  - announcement / release / following 三类 Activity 卡片**不**用 RepoCardViewData，
//    因为它们的视觉骨架与 repo 卡片差异较大（左上 kind icon、右上相对时间、body 是
//    release notes 等）。这些走 ActivityViewModel 自己的视图数据，沿用现状。
//  - star / repository / suggestion 三类是 repo-backed 的，可以走 RepoCardViewData
//    + `CardBadge.activityKind(_)` 携带头像左下 kind icon 角标。
//    （v2.0 起右上相对时间已删；详见 `CardBadge.activityKind` 文档注释。）
//

import Foundation

// MARK: - RepoCardViewData

/// 卡片视图数据（适配层）。
///
/// - Note: 转换扩展（`Repo.asCardData()` / `StarcatRepoCardDTO.asCardData(...)`)
///   负责从领域模型 → 视图数据，UI 层只看本类型，不需要知道数据来自哪里。
struct RepoCardViewData: Identifiable, Hashable, Sendable {

    /// SwiftUI Identifiable / List(selection:) / ForEach diff 用的稳定 id。
    /// 直接复用 `ghRepoId`（GitHub 数字 id），rename 不影响 diff。
    var id: Int64 { ghRepoId }

    /// GitHub 数字 id（必填）。
    let ghRepoId: Int64

    /// `owner/repo` 格式完整名（仅显示）。
    let fullName: String

    /// owner login。用于跳转 / 显示。
    let owner: String

    /// repo 名（不含 owner 前缀）。
    let repo: String

    /// 头像 URL（owner 头像）。
    let avatarURL: URL?

    /// 描述（GitHub 原文，未过滤 emoji shortcode）。
    let description: String?

    /// 主要编程语言。
    let language: String?

    /// Stars 数。
    let starsCount: Int

    /// Forks 数。后端 enricher 未补全时退化为 0；UI 显示时若 0 可以渲染 "—"。
    let forksCount: Int

    let isArchived: Bool
    let isFork: Bool
    let isPrivate: Bool

    /// 当前用户是否已 star 此 repo。
    /// 由转换层填好（`Repo.isStarred` 直接读，DTO 转换时通过 `StarredRegistry.contains` 查询）。
    /// SwiftUI 监听到 registry 变更后会重新调用转换扩展，本字段同步刷新。
    let isStarred: Bool

    /// 当前 repo 是否已加入 Starcat 私有知识库。
    ///
    /// 该字段必须由调用方显式注入；默认 false 表示“未查询/不展示”，避免
    /// Trending / Weekly 等远端列表在没有本地 `library_state` 信号时误画 ❤️。
    let isInLibrary: Bool

    /// 场景独有徽章（trending +N / weekly 第 N 期 / activity kind icon）。
    let badge: CardBadge?

    /// Weekly 三源标识。仅 Weekly feed 传入；其它场景保持空数组。
    let weeklySources: [WeeklySource]

    /// Weekly 三源短标签：ruanyf 显示期号、ZRead 显示周、HN 显示短日期。
    let weeklySourceLabel: String?

    /// fullName 同行右侧的轻量元信息。Release 聚合卡片用它展示最新发布时间；
    /// 其它场景保持 nil，避免恢复已删除的右上相对时间戳。
    let inlineMetadata: RepoCardInlineMetadata?

    /// 阅读状态（v2，2026-06-12 引入）。
    ///
    /// **设计意图**：让列表 row 在 chip 行末尾渲染 unread / using 角标，
    /// 帮用户在主列表"一眼分辨哪些 starred repo 还没看 / 哪些正在用"。
    ///
    /// **填充语义**：
    /// - **nil**：调用方没查 / 没传（trending / weekly / activity 默认走这）
    ///   → UnifiedRepoRow **不渲染**任何状态角标（即使 isStarred == true）
    /// - **.unread / .read / .using**：调用方已显式查询并传入
    ///   → 渲染规则：`isStarred && readStatus != .read` 才显示角标
    ///
    /// 之所以让 nil 与 .unread 区分（而不是直接默认 .unread），是因为
    /// trending/weekly ephemeral 列表里 100% 的 row 都是「未在 repo_notes 写过」
    /// → 全部当 implicit unread → 整页都亮红点 = 视觉污染。让调用方显式声明
    /// 才是"对 readStatus 信号负责"的语义。
    ///
    /// **目前已接入路径**：Manage（`RepoListView`）
    /// **暂未接入**：Trending / Weekly / Activity（保持 nil；后续按需扩展）
    let readStatus: RepoStatus?

    /// OpenSSF Scorecard 安全评分徽章。
    ///
    /// nil 表示本地没有可展示的成功评分；列表 row 必须整块不渲染，也不能在
    /// body 里触发网络请求。刷新由后台 poller 或详情页 fire-and-forget 预拉负责。
    let openSSFScore: OpenSSFScoreBadgeData?

    /// Repo Health 聚合健康度徽章（2026-06-21 dong4j 反馈"列表 row 也加 Health badge"）。
    ///
    /// 渲染语义与 `openSSFScore` 对称：
    /// - nil → row 不渲染（无本地缓存，由 `RepoHealthStore.badge(for:)` 返回 nil）
    /// - 非 nil → row 渲染胶囊（gauge icon + 分数 + 等级）
    ///
    /// Pro gate 由详情页入口负责（`entitlementGate.requirePro(.repoHealth)`），
    /// 列表行不做 gate：缓存存在即可视化，与 OpenSSF 行为一致。
    let healthBadge: RepoHealthBadgeData?
}

struct RepoCardInlineMetadata: Hashable, Sendable {
    let systemImage: String
    let text: String
}

// MARK: - CardBadge

/// 场景独有的卡片徽章。
///
/// 设计意图：用 enum 而不是「多 optional 字段」（如 `weeklyIssue: Int? + trendingChange: Int?`）
/// 是因为：① 同一张卡片只可能命中一种徽章语义；② 关联值天然紧凑，避免「这两个字段同时
/// 非空到底渲染哪个」的二义性；③ 未来加新徽章只新增 case，不动现有调用点。
///
/// **不要**在这里加「编辑点评 / 推荐理由 / AI 评分」等内容字段（详细设计 §6.1.4 硬边界
/// 规则同样适用：Article 字段不污染 Repo 卡片 schema）。如果 Weekly 演化出 article
/// 模型，新建 `WeeklyArticleCardViewData`，不要扩展 `CardBadge`。
enum CardBadge: Hashable, Sendable {
    /// Trending 场景：本期榜单 stars 增量（如 daily +321）。
    case trendingChange(Int)

    /// Weekly 场景：项目首次被收录的期号（如「第 399 期」）。
    case weeklyIssue(Int)

    /// Activity 场景：头像左下角 kind icon 圆角标。
    /// `ActivityCategory` 决定 icon 形状与配色。
    ///
    /// **v2.0（2026-06-11 dong4j 决策）去掉 `Date` 第二参**：
    /// 原 `.activityKind(ActivityCategory, Date)` 用 `Date` 在卡片右上角渲染
    /// `RelativeDateBadge`「3 天前」相对时间，但 `Date` 的真实语义按 kind 漂移
    /// 严重（`.star` = starredAt / `.repository` & `.suggestion` = pushedAt /
    /// `.release` 走老的 `ActivityRowView` 不进这里），在 `.all` 视图同框时
    /// 用户根本分不清"5 分钟前"指 star 行为还是 repo push。dong4j 体测后判定
    /// 右上时间戳"信息密度低 + 语义漂移"得不偿失,选择整列去掉,头像左下 kind icon
    /// + 行内 chip 区已经能传达足够信号。`.release` / `.announcement` 走
    /// `ActivityRowView`（不进 UnifiedRepoRow）的时间戳保留不动。
    case activityKind(ActivityCategory)
}

// MARK: - Repo → RepoCardViewData

extension Repo {

    /// 把已 star 的本地 `Repo` 转为卡片视图数据。
    ///
    /// - Parameters:
    ///   - badge: 场景独有徽章（manage 场景通常 nil）
    ///   - inlineMetadata: fullName 同行右侧的小型元信息（发行版聚合卡片使用）
    ///   - readStatus: 阅读状态（Manage 场景由 `HomeViewModel.statusMap` 注入；
    ///     其他场景保持 nil 即可，UnifiedRepoRow 不会渲染角标）
    /// - Returns: 视图数据；`isStarred` 直接读 `self.isStarred`（本地 DB 是真值）
    func asCardData(
        badge: CardBadge? = nil,
        inlineMetadata: RepoCardInlineMetadata? = nil,
        readStatus: RepoStatus? = nil,
        isInLibrary: Bool = false,
        openSSFScore: OpenSSFScoreBadgeData? = nil,
        healthBadge: RepoHealthBadgeData? = nil
    ) -> RepoCardViewData {
        RepoCardViewData(
            ghRepoId: self.id,
            fullName: self.fullName,
            owner: self.owner,
            repo: self.name,
            avatarURL: nil,                  // Repo 表暂未存 avatar；UI 层可由 owner login 拼
            description: self.description,
            language: self.language,
            starsCount: self.starsCount,
            forksCount: self.forksCount,
            isArchived: self.isArchived,
            isFork: self.isFork,
            isPrivate: self.isPrivate,
            isStarred: self.isStarred,
            isInLibrary: isInLibrary,
            badge: badge,
            weeklySources: [],
            weeklySourceLabel: nil,
            inlineMetadata: inlineMetadata,
            readStatus: readStatus,
            openSSFScore: openSSFScore,
            healthBadge: healthBadge
        )
    }
}

// MARK: - StarcatRepoCardDTO → RepoCardViewData

extension StarcatRepoCardDTO {

    /// 把后端 DTO（trending / weekly）转为卡片视图数据。
    ///
    /// - Parameters:
    ///   - registry: 全局已 star 集合，用于回填 `isStarred`（设计 §3.1.2 跨场景标记）
    ///   - badge: 场景独有徽章；通常由 ViewModel 在 `dto.toCardData(...)` 调用处决定
    /// - Returns: 视图数据；`isStarred` = `registry.contains(ghRepoId:)`
    @MainActor
    func asCardData(
        registry: StarredRegistry,
        badge: CardBadge? = nil,
        openSSFScore: OpenSSFScoreBadgeData? = nil,
        healthBadge: RepoHealthBadgeData? = nil
    ) -> RepoCardViewData {
        RepoCardViewData(
            ghRepoId: self.ghRepoId,
            fullName: self.fullName,
            owner: self.owner,
            repo: self.repo,
            avatarURL: self.ownerAvatar,
            description: self.description,
            language: self.language,
            starsCount: self.stars,
            forksCount: self.forks,
            isArchived: self.isArchived,
            isFork: self.isFork,
            isPrivate: self.isPrivate,
            isStarred: registry.contains(ghRepoId: self.ghRepoId),
            isInLibrary: false,
            badge: badge,
            weeklySources: [],
            weeklySourceLabel: nil,
            inlineMetadata: nil,
            readStatus: nil,
            openSSFScore: openSSFScore,
            healthBadge: healthBadge
        )
    }
}

// MARK: - TrendingRepo → RepoCardViewData

extension TrendingRepo {

    /// 把 Trending 领域模型转为卡片视图数据。
    ///
    /// 由 `TrendingView` 列表 row 在每次重渲染时调用。`isStarred` 通过 registry 查询，
    /// 让 row 上的 ✓ 标记在用户 star/unstar 后即时同步（registry 是 `@Observable`，
    /// SwiftUI 监听变更后触发整个 List 重渲染，本扩展会被重新调用）。
    ///
    /// - Parameters:
    ///   - registry: 全局已 star 集合
    ///   - badge: 通常传 `.trendingChange(repo.starsInPeriod)` 复刻 +N chip。
    ///            外部如需特殊场景可传 nil（暂无此需求）。
    /// - Returns: 视图数据
    @MainActor
    func asCardData(
        registry: StarredRegistry,
        badge: CardBadge? = nil,
        openSSFScore: OpenSSFScoreBadgeData? = nil,
        healthBadge: RepoHealthBadgeData? = nil
    ) -> RepoCardViewData {
        let resolvedBadge = badge ?? .trendingChange(self.starsInPeriod)
        return RepoCardViewData(
            ghRepoId: self.ghRepoId,
            fullName: self.fullName,
            owner: self.owner,
            repo: self.name,
            avatarURL: self.ownerAvatar,
            description: self.description,
            language: self.language,
            starsCount: self.starsCount,
            forksCount: self.forksCount,
            isArchived: false,
            isFork: false,
            isPrivate: false,
            isStarred: registry.contains(ghRepoId: self.ghRepoId),
            isInLibrary: false,
            badge: resolvedBadge,
            weeklySources: [],
            weeklySourceLabel: nil,
            inlineMetadata: nil,
            readStatus: nil,
            openSSFScore: openSSFScore,
            healthBadge: healthBadge
        )
    }
}

// MARK: - WeeklyFeedItem → RepoCardViewData

extension WeeklyFeedItem {

    /// 把 Weekly 领域模型转为卡片视图数据。
    ///
    /// - Parameters:
    ///   - registry: 全局已 star 集合（决定 ✓ 标记）
    ///   - badge: 三源聚合列表默认不挂 badge，来源图标与短标签单独渲染。
    /// - Returns: 视图数据
    @MainActor
    func asCardData(
        registry: StarredRegistry,
        badge: CardBadge? = nil,
        openSSFScore: OpenSSFScoreBadgeData? = nil,
        healthBadge: RepoHealthBadgeData? = nil
    ) -> RepoCardViewData {
        return RepoCardViewData(
            ghRepoId: card.ghRepoId,
            fullName: card.fullName,
            owner: card.owner,
            repo: card.repo,
            avatarURL: card.ownerAvatar,
            description: card.description,
            language: card.language,
            starsCount: card.stars,
            forksCount: card.forks,
            isArchived: card.isArchived,
            isFork: card.isFork,
            isPrivate: card.isPrivate,
            isStarred: registry.contains(ghRepoId: card.ghRepoId),
            isInLibrary: false,
            badge: badge,
            weeklySources: sourceTypes,
            weeklySourceLabel: shortSourceLabel,
            inlineMetadata: nil,
            readStatus: nil,
            openSSFScore: openSSFScore,
            healthBadge: healthBadge
        )
    }
}
