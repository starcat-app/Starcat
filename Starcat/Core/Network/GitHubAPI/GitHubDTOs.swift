//
//  GitHubDTOs.swift
//  Starcat
//
//  GitHub REST API 响应解码 DTO。
//
//  设计约束：
//  - DTO 与数据库模型分离：DTO 字段名跟 GitHub 走（snake_case 自动转 camelCase），
//    数据库模型字段名跟我们 schema 走；二者通过显式 mapper 转换，互不污染
//  - 时间字段保持 String（ISO8601 原文），不在 DTO 里 Date 化，避免时区/格式纠结
//  - 不解码所有 GitHub 字段，只解码我们当前用到的——降低破坏性变更风险
//

import Foundation

// MARK: - User

/// `GET /user` 响应（也用于 starred_repos 里的 owner 嵌套字段）。
///
/// 注意字段可选性：
/// - `/user` 端点返回全部字段
/// - `/user/starred` 嵌套的 `owner` 只返回 id/login/avatar_url
/// 所以 followers/following/publicRepos 必须可选，否则嵌套 owner 解码失败。
///
/// HOM-PROFILE (2026-06-05)：新增个人主页字段（bio / company / location / email /
/// blog / twitterUsername / htmlUrl）。全部可选，配合 `/user/starred` 嵌套 owner 解码兼容。
/// 字段直接对应 GitHub `/user` 端点的 snake_case 同名字段（decoder 已开启
/// `convertFromSnakeCase`），仅 `htmlUrl` 是为了对齐其它 DTO（如 Repo.htmlUrl）的命名约定。
// 2026-06-06 UserProfileService（A 方案）：从 `Decodable` 升级为 `Codable`，
// 让 service 可以把整个 DTO 直接落 UserDefaults（与 ContributionService 同款落盘范式）。
// 13 个字段全部 `let` + 标量类型，Encodable 自动合成，无需手写 CodingKeys。
struct GitHubUserDTO: Codable, Equatable {
    let id: Int64
    let login: String
    let name: String?
    let avatarUrl: String?

    // MARK: - 用户统计（仅 /user 端点返回）

    /// 公开仓库数。
    let publicRepos: Int?
    /// 粉丝数。
    let followers: Int?
    /// 关注数。
    let following: Int?

    // MARK: - 个人主页字段（仅 /user 端点返回；HOM-PROFILE 2026-06-05）

    /// 个人简介，纯文本，可含 @mention（GitHub 不渲染，原样返回）。
    let bio: String?
    /// 公司，如 "@apple" 或 "Apple Inc."（GitHub 不强制格式）。
    let company: String?
    /// 地理位置（用户自填）。
    let location: String?
    /// 公开邮箱；用户在 Settings → Profile 勾选"Display email" 才会返回。
    let email: String?
    /// 个人网站 URL；GitHub 不保证带 scheme（可能是 `dong4j.github.io`）。
    let blog: String?
    /// Twitter / X 用户名（不含 @），用户在 Profile Settings 配置。
    let twitterUsername: String?
    /// GitHub 主页完整 URL（`https://github.com/{login}`）。
    let htmlUrl: String?
}

// MARK: - License

struct GitHubLicenseDTO: Decodable, Equatable {
    let key: String?
    let name: String?
    let spdxId: String?
}

// MARK: - Repo

/// 仓库元数据 DTO。
///
/// 注意字段映射：
/// - `stargazersCount` → 数据库 `stars_count`
/// - `fork` → 数据库 `is_fork`
/// - `archived` → 数据库 `is_archived`
/// - `private` 是 Swift 关键字，需要用 `isPrivate` 并显式 CodingKey
///
/// 2026-06-14 SEARCH-RICH（搜索弹窗信息密度增强）：新增 5 个零成本字段。
/// 全部 Optional —— 兼容老的 `/user/starred` 嵌套 repo（部分字段不返回）以及
/// 网络层不同端点的字段差异：
/// - `openIssuesCount` / `defaultBranch`：`/search/repositories` 与
///   `/user/starred` 嵌套 repo 都返回；过去未解码导致 `Repo` 表对应列长期 NULL
/// - `disabled` / `isTemplate`：仅 search / `/repos/{owner}/{repo}` 返回；
///   仅在搜索结果详情弹窗里渲染状态徽章，不入库（瞬时态）
/// - `score`：仅 search 端点返回（best-match 排序时给出 0.0~1.0 相关度）；
///   其它端点不返回 → 必须 Optional
struct GitHubRepoDTO: Decodable, Equatable {
    let id: Int64
    let name: String
    let fullName: String
    let owner: GitHubUserDTO
    let description: String?
    let language: String?
    let stargazersCount: Int
    let forksCount: Int
    let watchersCount: Int
    let topics: [String]?
    let license: GitHubLicenseDTO?
    let homepage: String?
    let htmlUrl: String
    let cloneUrl: String?
    let sshUrl: String?
    let isPrivate: Bool
    let fork: Bool
    let archived: Bool
    let pushedAt: String?
    let createdAt: String?
    let updatedAt: String?

    // MARK: - SEARCH-RICH（2026-06-14）
    //
    // 全部 Optional 但**不带默认值**：Swift `let x: T = default` 会让编译器
    // synthesized memberwise init 完全跳过该参数（"已固定"语义），后续没法
    // 在 init 里覆盖；为了保留 memberwise init 既能默认 nil 又能显式传值的
    // 灵活性，5 个字段保持 `let x: T?`，所有 callsite 显式传 nil（10 处 fixture
    // 已逐一更新）。

    /// 未关闭 issue 数（GitHub `open_issues_count`，**含 PR**）。
    let openIssuesCount: Int?
    /// 默认分支（如 `main` / `master`）。
    let defaultBranch: String?
    /// 仓库是否被 GitHub 停用（违规 / DMCA / 长期无人维护被官方停用）。
    let disabled: Bool?
    /// 是否模板仓库（GitHub Repository Template 功能）。
    let isTemplate: Bool?
    /// 搜索相关度（仅 `/search/repositories` 返回，best-match 排序时有意义）。
    let score: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case fullName
        case owner
        case description
        case language
        case stargazersCount
        case forksCount
        case watchersCount
        case topics
        case license
        case homepage
        case htmlUrl
        case cloneUrl
        case sshUrl
        // `private` 在 JSON 里就是 "private"，避免 Swift 关键字
        case isPrivate = "private"
        case fork
        case archived
        case pushedAt
        case updatedAt
        case createdAt
        // SEARCH-RICH 2026-06-14
        // 以下 5 个 case 用 camelCase raw value，配合 decoder 的
        // `.convertFromSnakeCase` strategy：JSON `open_issues_count` 先被
        // strategy 转成 `openIssuesCount`，再与本 raw value 匹配 → 解码成功。
        case openIssuesCount
        case defaultBranch
        case disabled
        case isTemplate
        case score
    }
}

// MARK: - Starred wrapper

/// 当请求头带 `Accept: application/vnd.github.star+json` 时，GitHub 返回
/// `{ "starred_at": "...", "repo": { ...full repo... } }` 而不是裸 Repo。
struct StarredRepoDTO: Decodable, Equatable {
    let starredAt: String
    let repo: GitHubRepoDTO
}

struct GitHubSubscriptionDTO: Codable, Equatable {
    let subscribed: Bool
    let ignored: Bool
    let reason: String?
    let createdAt: String?
    let url: String?
    let repositoryUrl: String?
}

struct GitHubSubscriptionRequestDTO: Encodable {
    let subscribed: Bool
    let ignored: Bool
}

// MARK: - Release（HOM-47）

/// `GET /repos/{owner}/{repo}/releases` 单条响应。
///
/// 字段映射：
/// - GitHub `id`：Release 全局唯一 id（与 tag_name 不同，tag 可重命名 / 删除重建）
/// - GitHub `assets`：资产数组（dmg / pkg / zip 等）
/// - 不解码 `author` / `tarball_url` / `zipball_url`：MVP 不展示，少一份解码负担
struct GitHubReleaseDTO: Decodable, Equatable {
    let id: Int64
    let tagName: String
    let name: String?
    let body: String?
    let htmlUrl: String
    let prerelease: Bool
    let draft: Bool
    let publishedAt: String?
    let createdAt: String?
    let assets: [GitHubReleaseAssetDTO]?
}

/// Release 单个资产（一个可下载的构件）。
struct GitHubReleaseAssetDTO: Decodable, Equatable {
    let id: Int64
    let name: String
    let contentType: String?
    let size: Int
    /// REST API 下载端点（非 browser 跳转 URL）。
    let url: String?
    let browserDownloadUrl: String
    let downloadCount: Int
    let createdAt: String?
}

// MARK: - Events（Activity 公告与关注 PR-2，2026-06-16）

/// `GET /users/{username}/received_events/public` 单条事件。
///
/// **不实现 Decodable**：原因是 `payload` 子对象在不同 `type` 下字段完全不同
/// （WatchEvent 只有 `action`；PushEvent 有 `ref` / `commits`；PullRequestEvent
/// 有 `pull_request` 这种嵌套大对象 …）。如果把 payload 解码成 strongly-typed
/// struct，需要为每个 event type 写一份 DTO，且未来 GitHub 加字段时容易 silent fail。
///
/// 采用「网络层把 payload 子对象 reserialize 成 JSON 字符串」的方案：
/// - `EventsAPI` 用 `JSONSerialization` 解析顶层数组、把 `payload` 子树重新 dump 成 String
/// - ViewModel 层按 `type` 二次解析 `payloadJson`（如 PullRequestEvent 取 `pull_request.title`）
/// - DB 持久化时直接落 `activity_events.payload_json TEXT NOT NULL`，无信息丢失
struct GitHubEventDTO: Equatable {

    /// GitHub 事件 ID（字符串数字，如 `"45628942691"`）。GitHub 用 String 不是 Int64。
    let id: String

    /// 事件类型（如 `"WatchEvent"` / `"ForkEvent"` / `"PushEvent"` /
    /// `"IssuesEvent"` / `"PullRequestEvent"` / `"CreateEvent"` /
    /// `"DiscussionEvent"`）。第一版排除：`ReleaseEvent`（决策 Q1，与 releases
    /// 表语义重复）/ `GollumEvent` / `PublicEvent` / `MemberEvent`（信噪比低）。
    let type: String

    /// 行动者（被关注的那个人）。
    let actor: GitHubEventActorDTO

    /// 事件发生的仓库。注意 GitHub events 端点的 `repo.name` 是 full_name 形式
    /// （如 `"torvalds/linux"`），与 `/repos/{owner}/{repo}` 端点的 `name` 字段
    /// （仅 `"linux"`）不同。
    let repo: GitHubEventRepoDTO

    /// payload 子对象的原始 JSON 字符串（已 `.sortedKeys` 规范化，便于 diff）。
    /// ViewModel 二次解析；DB 直接落库。
    let payloadJson: String

    /// 事件创建时间，ISO8601 字符串。
    let createdAt: String
}

/// Event actor（被关注的用户 / 组织）。
///
/// `displayLogin` 字段是 GitHub 在 events 端点专门给出的「显示名」，与 `login`
/// 通常相同，但用户改 login 后 GitHub 会用 displayLogin 显示历史事件的旧名。
/// 解码可选，ViewModel 优先用 `login`。
struct GitHubEventActorDTO: Equatable {
    let id: Int64
    let login: String
    let displayLogin: String?
    let avatarUrl: String?
}

/// Event repo（事件发生的仓库）。
///
/// 注意：events 端点只返回 `id` / `name` (full_name) / `url`，没有 stars /
/// language / description 等元数据。如果 ViewModel 需要这些信息，需要按 `id`
/// 反查本地 `repos` 表（用户 star 过的话有）或留空白。
struct GitHubEventRepoDTO: Equatable {
    let id: Int64
    /// full_name 形式（`"owner/repo"`）。
    let name: String
    let url: String?
}

// MARK: - Announcements（Activity 公告与关注 PR-3，2026-06-17）

/// `GET https://github.blog/feed/` 单条 RSS item（解析后）。
struct GitHubBlogRSSItemDTO: Equatable {
    /// RSS `<guid>` 原生 id（如 `?p=96773`）。入库时加 `blog:` 前缀。
    let guid: String
    let title: String
    let link: String
    let author: String?
    /// RFC 2822 原文（写入层转 ISO8601 入库）。
    let pubDate: String
    let categories: [String]
    /// `<description>` HTML 摘要片段。
    let descriptionHTML: String?
    /// `<content:encoded>` 完整 HTML 正文。
    let contentHTML: String?
}

/// `GET /repos/{owner}/{repo}/security-advisories` 单条 GHSA。
struct GitHubSecurityAdvisoryDTO: Decodable, Equatable {
    let ghsaId: String
    let summary: String
    let description: String?
    let htmlUrl: String?
    let publishedAt: String?
    let severity: String?

    enum CodingKeys: String, CodingKey {
        // `GitHubAPIClient` 的 decoder 已统一启用 `.convertFromSnakeCase`。这里的 raw
        // value 必须保持 camelCase，否则自定义 `init(from:)` 会把 `ghsa_id` 再匹配
        // 成 `ghsa_id`，导致 GitHub 实际响应里的字段被错判为缺失。
        case ghsaId
        case summary
        case description
        case htmlUrl
        case publishedAt
        case severity
    }

    init(
        ghsaId: String,
        summary: String,
        description: String?,
        htmlUrl: String?,
        publishedAt: String?,
        severity: String?
    ) {
        self.ghsaId = ghsaId
        self.summary = summary
        self.description = description
        self.htmlUrl = htmlUrl
        self.publishedAt = publishedAt
        self.severity = severity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ghsaId = try container.decode(String.self, forKey: .ghsaId)

        // GitHub 的 repository security advisory 响应由维护者填写，偶发会缺少
        // `summary` 这类展示字段。Activity feed 只需要跳过或降级展示，不应因
        // 单条 advisory 字段不完整让整批安全公告扫描解析失败。
        let decodedSummary = try container.decodeIfPresent(String.self, forKey: .summary)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        summary = decodedSummary?.nilIfBlank
            ?? description?.nilIfBlank
            ?? ghsaId

        htmlUrl = try container.decodeIfPresent(String.self, forKey: .htmlUrl)
        publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
        severity = try container.decodeIfPresent(String.self, forKey: .severity)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
