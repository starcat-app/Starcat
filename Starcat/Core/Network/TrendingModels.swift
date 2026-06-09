//
//  TrendingModels.swift
//  Starcat
//
//  GitHub Trending API 响应 DTO。
//
//  数据源：https://starcat-trending-api.fly.dev/repo
//  API 参数：since (daily/weekly/monthly), lang (语言筛选)
//
//  设计约束：
//  - DTO 字段名与上游 API 保持一致（snake_case）
//  - 不做业务逻辑转换，只做解码
//

import Foundation
import SwiftUI

// MARK: - API Response（已删，R-01 v1.2 走 envelope）
//
// 旧的非 envelope `TrendingResponseDTO` / `TrendingContributorDTO` 在 R-01 v1.2 改造后已废。
// 新数据流：API 响应 envelope → `StarcatEnvelope<[StarcatRepoCardDTO]>` → 由 `TrendingRepo.init(card:since:)`
// 转 UI 模型。后端字段集见 `Starcat/Core/Network/StarcatRepoCardDTO.swift`。

// MARK: - Domain Model

/// Trending 仓库领域模型。
///
/// R-01 v1.2 起从 `StarcatRepoCardDTO + TrendingExtension` 转换而来（见 `init(card:since:)`）。
/// 包含计算属性用于格式化显示。
struct TrendingRepo: Identifiable, Equatable {
    /// 唯一标识（使用 fullName 作为 id）
    var id: String { fullName }

    /// GitHub repo 数字 id。
    ///
    /// R-01 v1.2（2026-06-10）：从 `StarcatRepoCardDTO.ghRepoId` 透传。trending 列表
    /// 内部 SwiftUI diff 仍用 `fullName`（兼容旧 selection binding）；`ghRepoId` 主要
    /// 给 `RepoCardViewData.id`（UnifiedRepoRow row diff key）+ `StarredRegistry.contains`
    /// 使用——后者是设计 §3.1.2 跨场景标记的核心入口。
    let ghRepoId: Int64

    /// owner/repo 格式完整名
    let fullName: String

    /// owner 部分
    let owner: String

    /// repo 名称
    let name: String

    /// GitHub 仓库 URL
    let url: URL

    /// 仓库描述
    let description: String?

    /// 主要编程语言
    let language: String?

    /// 当前总 stars（可变，用于本地 star 操作后 +1）
    var starsCount: Int

    /// 当前 forks
    let forksCount: Int

    /// 周期内新增 stars
    let starsInPeriod: Int

    /// 周期文本描述（如 "321 stars today"）
    let periodText: String

    /// 贡献者列表
    let contributors: [Contributor]

    // MARK: - R-01 v1.2 GRDB v8 新字段（2026-06-10 落地）
    //
    // 这 4 字段从 `StarcatRepoCardDTO` 透传过来，对应 trending_repos 表 v8 新加 4 列。
    // 全部 Optional：trending API 返回的 DTO 不一定填满（enricher 可能没补全
    // owner_avatar 等字段；离线缓存 v8 之前的行也是 NULL）。

    /// 仓库所有者头像 URL（GitHub `owner.avatar_url`），UI hero 区直接渲染。
    let ownerAvatar: URL?
    /// 订阅者数（GitHub `subscribers_count`），与 watchers 不同。
    let subscribersCount: Int?
    /// 默认分支（如 `main` / `master`）。
    let defaultBranch: String?
    /// 未关闭 issue 数（GitHub `open_issues_count`）。
    let openIssuesCount: Int?

    /// R-01 v1.2 初始化：从 envelope 化的 `StarcatRepoCardDTO` + 周期信息构造。
    ///
    /// 字段映射：
    ///   - `card.fullName` / `card.owner` / `card.repo` → `fullName` / `owner` / `name`
    ///   - `card.htmlUrl` 优先；缺失时 fallback 用 `GitHubURLs.repo(owner:repo:)` 重建
    ///   - `card.description` / `card.language` → `description` / `language`
    ///   - `card.stars` / `card.forks` → `starsCount` / `forksCount`
    ///   - `card.trending?.change` → `starsInPeriod`（缺扩展段时退化为 0）
    ///   - `card.trending?.contributors` → `contributors` 数组（缺扩展段时空数组）
    ///
    /// **R-01 v1.2 GRDB v8 新增（2026-06-10）**：
    ///   `card.ownerAvatar` / `card.subscribers` / `card.defaultBranch` / `card.openIssues`
    ///   → `ownerAvatar` / `subscribersCount` / `defaultBranch` / `openIssuesCount`
    ///
    /// 仍未利用的 DTO 字段（v1.2 边界内但 trending UI 暂不需要）：
    ///   `gh_repo_id`（trending 用 fullName 作 PK，不依赖 GitHub id）/
    ///   `watchers` / `topics` / `homepage` / `license_spdx` /
    ///   `is_archived` / `is_fork` / `is_private` / `pushed_at` / `updated_at` / `created_at`
    init(card: StarcatRepoCardDTO, since: TrendingPeriod) {
        self.ghRepoId = card.ghRepoId
        self.fullName = card.fullName
        self.owner = card.owner
        self.name = card.repo
        self.url = card.htmlUrl ?? GitHubURLs.repo(owner: card.owner, repo: card.repo)
        self.description = card.description
        self.language = card.language
        self.starsCount = card.stars
        self.forksCount = card.forks
        self.starsInPeriod = card.trending?.change ?? 0

        // 周期文本：只显示数字，如 "+321" / "0"。
        let prefix = self.starsInPeriod > 0 ? "+" : ""
        self.periodText = "\(prefix)\(self.starsInPeriod)"

        // 后端 contributors 已是「avatar URL + login」结构化字段，前端零字符串处理。
        self.contributors = (card.trending?.contributors ?? []).map { c in
            Contributor(
                username: c.login,
                avatarURL: c.avatar,
                profileURL: GitHubURLs.userProfile(login: c.login)
            )
        }

        // R-01 v1.2 GRDB v8 4 字段透传（DTO 对应字段直接拿）
        self.ownerAvatar = card.ownerAvatar
        self.subscribersCount = card.subscribers
        self.defaultBranch = card.defaultBranch
        self.openIssuesCount = card.openIssues
    }

    /// 贡献者模型。
    struct Contributor: Identifiable, Equatable {
        var id: String { username }
        let username: String
        let avatarURL: URL?
        let profileURL: URL?
    }
}

// MARK: - Period

/// Trending 时间周期。
enum TrendingPeriod: String, CaseIterable, Identifiable {
    case daily = "daily"
    case weekly = "weekly"
    case monthly = "monthly"

    var id: String { rawValue }

    /// SwiftUI 控件里展示的本地化周期名称。
    var displayName: LocalizedStringKey {
        switch self {
        case .daily:   return "trending.period.daily"
        case .weekly:  return "trending.period.weekly"
        case .monthly: return "trending.period.monthly"
        }
    }

    /// 需要 plain String 的 API 使用，例如 navigationSubtitle。
    var localizedDisplayName: String {
        switch self {
        case .daily:   return String(localized: "trending.period.daily")
        case .weekly:  return String(localized: "trending.period.weekly")
        case .monthly: return String(localized: "trending.period.monthly")
        }
    }

    /// 英文名称（用于 API 参数）
    var apiValue: String { rawValue }
}

// MARK: - Language

/// Trending 语言筛选项。
///
/// 这里故意用 struct 而不是固定 enum：左侧 Trending 入口会复用用户本地
/// `Languages` 聚合结果，语言集合随用户 stars 变化，不应该被硬编码 case 限住。
struct TrendingLanguage: Hashable, Identifiable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue.isEmpty ? "<all>" : rawValue }

    /// 语言名称来自 API / 本地聚合，非空值必须按原样显示；只有“全部语言”走本地化。
    var localizedDisplayName: String {
        rawValue.isEmpty ? String(localized: "trending.allLanguages") : rawValue
    }

    /// API 参数值（空字符串表示全部）。
    var apiValue: String { rawValue }

    static let all = TrendingLanguage("")
    static let swift = TrendingLanguage("Swift")
    static let python = TrendingLanguage("Python")
    static let typescript = TrendingLanguage("TypeScript")
    static let javascript = TrendingLanguage("JavaScript")
    static let go = TrendingLanguage("Go")
    static let rust = TrendingLanguage("Rust")
    static let java = TrendingLanguage("Java")
    static let kotlin = TrendingLanguage("Kotlin")
    static let dart = TrendingLanguage("Dart")
}
