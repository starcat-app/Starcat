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

    // MARK: - R-01 v1.2 StarcatRepoCardDTO 扩展 4 字段（2026-06-10 落地）
    //
    // 这 4 字段从 `StarcatRepoCardDTO` 透传过来，对应 `trending_repos` 表的同名 4 列。
    // 全部 Optional：trending API 返回的 DTO 不一定填满（enricher 可能没补全
    // owner_avatar 等字段，下游 toDomain / makeEphemeralRepo 端 graceful 退化）。

    /// 仓库所有者头像 URL（GitHub `owner.avatar_url`），UI hero 区直接渲染。
    let ownerAvatar: URL?
    /// 订阅者数（GitHub `subscribers_count`），与 watchers 不同。
    let subscribersCount: Int?
    /// 默认分支（如 `main` / `master`）。
    let defaultBranch: String?
    /// 未关闭 issue 数（GitHub `open_issues_count`）。
    let openIssuesCount: Int?

    // MARK: - R-05 trending 详情页字段补齐 10 字段（2026-06-11 落地）
    //
    // 这 10 字段从 `StarcatRepoCardDTO` 透传过来，对应 `trending_repos` 表的同名 10 列
    // （schema 详见 `DatabaseMigrationsV1.swift` 的 `createTrendingRepos`）。
    // 全部 Optional：trending-api 偶发字段缺失时退化为 nil；
    // 让 toDomain / makeEphemeralRepo 端 graceful 退化（Bool? → false / Int? → 0）。
    //
    // **R-05 修补动机**：trending 详情页（未 star 走 `makeEphemeralRepo()` 兜底路径）
    // 之前显示 Watchers=0 / Created=- / Updated=- / License=N/A / Topics=N/A —— 不是
    // trending-api 后端没拉（enricher 调 GET /repos/{o}/{r} 拉满了），是 v1.2 落地时
    // `TrendingRepo.init(card:since:)` 把这 10 字段标为「v1.2 边界内但 trending UI
    // 暂不需要」直接丢弃，下游 `makeEphemeralRepo()` 只能填默认值（0 / nil）。
    //
    // **持久化语义**：与 `Repo` 表对齐 —— `topics` 存 JSON 数组字符串（如
    // `["ai","swift"]`）而非 [String]，避免再开一张 trending_topics 明细表 +
    // 让 toDomain/from 完全一一映射，与 `repos.topics` 命名完全对齐。

    /// Watchers 总数（GitHub `watchers_count`，注：API 字段实际等于 stars；真"watchers"
    /// 语义看 subscribersCount。此处尊重 DTO 透传，UI 显示哪个由 hero/详情决定）。
    let watchersCount: Int?
    /// Topics JSON 数组字符串（如 `["ai","swift"]`）。与 `Repo.topics` 同语义同格式。
    /// 解析时 UI 层用 `Repo.parsedTopics()` 之类 helper（已存在）。
    let topics: String?
    /// SPDX 许可证标识符（如 `MIT` / `Apache-2.0`）。
    let license: String?
    /// 项目主页 URL（GitHub `homepage`）。`nil` 表示 enricher 拿到空串后已归一化（详
    /// 见 `StarcatRepoCardDTO.decodeOptionalURL`）。
    let homepage: URL?
    /// 仓库是否归档。
    let isArchived: Bool?
    /// 是否 fork 自其他仓库。
    let isFork: Bool?
    /// 是否私有仓库（trending 场景应总是 false，但保留字段防御外部 schema 变化）。
    let isPrivate: Bool?
    /// 最后一次 push 的 ISO8601 时间字符串。
    let pushedAt: String?
    /// 仓库创建的 ISO8601 时间字符串。
    let createdAt: String?
    /// 最后一次更新的 ISO8601 时间字符串。
    let updatedAt: String?

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
    /// **R-01 v1.2 扩展 4 字段（2026-06-10）**：
    ///   `card.ownerAvatar` / `card.subscribers` / `card.defaultBranch` / `card.openIssues`
    ///   → `ownerAvatar` / `subscribersCount` / `defaultBranch` / `openIssuesCount`
    ///
    /// **R-05 新增 10 字段（2026-06-11）**：补齐 trending 详情页 hero/
    /// 详情区显示 watchers / topics / license / homepage / created / updated / pushed /
    /// archived / fork / private 这 10 字段所需的全部透传——之前因为 trending 列表 row
    /// 不展示这些字段被错误标为「v1.2 边界内但 trending UI 暂不需要」，导致
    /// `makeEphemeralRepo()` 兜底路径只能填默认值。**Topics 字段做一次性 [String] →
    /// JSON 字符串编码**，与 `Repo.topics` 持久化格式对齐，下游 `makeEphemeralRepo()`
    /// 直接透传不再编码。
    ///
    /// 仍未利用的 DTO 字段（确认 trending 不需要）：
    ///   `gh_repo_id`（trending 用 fullName 作 PK，不依赖 GitHub id；但 ghRepoId 已透传作 Repo.id）
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

        // R-01 v1.2 扩展 4 字段透传（DTO 对应字段直接拿）
        self.ownerAvatar = card.ownerAvatar
        self.subscribersCount = card.subscribers
        self.defaultBranch = card.defaultBranch
        self.openIssuesCount = card.openIssues

        // R-05 详情页 10 字段透传（DTO → TrendingRepo）
        //
        // - watchers / homepage / license / pushedAt / createdAt / updatedAt / isArchived /
        //   isFork / isPrivate：DTO 字段直接透传
        // - topics：DTO 是 `[String]`；TrendingRepo 与 Repo 表对齐用 String?(JSON)。
        //   一次性编码集中在这里，下游 makeEphemeralRepo / record 持久化全部直接拷贝。
        //   编码失败极罕见（[String] → JSON 几乎不可能失败），退化为 nil 让后续链路
        //   把 topics 段视为「无数据」隐藏，不阻塞 trending 卡片其它字段渲染。
        self.watchersCount = card.watchers
        self.topics = Self.encodeTopicsJSON(card.topics)
        self.license = card.licenseSpdx
        self.homepage = card.homepage
        self.isArchived = card.isArchived
        self.isFork = card.isFork
        self.isPrivate = card.isPrivate
        self.pushedAt = card.pushedAt
        self.createdAt = card.createdAt
        self.updatedAt = card.updatedAt
    }

    /// [String] → JSON 字符串编码（与 `StarcatRepoCardDTO.toEphemeralRepo()` 同语义）。
    /// 空数组返回 nil；编码失败也返回 nil（不让 trending 卡片整体降级）。
    private static func encodeTopicsJSON(_ topics: [String]) -> String? {
        guard !topics.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(topics),
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    /// 贡献者模型。
    struct Contributor: Identifiable, Equatable {
        var id: String { username }
        let username: String
        let avatarURL: URL?
        let profileURL: URL?
    }

    // MARK: - Ephemeral Repo 构造（详情页 hero 兜底）

    /// 把 `TrendingRepo` 转为 in-memory 临时 `Repo`，用于详情页 hero 渲染。
    ///
    /// **使用场景**：用户点开一个**未本地 star** 的 trending row 时，详情页 hero
    /// 区需要立即拿到 `Repo` 渲染（fullName / stars / forks / language / topics
    /// / 创建时间 / 更新时间 等）。R-01 v1.2 Phase B3（2026-06-10）切到
    /// `RepoDetailScaffold` 后，trending 分支不再手写 hero —— 必须把 trending 模型
    /// 转为 `Repo` 才能喂给 Scaffold。
    ///
    /// **关键约束**：
    /// - `id = ghRepoId`（R-01 v1.2 起 trending row 必填）；ghRepoId 为 0 退化代表「过渡 row」，
    ///   调用方应通过 `id == 0` 判断「无法 star/unstar」。
    /// - **不要落 DB**：仅限「详情页 hero 区域不至于完全空着」。`isStarred` 永远 false，
    ///   落库会污染本地用户 star 列表。
    /// - **isStarred 永远 false**：trending 模型不知道当前用户的 star 状态，调用方应
    ///   通过 `StarredRegistry.contains(ghRepoId:)` 判断真实 star 状态后覆盖。
    /// - 字段缺失行为（R-05 修订，2026-06-11）：trending-api enricher 已经从 GitHub
    ///   /repos/{o}/{r} 拉满了 watchers / topics / license / homepage / created /
    ///   updated / pushed / archived / fork / private 共 10 字段，全部透传到
    ///   `TrendingRepo`，再透传到这里，**详情页不再显示 0 / N/A / -**。仅当 trending-api
    ///   enricher 偶发字段缺失时退化为 nil/默认，hero 端能 graceful 处理。
    ///
    /// **本地命中优先**：调用方应**先**通过 `repoRepository.findByOwnerName(owner:name:)`
    /// 查本地真值；只有未命中时才退化到本方法。本地真值含完整 v1.2 14 字段。
    func makeEphemeralRepo() -> Repo {
        let resolvedHtmlUrl = self.url.absoluteString
        return Repo(
            id: self.ghRepoId,                      // R-01 v1.2 起 trending row 必填；为 0 时调用方需检查
            owner: self.owner,
            name: self.name,
            fullName: self.fullName,
            description: self.description,
            language: self.language,
            starsCount: self.starsCount,
            forksCount: self.forksCount,
            // R-05 起：以下字段从 DTO 透传过来（trending-api 缺字段时退化为 nil/默认）
            watchersCount: self.watchersCount ?? 0,
            topics: self.topics,                    // 已是 JSON 字符串与 Repo.topics 对齐
            license: self.license,
            homepage: self.homepage?.absoluteString,
            htmlUrl: resolvedHtmlUrl,
            cloneUrl: nil,                          // trending DTO 不含；保持 nil
            sshUrl: nil,                            // trending DTO 不含；保持 nil
            isPrivate: self.isPrivate ?? false,
            isFork: self.isFork ?? false,
            isArchived: self.isArchived ?? false,
            isStarred: false,                       // ephemeral；调用方按 registry 真值覆盖
            pushedAt: self.pushedAt,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt,
            starredAt: nil,
            cachedAt: nil,
            ownerAvatar: self.ownerAvatar?.absoluteString,
            subscribersCount: self.subscribersCount,
            defaultBranch: self.defaultBranch,
            openIssuesCount: self.openIssuesCount
        )
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
        case .daily:   return String.l10n("trending.period.daily")
        case .weekly:  return String.l10n("trending.period.weekly")
        case .monthly: return String.l10n("trending.period.monthly")
        }
    }

    /// 英文名称（用于 API 参数）
    var apiValue: String { rawValue }
}

// MARK: - Language

/// Trending 语言筛选项。
///
/// 这里故意用 struct 而不是固定 enum：左侧 Trending 入口的语言集合来自
/// 后端 `/api/v1/languages` 聚合接口（基于 trending_repos 实际数据），
/// 不应该被硬编码 case 限住。后端返空 / 不可达时退化到下方的 `fallbackList`。
///
/// **特殊值（哨兵）**：
///   - `.all`：rawValue=""，表示「全部语言」UI 入口，不向后端发 lang 参数
///   - `.uncategorized`：rawValue=`__uncategorized__`，与后端常量
///     `model.UncategorizedLanguageKey` 完全对齐——查询 `language IS NULL OR ''` 的 repo
///
/// 设计意图：哨兵值由前后端共同维护，**不要**改这个字符串值，否则后端旧客户端会出现
/// 「未分类入口选了，但后端不识别 → 兜底走精确匹配 → 永远返 0 条」的隐性错误。
struct TrendingLanguage: Hashable, Identifiable, Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String {
        if rawValue.isEmpty { return "<all>" }
        // uncategorized 哨兵已经包含双下划线，与任何真实语言名碰不到，不需要额外前缀
        return rawValue
    }

    /// 是否为「未分类」哨兵。UI 行 / 详情页判断专用。
    var isUncategorized: Bool { rawValue == Self.uncategorizedKey }

    /// 语言名称来自 API / 本地聚合，非空值原样显示；
    /// 「全部」/「未分类」走本地化（i18n 决定文案，独立于后端 label）。
    var localizedDisplayName: String {
        if rawValue.isEmpty {
            return String.l10n("trending.allLanguages")
        }
        if isUncategorized {
            return String.l10n("trending.language.uncategorized")
        }
        return rawValue
    }

    /// API 参数值（空字符串表示全部；uncategorized 直接发哨兵值给后端）。
    var apiValue: String { rawValue }

    // MARK: - 哨兵值（必须与后端 internal/model/trending.go 同名常量对齐）

    /// `__uncategorized__` 哨兵字符串。
    /// 后端对应：`internal/model.UncategorizedLanguageKey`。任何调整都必须前后端同步。
    static let uncategorizedKey = "__uncategorized__"

    static let all = TrendingLanguage("")
    static let uncategorized = TrendingLanguage(uncategorizedKey)
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

// MARK: - Language Aggregate DTO

/// 后端 `GET /api/v1/languages` 返回的单项（envelope.data 元素）。
///
/// 与 `TrendingLanguage` 的关系：
///   - `TrendingLanguageAggregateDTO` 是网络层 DTO，对应后端 `model.LanguageAggregate`
///   - `TrendingLanguage` 是 UI 模型，sidebar / picker 用它做 selection binding
///   - 流向：后端 envelope → DTO 解码 → `TrendingLanguageStore` 保存 → SidebarView
///     转 `TrendingLanguage` 渲染 + 透出 count
///
/// 字段命名走 envelope schema_version=1 的 snake_case 约定（CodingKeys 显式映射）。
struct TrendingLanguageAggregateDTO: Decodable, Hashable, Sendable {
    /// 后端语言 key（GitHub 规范化名 / `__uncategorized__`）。
    let key: String
    /// 后端展示名（`key` 同值 / `Uncategorized`）。
    /// 客户端**不直接**展示这个值——非空 key 显示 key 本身，
    /// `__uncategorized__` 走客户端 i18n 文案。
    let label: String
    /// 该语言下当前 trending_repos 表中可用且已 enrich 的 repo 数量。
    /// sidebar 行尾计数列展示这个值，与 Tags / Languages section 视觉一致。
    let count: Int

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case count
    }

    /// 转成 sidebar 用的 `TrendingLanguage`。
    /// 哨兵 key 自动转为 `.uncategorized`；其余 key 透传作为 rawValue。
    var asTrendingLanguage: TrendingLanguage {
        if key == TrendingLanguage.uncategorizedKey {
            return .uncategorized
        }
        return TrendingLanguage(key)
    }
}
