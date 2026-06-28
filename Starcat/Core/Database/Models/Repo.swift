//
//  Repo.swift
//  Starcat
//
//  仓库元数据，对应 docs/3-设计/详细设计/01-数据库设计.md 第 2.1 节 `repos` 表。
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

    // MARK: - R-01 v1.2 StarcatRepoCardDTO 扩展 4 字段（2026-06-10）
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
        // R-01 v1.2 扩展 4 字段（2026-06-10）
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
    //
    // ─────────────────────────────────────────────────────────────────────
    // v3 修订（2026-06-11, dong4j hero star 不刷新 bug 真机复现后回归）
    // ─────────────────────────────────────────────────────────────────────
    //
    // 演化路径（重要历史避坑）：
    //
    // - **v1 早期**：依赖 compiler synthesized 全字段 ==，与下面只 hash id 的
    //   `hash(into:)` 配对。Hashable 合约要求 `a == b ⇒ hash(a) == hash(b)`
    //   （**单向蕴含**），全字段 == 配 hash 只 id **满足合约**（== 真 → 所有
    //   字段相等 → id 相等 → hash 相等 ✓）。
    //
    //   但当时项目把 `Repo` 作为 `List(selection:)` 的 selection 类型，selection
    //   binding 写入时 SwiftUI 内部用 hash 做 bucket + == 做匹配；同 id 不同
    //   cachedAt 等字段更新后 selection 与 viewItem hash 相同但 == 不等，
    //   表现为"列表点击没反应、detail 不刷新"。
    //
    // - **v2 妥协**：把 `==` 改成只比 id（与 hash 一致），修了 List(selection:)
    //   bug。代价：**SwiftUI view diffing 也用 Equatable 比较 view prop**——
    //   当父 view 重新计算后构造新 child view（如 `RepoDetailScaffold(repo: ...)`）,
    //   SwiftUI 用 `Repo.==` 判断 `repo` prop 是否变化决定是否调用 child body；
    //   只比 id 的 == 让"id 相同但其他字段变了"的更新被 diff 跳过，子 view 不重渲染。
    //
    //   v2 引入的副作用：dong4j 在 trending 详情页第一次 star 一个 repo 后,
    //   `displayRepo` 切换为 isStarred=true 的本地真值（id 不变），但 SwiftUI 用
    //   `Repo.==` 判定 prop 没变,跳过 hero `StarStatChipButton` 重渲染→
    //   **hero star icon 永远是空心,只有切走 detail 再切回（view 销毁重建,
    //   不走 diff 路径）才显示实心**。
    //
    //   同源 bug 在 stars count / forks / starredAt / status / topics 等所有
    //   "id 不变但其他字段变化"路径都潜伏存在，只是这些字段变化频率低 + 用户
    //   不主动盯着复现，所以直到高频 star 操作才被暴露。
    //
    // - **v3 回归全字段 ==**（本提交）：
    //
    //   1. **删除自定义 `==`**：让 Swift compiler synthesize 全字段比较。
    //      `Repo` 所有字段都是 Equatable value type（Int64 / String / String?
    //      / Int / Bool / String?），synthesis 安全。
    //
    //   2. **保留 `hash(into:)` 只 hash id**：
    //      - 满足 Hashable 合约（== 真 → 全字段相等 → id 相等 → hash 相等 ✓）
    //      - hash 计算便宜（不遍历 25+ 字段）
    //      - 反向：hash 相等不要求 == 真（合约不强制），允许 hash 冲突
    //      - 业务上 Starcat **没有** Set<Repo> / Dictionary<Repo, V> 用法
    //        （selection 全部走 selectedRepoID: Int64? / multiSelectedRepoIDs:
    //        Set<Int64>，详见 `HomeViewModel.swift` line 123-130 注释），
    //        所以 hash 冲突频率不影响真实性能。
    //
    //   3. **List(selection:) 不再用 Repo**：原 v2 修法目标已通过把所有
    //      selection 改成 Int64-based 彻底解决（HomeViewModel 单选 / 多选
    //      字段类型),`Repo.==` 不再承担 selection 匹配职责，可以放心做
    //      正确的全字段比较，让 SwiftUI view diffing 正常工作。
    //
    // 不变量：
    //   - Hashable 合约：== ⇒ hash 相等（保持）
    //   - SwiftUI diffing：repo 任一字段变化都触发 view body 重新计算（恢复）
    //   - selection 路径：HomeViewModel.selectedRepoID / multiSelectedRepoIDs
    //     必须保持 Int64-based（不要回退到 Repo-based,否则 v1 bug 复活）

    /// 只基于 id 散列（即同一 GitHub repo 即视为相等的 hash key 集合）。
    /// 默认 synthesized hash 会遍历 25+ 字段，对 1800+ repo 全部 hash 一遍代价不小；
    /// id 在 GitHub 全局唯一，足够作 hash key。
    ///
    /// 配合下面 compiler-synthesized `==`（全字段比较），符合 Hashable 合约
    /// `a == b ⇒ hash(a) == hash(b)`：全字段 == 真 → id 必相等 → hash 相等 ✓。
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    // `static func == (lhs: Repo, rhs: Repo) -> Bool` 由 Swift compiler 自动
    // synthesize 全字段比较（不要手写 id-only ==，详见上面 v3 修订注释）。
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
