//
//  StarcatRepoCardDTO.swift
//  Starcat
//
//  Starcat Repo Card Schema v1 —— 三场景共用架构（R-01）的统一后端 DTO。
//
//  数据源：trending / weekly / 未来其他「发现型」后端服务。
//  对应文档：`docs/详细设计/18-三场景共用架构.md` v1.2 §6.1。
//
//  ────────────────────────────────────────────────────────────────────────────
//  ⚠️ Schema 硬边界规则（违反需先改 §6.1.4 文档再改这里！v1.2 dong4j review R6）
//  ────────────────────────────────────────────────────────────────────────────
//
//  核心字段允许范围：
//      仅与 GitHub Repo metadata 原生语义对齐的字段（GitHub `/repos/{o}/{r}`
//      响应里有的字段子集 + 派生字段如 `license_spdx`）。
//
//  扩展段允许范围：
//      `trending.*` / `weekly.*` 只能放与「该场景的发现型语义」绑定的字段。
//      例如 trending.change（本期榜单 stars 增量）/ weekly.first_issue（首次收录期号）。
//
//  绝对禁止（红线）：
//   ❌ 把非 Repo metadata 字段（如 editorComment / reason / relatedArticles /
//      recommendedReadingTime）放到核心字段
//   ❌ 试图把扩展段字段提升到顶层（如 weekly.editorComment → 顶层 editorComment）
//   ❌ 在扩展段塞超出「该场景发现型语义」的字段（如 weekly.unrelatedDiscussion）
//
//  替代方案：
//      当某场景演化出 Article 模型时（比如 weekly 长出编辑点评 / 相关文章），
//      不要扩本 DTO，而是另起 endpoint：
//        GET /api/v1/weekly/repos     → StarcatRepoCardDTO（保持卡片 = repo metadata 语义）
//        GET /api/v1/weekly/articles  → StarcatWeeklyArticleDTO（独立 schema）
//  ────────────────────────────────────────────────────────────────────────────
//
//  设计意图：
//  - 后端 trending / weekly / 未来发现型服务遵循同一份 schema，前端零适配
//  - URL 版本化（`/api/v1/*`）+ 顶层 `schema_version` 字段双保险，防止后端
//    schema 演进时拖死前端解码
//  - DTO 解码本身不校验 schema_version（只解码字段）；envelope 包装与 schema_version
//    校验由 `StarcatEnvelope.swift` 的 `StarcatEnvelopeDecoder.decode` 统一处理
//
//  Sendable：DTO 全部值类型 + 不可变 let，天然满足 Sendable 要求。
//

import Foundation

// MARK: - Envelope（统一顶层包装见 StarcatEnvelope.swift）
//
// `/api/v1/repos` / `/api/v1/projects` 端点的顶层响应统一走 `StarcatEnvelope<[StarcatRepoCardDTO]>`，
// 单 repo 聚合 endpoint 走 `StarcatEnvelope<StarcatRepoCardDTO>`，定义在 StarcatEnvelope.swift 里。
// 旧的非泛型 `StarcatRepoCardResponse` 已删除（R-01 数据层接通时统一用 `StarcatEnvelopeDecoder.decode`）。

// MARK: - Repo Card DTO（卡片主体）

/// 三场景共用的「Repo 卡片」DTO。
///
/// 字段层级：
/// - 核心字段：与 GitHub Repo metadata 原生语义对齐（snake_case 与 GitHub 风格一致）
/// - 扩展段（`trending` / `weekly`）：场景独有的发现型语义字段（可选，缺失即 nil）
///
/// 字段必填性：
/// - `gh_repo_id`：必填（N5 决策：enricher 未补全的 repo 后端不返回）
/// - 计数字段（stars/forks/watchers/subscribers/open_issues）：必填，缺省值视后端而定
/// - 时间字段（pushed_at/updated_at/created_at）：可选（后端可能未补全 enrich）
/// - URL 字段（owner_avatar/homepage/html_url）：可选
///
/// 与 GitHubRepoDTO 的关系：
/// - GitHubRepoDTO 直接对应 GitHub 官方 `/repos/{o}/{r}` 响应（`stargazers_count` 等命名）
/// - StarcatRepoCardDTO 是 starcat 后端**已聚合 + 重命名**后的中间表示（`stars` / `forks` 等更短）
/// - 二者不互通；`toEphemeralRepo()` 提供单向转 `Repo`（in-memory 用，不落 DB）
struct StarcatRepoCardDTO: Decodable, Sendable, Equatable {

    // MARK: - 核心字段（只放 GitHub Repo metadata 语义字段，硬边界！）

    /// GitHub repo 数字 id（必填）。Int64 与 `Repo.id` 一致。
    /// 这是「跨 rename 稳定的主键」，远比 fullName 可靠（用户改名后 id 不变）。
    let ghRepoId: Int64

    /// `owner/repo` 格式完整名。仅用于显示 / 向后兼容。
    let fullName: String

    /// 仓库所有者 login。
    let owner: String

    /// 仓库名（不含 owner 前缀）。后端字段名 `repo`，避免与外层结构同名。
    let repo: String

    /// 所有者头像 URL（用户 / 组织）。
    let ownerAvatar: URL?

    /// 仓库描述（GitHub 原文，未过滤 emoji shortcode）。
    let description: String?

    /// 主要编程语言。
    let language: String?

    /// Stars 总数。
    let stars: Int

    /// Forks 总数。
    let forks: Int

    /// Watchers 总数（GitHub API 注意：watchers_count 实际等于 stars，watchers 是 subscribers）。
    /// 此处尊重后端 enricher 的语义（按后端 Go 代码而定）。
    let watchers: Int

    /// 订阅者数（GitHub `subscribers_count` 字段）。
    let subscribers: Int

    /// Topics 数组。空数组而非 nil（设计 §6.1.3 默认 [])。
    let topics: [String]

    /// 项目主页 URL。
    let homepage: URL?

    /// SPDX 许可证标识符（如 `MIT` / `Apache-2.0`）。
    let licenseSpdx: String?

    /// 仓库是否归档。
    let isArchived: Bool

    /// 是否 fork 自其他仓库。
    let isFork: Bool

    /// 是否私有仓库（trending/weekly 场景下应总是 false）。
    let isPrivate: Bool

    /// 默认分支（如 `main` / `master`）。
    let defaultBranch: String?

    /// 未关闭 issue 数。
    let openIssues: Int

    /// 最后一次 push 的 ISO8601 时间字符串。
    let pushedAt: String?

    /// 最后一次更新的 ISO8601 时间字符串。
    let updatedAt: String?

    /// 仓库创建的 ISO8601 时间字符串。
    let createdAt: String?

    /// GitHub 网页地址（`https://github.com/owner/repo`）。
    let htmlUrl: URL?

    // MARK: - 扩展段（每个场景独立可选；硬边界见文件头）

    /// Trending 场景独有字段。trending API 返回，weekly API 必为 nil。
    let trending: TrendingExtension?

    /// Weekly 场景独有字段。weekly API 返回，trending API 必为 nil。
    let weekly: WeeklyExtension?

    // MARK: - CodingKeys（snake_case → camelCase 显式映射）

    enum CodingKeys: String, CodingKey {
        case ghRepoId = "gh_repo_id"
        case fullName = "full_name"
        case owner
        case repo
        case ownerAvatar = "owner_avatar"
        case description
        case language
        case stars
        case forks
        case watchers
        case subscribers
        case topics
        case homepage
        case licenseSpdx = "license_spdx"
        case isArchived = "is_archived"
        case isFork = "is_fork"
        case isPrivate = "is_private"
        case defaultBranch = "default_branch"
        case openIssues = "open_issues"
        case pushedAt = "pushed_at"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case htmlUrl = "html_url"
        case trending
        case weekly
    }

    // MARK: - 容错解码
    //
    // 后端 enricher 不一定能补全所有字段（特别是新爬到的项目）。
    // 计数字段缺失退化为 0，topics 缺失退化为 []，可选字段直接 nil。
    // gh_repo_id 是必填（N5 决策：enricher 未补全的 repo 后端不返回）。

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.ghRepoId = try c.decode(Int64.self, forKey: .ghRepoId)
        self.fullName = try c.decode(String.self, forKey: .fullName)
        self.owner = try c.decode(String.self, forKey: .owner)
        self.repo = try c.decode(String.self, forKey: .repo)
        self.ownerAvatar = try c.decodeIfPresent(URL.self, forKey: .ownerAvatar)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.language = try c.decodeIfPresent(String.self, forKey: .language)
        self.stars = try c.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        self.forks = try c.decodeIfPresent(Int.self, forKey: .forks) ?? 0
        self.watchers = try c.decodeIfPresent(Int.self, forKey: .watchers) ?? 0
        self.subscribers = try c.decodeIfPresent(Int.self, forKey: .subscribers) ?? 0
        self.topics = try c.decodeIfPresent([String].self, forKey: .topics) ?? []
        self.homepage = try c.decodeIfPresent(URL.self, forKey: .homepage)
        self.licenseSpdx = try c.decodeIfPresent(String.self, forKey: .licenseSpdx)
        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.isFork = try c.decodeIfPresent(Bool.self, forKey: .isFork) ?? false
        self.isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        self.defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        self.openIssues = try c.decodeIfPresent(Int.self, forKey: .openIssues) ?? 0
        self.pushedAt = try c.decodeIfPresent(String.self, forKey: .pushedAt)
        self.updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        self.createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        self.htmlUrl = try c.decodeIfPresent(URL.self, forKey: .htmlUrl)
        self.trending = try c.decodeIfPresent(TrendingExtension.self, forKey: .trending)
        self.weekly = try c.decodeIfPresent(WeeklyExtension.self, forKey: .weekly)
    }

    /// 测试 / fixture 使用的 memberwise init。生产代码请走 JSONDecoder 解码。
    init(
        ghRepoId: Int64,
        fullName: String,
        owner: String,
        repo: String,
        ownerAvatar: URL? = nil,
        description: String? = nil,
        language: String? = nil,
        stars: Int = 0,
        forks: Int = 0,
        watchers: Int = 0,
        subscribers: Int = 0,
        topics: [String] = [],
        homepage: URL? = nil,
        licenseSpdx: String? = nil,
        isArchived: Bool = false,
        isFork: Bool = false,
        isPrivate: Bool = false,
        defaultBranch: String? = nil,
        openIssues: Int = 0,
        pushedAt: String? = nil,
        updatedAt: String? = nil,
        createdAt: String? = nil,
        htmlUrl: URL? = nil,
        trending: TrendingExtension? = nil,
        weekly: WeeklyExtension? = nil
    ) {
        self.ghRepoId = ghRepoId
        self.fullName = fullName
        self.owner = owner
        self.repo = repo
        self.ownerAvatar = ownerAvatar
        self.description = description
        self.language = language
        self.stars = stars
        self.forks = forks
        self.watchers = watchers
        self.subscribers = subscribers
        self.topics = topics
        self.homepage = homepage
        self.licenseSpdx = licenseSpdx
        self.isArchived = isArchived
        self.isFork = isFork
        self.isPrivate = isPrivate
        self.defaultBranch = defaultBranch
        self.openIssues = openIssues
        self.pushedAt = pushedAt
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.htmlUrl = htmlUrl
        self.trending = trending
        self.weekly = weekly
    }

    // MARK: - 扩展段定义

    /// Trending 场景独有字段。
    ///
    /// **硬边界**：只放与「本期榜单语义」绑定的字段。新需求请评估是否真的属于
    /// trending 语义，还是应该走 GitHub /repos endpoint 拉。
    struct TrendingExtension: Decodable, Sendable, Equatable {
        /// 本期榜单 stars 增量（如 daily +321）。
        let change: Int
        /// 本期榜单贡献者列表（GitHub Trending 页面显示的头像列）。
        let contributors: [TrendingContributor]

        init(change: Int, contributors: [TrendingContributor] = []) {
            self.change = change
            self.contributors = contributors
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.change = try c.decodeIfPresent(Int.self, forKey: .change) ?? 0
            self.contributors = try c.decodeIfPresent([TrendingContributor].self, forKey: .contributors) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case change
            case contributors
        }
    }

    struct TrendingContributor: Decodable, Sendable, Equatable {
        let avatar: URL
        let login: String
    }

    /// Weekly 场景独有字段。
    ///
    /// **硬边界**：只放与「周刊收录元数据」绑定的字段。
    /// 编辑点评 / 推荐理由 / 相关文章等 Article 字段一律不放这里，必要时另起 endpoint。
    struct WeeklyExtension: Decodable, Sendable, Equatable {
        /// 项目首次被周刊收录的期号。
        let firstIssue: Int
        /// 首次收录期号的原文链接（GitHub markdown 文件 URL）。
        let issueUrl: URL

        enum CodingKeys: String, CodingKey {
            case firstIssue = "first_issue"
            case issueUrl = "issue_url"
        }
    }
}

// MARK: - DTO → Repo 转换

extension StarcatRepoCardDTO {

    /// 转成临时（in-memory）`Repo` 对象，仅用于详情页 fallback / hint 链路。
    ///
    /// 关键约束：
    /// - **不要落 DB**：`isStarred` 永远 false（DTO 不知道当前用户的 star 状态），
    ///   持久化会污染本地用户私有数据。
    /// - `cachedAt` / `starredAt` / `cloneUrl` / `sshUrl` 都为 nil（DTO 没有这些字段）。
    /// - `topics` 序列化为 JSON 字符串与 `Repo.topics` 对齐。
    /// - `htmlUrl` 缺失时 fallback 到 `GitHubURLs.repo(owner:repo:)`，避免空字符串。
    ///
    /// 调用方负责自行通过 `StarredRegistry.contains(ghRepoId:)` 判断真实 star 状态。
    func toEphemeralRepo() -> Repo {
        // topics 序列化为 JSON 字符串。空数组直接写 "[]"，与 Repo.topics 行为一致。
        let topicsJSON: String? = {
            guard !topics.isEmpty else { return nil }
            // [String] 编码为 JSON 几乎不会失败（除非内存爆炸）；fallback 给 nil 让上层不挂。
            guard let data = try? JSONEncoder().encode(topics),
                  let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return str
        }()

        let resolvedHtmlUrl = htmlUrl?.absoluteString
            ?? GitHubURLs.repo(owner: owner, repo: repo).absoluteString

        return Repo(
            id: ghRepoId,
            owner: owner,
            name: repo,
            fullName: fullName,
            description: description,
            language: language,
            starsCount: stars,
            forksCount: forks,
            watchersCount: watchers,
            topics: topicsJSON,
            license: licenseSpdx,
            homepage: homepage?.absoluteString,
            htmlUrl: resolvedHtmlUrl,
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: isPrivate,
            isFork: isFork,
            isArchived: isArchived,
            isStarred: false,    // ← 关键：ephemeral Repo 不持有 star 状态
            pushedAt: pushedAt,
            createdAt: createdAt,
            updatedAt: updatedAt,
            starredAt: nil,
            cachedAt: nil
        )
    }
}
