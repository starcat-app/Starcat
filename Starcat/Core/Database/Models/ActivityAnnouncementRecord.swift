//
//  ActivityAnnouncementRecord.swift
//  Starcat
//
//  Activity 公告与关注 PR-1（2026-06-16）：announcement 分类双源公告聚合
//  GRDB 持久化记录。对应 `activity_announcements` 表。
//
//  关键设计（详见 DatabaseMigrationsV1.createActivityAnnouncements 注释）：
//  - 双源（blog / security），不同 `source` 占用不同 id 命名空间避免碰撞：
//    `"blog:<rss guid>"` / `"security:<GHSA id>"`（dong4j 2026-06-16 决策 P1）。
//    schema 不强制 enforce id 前缀，由 Repository 写入层使用 `AnnouncementSource.makeId(_:)`
//    构造。
//  - `bodyMarkdown` 字段名沿用「markdown」语义，实际 RSS 拉到的是 HTML 片段
//    （`content:encoded`），与 `releases.body_markdown` 风格统一为「正文 blob」语义，
//    不限定具体 markup 格式。
//  - `categories` 用 JSON 数组字符串直存（RSS 可有多 category），与 `repos.topics`
//    同款策略；编解码由业务层处理，参考 `AnnouncementCategoriesCodec`。
//  - `isRead` device-local，不挂 CloudKit（决策 M2）。
//

import Foundation
import GRDB

// MARK: - AnnouncementSource

/// 公告来源枚举。schema 用 String 列存，这里集中常量避免业务代码散落字符串字面量。
///
/// **id 前缀规范**：写入 `activity_announcements.id` 时**必须**通过
/// `makeId(nativeId:)` 拼接 `"<source>:<nativeId>"`，让读出来的 id 看一眼能区分
/// 来源（dong4j 2026-06-16 决策 P1：与 `ActivityItem.id` 命名风格对齐）。
///
/// **删除的源**（决策 Q2 删除 discussions 后只剩 2 源）：
/// - `.discussion`：Discussions GraphQL 在 starred repos 拉 Announcements 类别 —— 命中率 < 5% +
///   1810 repo 拼 query 接近 GraphQL 50KB 上限，性价比极低，方案 v2 整段删除。
enum AnnouncementSource: String, Sendable, Codable, CaseIterable {
    /// GitHub Blog RSS（`github.blog/feed/`）：100% 覆盖率，所有用户都看到 GitHub 平台公告。
    case blog
    /// GitHub Security Advisory（`GET /repos/{o}/{r}/security-advisories`）：~2-3% 覆盖率，
    /// 仅查「最近 30 天有 push」的 starred repo（约 50~200 个）。
    case security

    /// 构造 `activity_announcements.id`：`"<source>:<nativeId>"`。
    ///
    /// `nativeId` 含义按 source 不同：
    /// - `.blog`：RSS `<guid>` 内容（如 `?p=96773`）
    /// - `.security`：GHSA id（如 `GHSA-xxxx-xxxx-xxxx`）
    func makeId(nativeId: String) -> String {
        "\(rawValue):\(nativeId)"
    }
}

// MARK: - Record

struct ActivityAnnouncementRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable {

    static let databaseTableName = "activity_announcements"

    /// PK：`"<source>:<nativeId>"`（如 `"blog:96773"` / `"security:GHSA-xxxx-..."`）。
    /// 由 `AnnouncementSource.makeId(nativeId:)` 统一构造。
    var id: String

    /// 来源（用 String 列存对应 `AnnouncementSource.rawValue`）。
    var source: String

    /// 公告标题。
    var title: String

    /// 公告正文（实为 HTML 片段，命名沿用 markdown 语义保持与 `releases.body_markdown`
    /// 风格统一）。UI 详情走 WKWebView 渲染（复用 `ReadmeWebView`）。
    var bodyMarkdown: String?

    /// 作者（RSS `dc:creator`）。security 来源可能没有具体作者。
    var author: String?

    /// 公告原文 URL。
    var url: String

    /// 关联 repo 全名 `"owner/repo"`。
    /// - `.blog` 来源：nil（GitHub 平台公告非个性化）
    /// - `.security` 来源：必有（绑定具体 repo 的 GHSA）
    var repoName: String?

    /// RSS / GHSA 分类 / 标签的 JSON 数组字符串（如 `["AI & ML", "Security"]`）。
    /// 编解码走 `AnnouncementCategoriesCodec`。
    var categories: String?

    /// 用户已读状态。默认 false（未读）。device-local，不走 CloudKit。
    var isRead: Bool

    /// 公告发布时间（ISO8601 原文）。RSS `pubDate` 是 RFC 2822 格式，写入层转 ISO8601
    /// 保持本表内格式统一（与 `releases.published_at` 同款）。
    var createdAt: String

    /// 本地拉取时间（ISO8601）。仅作 debug / 数据清理冷却判定用。
    var fetchedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case title
        case bodyMarkdown = "body_markdown"
        case author
        case url
        case repoName = "repo_name"
        case categories
        case isRead = "is_read"
        case createdAt = "created_at"
        case fetchedAt = "fetched_at"
    }
}

// MARK: - Categories JSON 编解码

/// 集中处理 `categories` 数组与 JSON 字符串字段的相互转换。
///
/// 抽出来的理由与 `ReleaseAssetCodec` 同——避免业务层反复 try-catch + JSONEncoder。
/// nil / 空数组都编码成 nil 入库，节省 `[]` 占位字符。
enum AnnouncementCategoriesCodec {

    /// 把 categories 数组编码为 JSON 字符串（写库前调用）。
    static func encode(_ categories: [String]?) -> String? {
        guard let categories, !categories.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(categories),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    /// 解析数据库中的 categories 字段。
    /// 解析失败回落空数组，避免单行损坏导致整个公告流崩溃。
    static func decode(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return decoded
    }
}
