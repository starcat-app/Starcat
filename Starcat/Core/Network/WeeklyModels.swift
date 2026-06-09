//
//  WeeklyModels.swift
//  Starcat
//
//  阮一峰周刊（ruanyf/weekly）后端 API 的响应 DTO 与领域模型。
//
//  数据源：starcat-weekly-api（独立 Go 服务，见 https://github.com/dong4j/starcat-weekly-api）
//  上游 API 返回纯 JSON（与 starcat-sharing-api 同款风格，无 code 包装）。
//
//  设计约束：
//  - DTO 字段名与后端 JSON 保持一致（snake_case），通过 CodingKeys 显式映射，
//    与 TrendingModels 保持同款做法：不开 `.convertFromSnakeCase`，避免与
//    显式 CodingKeys 冲突。
//  - 领域模型由 DTO 构造，UI 层只关心领域模型。
//

import Foundation

// MARK: - API Response（已删，R-01 v1.2 走 envelope）
//
// 旧的非 envelope `WeeklyProjectListDTO` / `WeeklyProjectDTO` 在 R-01 v1.2 改造后已废。
// 新数据流：API 响应 envelope → `StarcatEnvelope<[StarcatRepoCardDTO]>` → 由 `WeeklyProject.init(card:)`
// 转 UI 模型；分页信息从 envelope.meta 取（page / pageSize / total）。

// MARK: - Domain Model

/// 周刊推荐项目领域模型，UI 直接消费。
///
/// 与 DTO 拆开是为了：
/// 1. 把字符串 URL 转成 `URL`，避免每个调用点都 `URL(string:)`；
/// 2. 提供 `fullName` 这种派生字段，让 UI 写法更简洁；
/// 3. 后续若加入 AI 摘要、订阅状态等 UI 专属字段，不污染网络层 DTO。
struct WeeklyProject: Identifiable, Equatable {
    /// 用 owner/repo 作 id：同一仓库不论在多少期出现，UI 都按"项目"维度去重展示。
    var id: String { fullName }

    /// GitHub repo 数字 id（R-01 v1.2，2026-06-10）。
    ///
    /// 来自 `StarcatRepoCardDTO.ghRepoId`（后端 enricher 必填，`N5` 决策保证 N6 后
    /// trending / weekly 列表 100% 携带 ghRepoId）。0 留作历史 / 故障 fallback 哨兵——
    /// 走到 0 时跨场景 `StarredRegistry.contains(ghRepoId: 0)` 永远命中不到，UI 上等同
    /// 「此 row 不显示 ✓」，可接受。
    let ghRepoId: Int64

    let owner: String
    let name: String
    let url: URL
    let description: String?
    let stars: Int
    let language: String?
    /// 项目第一次被周刊收录的期号；用来在 row 上展示"第 NNN 期推荐"。
    let firstIssue: Int
    /// 第一次收录的原始 md URL，方便用户跳到周刊原文上下文。
    let issueURL: URL?

    // MARK: R-01 v1.2 v8 字段（来自 StarcatRepoCardDTO）

    /// 仓库所有者头像 URL（GitHub `owner.avatar_url`）。RepoCardViewData / Hero 直接
    /// 渲染；缺失时 UI 走 `RepoAvatarURL.from(owner:)` fallback。
    let ownerAvatar: URL?

    /// Forks 数；后端 enricher 未补全时为 nil（UI 显示 0 / 隐藏）。
    let forks: Int?

    /// Watchers / subscribers / open_issues / default_branch — Weekly 详情 hero 区
    /// 复用 Manage / Trending 同款 RepoMetadataHeaderView，必须填齐这些字段。缺失
    /// 字段以 nil 透传，由 hero 渲染层判断「显示 / 隐藏」。
    let watchers: Int?
    let subscribers: Int?
    let openIssues: Int?
    let defaultBranch: String?

    let topics: [String]?
    let homepage: URL?
    let licenseSpdx: String?

    let isArchived: Bool?
    let isFork: Bool?
    let isPrivate: Bool?

    /// 时间戳（ISO8601 字符串），用于 hero 区的 "更新于 X 日" / "创建于 Y 日" 展示。
    let pushedAt: String?
    let updatedAt: String?
    let createdAt: String?

    var fullName: String { "\(owner)/\(name)" }

    /// R-01 v1.2 初始化：从 envelope 化的 `StarcatRepoCardDTO` + `WeeklyExtension` 构造。
    ///
    /// 字段映射：
    ///   - `card.owner` / `card.repo` → `owner` / `name`
    ///   - `card.htmlUrl` 优先；缺失时 fallback 用 `GitHubURLs.repo(owner:repo:)`
    ///   - `card.description` / `card.language` → `description` / `language`
    ///   - `card.stars` → `stars`
    ///   - `card.weekly?.firstIssue` → `firstIssue`（缺扩展段时退化为 0）
    ///   - `card.weekly?.issueUrl` → `issueURL`（缺扩展段时 nil）
    ///   - **R-01 v1.2 v8**：`ghRepoId` / `ownerAvatar` / `forks` / `watchers` /
    ///     `subscribers` / `openIssues` / `defaultBranch` / `topics` / `homepage` /
    ///     `licenseSpdx` / `isArchived` / `isFork` / `isPrivate` / `pushedAt` /
    ///     `updatedAt` / `createdAt` 全部从 DTO 直透传（DTO 也已透传 GitHub
    ///     `/repos/{owner}/{repo}` 全部主字段）。
    init(card: StarcatRepoCardDTO) {
        self.ghRepoId = card.ghRepoId
        self.owner = card.owner
        self.name = card.repo
        self.url = card.htmlUrl ?? GitHubURLs.repo(owner: card.owner, repo: card.repo)
        self.description = card.description
        self.stars = card.stars
        self.language = card.language
        self.firstIssue = card.weekly?.firstIssue ?? 0
        self.issueURL = card.weekly?.issueUrl

        // v1.2 v8 字段透传
        self.ownerAvatar = card.ownerAvatar
        self.forks = card.forks
        self.watchers = card.watchers
        self.subscribers = card.subscribers
        self.openIssues = card.openIssues
        self.defaultBranch = card.defaultBranch
        self.topics = card.topics
        self.homepage = card.homepage
        self.licenseSpdx = card.licenseSpdx
        self.isArchived = card.isArchived
        self.isFork = card.isFork
        self.isPrivate = card.isPrivate
        self.pushedAt = card.pushedAt
        self.updatedAt = card.updatedAt
        self.createdAt = card.createdAt
    }
}

// MARK: - Query parameters

/// 排序枚举，与后端 `sort` 参数一一对应。
///
/// 故意只暴露两个用户视角清晰的选项：
/// - "最新收录"：以期号倒序，用户能持续看到最近一期开始的项目；
/// - "Stars 最多"：把口碑积累的项目顶到前面，便于发现稳定推荐。
enum WeeklySort: String, CaseIterable, Identifiable {
    case firstIssueDesc = "first_issue_desc"
    case starsDesc = "stars_desc"

    var id: String { rawValue }
    var apiValue: String { rawValue }
}

/// 期号筛选；`all` 不传 issue 参数，对应"全部期号"。
///
/// 用结构体而非 enum，是为了让"任意期号"成为可参数化值，避免 enum 退化成
/// `case n(Int)` 后还得在 UI 里特殊处理"selected case"。
struct WeeklyIssueFilter: Hashable, Identifiable {
    /// nil = 全部期号；非 nil = 指定期号。
    let issueNumber: Int?

    var id: String {
        if let n = issueNumber { return "issue:\(n)" }
        return "issue:all"
    }

    var apiValue: String? {
        guard let n = issueNumber else { return nil }
        return String(n)
    }

    static let all = WeeklyIssueFilter(issueNumber: nil)
}
