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
//    + `CardBadge.activityKind(_, _)` 携带左上 kind icon 和右上时间。
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

    /// 场景独有徽章（trending +N / weekly 第 N 期 / activity kind icon）。
    let badge: CardBadge?
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

    /// Activity 场景：左上 kind icon + 右上相对时间。
    /// `Date` 用于显示「3 天前」相对时间；`ActivityCategory` 决定 icon。
    case activityKind(ActivityCategory, Date)
}

// MARK: - Repo → RepoCardViewData

extension Repo {

    /// 把已 star 的本地 `Repo` 转为卡片视图数据。
    ///
    /// - Parameter badge: 场景独有徽章（manage 场景通常 nil）
    /// - Returns: 视图数据；`isStarred` 直接读 `self.isStarred`（本地 DB 是真值）
    func asCardData(badge: CardBadge? = nil) -> RepoCardViewData {
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
            badge: badge
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
    func asCardData(registry: StarredRegistry, badge: CardBadge? = nil) -> RepoCardViewData {
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
            badge: badge
        )
    }
}
