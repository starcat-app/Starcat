//
//  Repo.swift
//  Starcat
//
//  仓库元数据，对应 docs/详细设计/01-数据库设计.md 第 2.1 节 `repos` 表。
//
//  关键约束：
//  - id 用 Int64（GitHub repo id 原生类型），与表 schema INTEGER PRIMARY KEY 一致
//  - topics 字段存 JSON 字符串，业务层用 `topicsArray` 计算属性解析；这样保持 GRDB 行映射简单
//  - 时间字段均存 ISO8601 字符串（GitHub API 直返该格式），暂不转 Date，避免时区/格式分歧
//  - is_* 字段用 Bool（GRDB 自动桥到 SQLite INTEGER 0/1）
//

import Foundation
import GRDB

/// 仓库元数据。
///
/// 该结构 1:1 映射 `repos` 表，字段顺序与 schema 保持一致以便阅读。
///
/// Hashable 实现：用 `id` 作为唯一标识（GitHub repo id 全局唯一），
/// SwiftUI `List(selection:)` 需要 Hashable，避免对所有字段做散列。
struct Repo: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Equatable, Hashable {

    static let databaseTableName = "repos"

    // MARK: - 标识

    /// GitHub repo ID（Int64）。
    var id: Int64

    // MARK: - 基本信息

    var owner: String
    var name: String
    /// `owner/name`，GitHub 全名，已建唯一索引。
    var fullName: String

    var description: String?
    var language: String?
    var starsCount: Int
    var forksCount: Int
    var watchersCount: Int
    /// JSON 数组字符串，如 `["ai","swift"]`。
    var topics: String?

    // MARK: - License / URL

    var license: String?
    var homepage: String?
    var htmlUrl: String
    var cloneUrl: String?
    var sshUrl: String?

    // MARK: - 状态标记

    var isPrivate: Bool
    var isFork: Bool
    var isArchived: Bool
    /// 本地视角：用户当前是否仍 star 着该 repo。取消 star 后设为 false 而非删除（保留笔记/标签）。
    var isStarred: Bool

    // MARK: - 时间字段（ISO8601）

    var pushedAt: String?
    var createdAt: String?
    var updatedAt: String?
    var starredAt: String?

    /// 本地缓存时间，与 GitHub 字段无关。
    var cachedAt: String?

    // MARK: - R-01 v1.2 StarcatRepoCardDTO 新字段（GRDB v8 schema，2026-06-10）
    //
    // 4 字段全部 Optional：老用户从 v7 升级时 SQLite 把这些列填 NULL；新拉的 repo
    // 通过 toEphemeralRepo() / GitHub /repos API 写入实际值。

    /// 仓库所有者头像 URL（GitHub /repos.owner.avatar_url）。
    /// UI hero 区直接渲染，免去额外 GitHub user API 调用。
    ///
    /// **默认 nil 的目的**：Swift memberwise init 会把"有默认值"的字段省略为可选参数，
    /// 这样 v8 之前已存在的 24+ 处 `Repo(...)` 调用方不必逐个补 `ownerAvatar: nil`。
    /// 老的 GitHub 同步路径（`StarsAPI` → `GitHubRepoDTO` → `Repo`）暂不消化此字段；
    /// 仅 Trending / Weekly / Sharing 三场景由 `StarcatRepoCardDTO.toEphemeralRepo()`
    /// 直填实值。后续若要让 Stars 同步也填，需扩 `GitHubRepoDTO`。
    var ownerAvatar: String? = nil

    /// 订阅者数（GitHub `subscribers_count`，与 watchers 不同）。发现型场景排序参考。
    /// 默认 nil 同上：兼容老 callsite。
    var subscribersCount: Int? = nil

    /// 默认分支（如 `main` / `master`）。README 与文件浏览路径展开依赖此字段。
    /// 默认 nil 同上：兼容老 callsite。
    var defaultBranch: String? = nil

    /// 未关闭 issue 数（GitHub `open_issues_count`）。UI hero 区与 stars/forks 并列展示。
    /// 默认 nil 同上：兼容老 callsite。
    var openIssuesCount: Int? = nil

    // MARK: - Codable Keys（snake_case 与表列对齐）

    enum CodingKeys: String, CodingKey {
        case id
        case owner
        case name
        case fullName = "full_name"
        case description
        case language
        case starsCount = "stars_count"
        case forksCount = "forks_count"
        case watchersCount = "watchers_count"
        case topics
        case license
        case homepage
        case htmlUrl = "html_url"
        case cloneUrl = "clone_url"
        case sshUrl = "ssh_url"
        case isPrivate = "is_private"
        case isFork = "is_fork"
        case isArchived = "is_archived"
        case isStarred = "is_starred"
        case pushedAt = "pushed_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case starredAt = "starred_at"
        case cachedAt = "cached_at"
        // R-01 v1.2 GRDB v8 新增（2026-06-10）
        case ownerAvatar = "owner_avatar"
        case subscribersCount = "subscribers_count"
        case defaultBranch = "default_branch"
        case openIssuesCount = "open_issues_count"
    }

    // MARK: - 派生属性

    /// 解析 topics JSON 字符串为数组；解析失败返回空数组。
    /// 不持久化此属性。
    var topicsArray: [String] {
        guard let topics, let data = topics.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    // MARK: - Hashable / Equatable

    /// 只基于 id 散列（即同一 GitHub repo 即视为相等的 hash key）。
    /// List(selection:) 用此保证选中行稳定，不受 cachedAt 等字段变化影响。
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// **必须与 hash 一致**：Hashable 契约要求 `a == b` ⇔ `hash(a) == hash(b)`。
    ///
    /// 早期版本依赖 synthesized 全字段 ==，与上面的 `hash(into:)` 不一致,
    /// 导致 SwiftUI `List(selection:)` 在 selection binding 写入时
    /// 找不到匹配 tag（hash 相等但 == 不等），表现为"列表点击没反应、detail 不刷新"。
    ///
    /// 仓库 id 在 GitHub 全局唯一，用 id 比较即可覆盖所有合理场景。
    static func == (lhs: Repo, rhs: Repo) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - R-01 Minimal Fallback 工厂

extension Repo {

    /// R-01：构造一个**最小可用**的 in-memory Repo，给 `MinimalRepoSource` 在
    /// 整条 source chain 全部 throws 或 nil 时兜底使用，避免详情页白屏。
    ///
    /// 如果有 hint DTO（trending / weekly 列表已经拉过的字段），优先复用 hint
    /// 字段；否则只有 owner / name 能用。`id` 来自 hint 的 `ghRepoId`，否则
    /// 用 0（非合法 GitHub id）；调用方应通过 `id == 0` 判断「无法 star/unstar」
    /// 而禁用对应交互。
    ///
    /// **不要**把这个 Repo 落 DB —— 字段大量缺失，落库会污染本地数据。
    /// 用途仅限「详情页 hero / readme 区域不至于完全空着」。
    static func makeMinimal(owner: String, name: String, hint: StarcatRepoCardDTO? = nil) -> Repo {
        if let hint {
            return hint.toEphemeralRepo()
        }
        let fallbackHtmlUrl = GitHubURLs.repo(owner: owner, repo: name).absoluteString
        return Repo(
            id: 0,                              // ⚠️ 非合法 id；调用方需检查
            owner: owner,
            name: name,
            fullName: "\(owner)/\(name)",
            description: nil,
            language: nil,
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: fallbackHtmlUrl,
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: false,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil,
            ownerAvatar: nil,
            subscribersCount: nil,
            defaultBranch: nil,
            openIssuesCount: nil
        )
    }
}
