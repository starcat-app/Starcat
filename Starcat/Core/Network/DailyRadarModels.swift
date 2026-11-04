//
//  DailyRadarModels.swift
//  Starcat
//
//  日报独立读取契约。内容身份与用户 Star、周刊来源事件分离；
//  摘要引用不可变修订，文章打开后不随目录刷新改变。
//

import Foundation

/// 内容语言不等同于界面语言；来源只发布中英文时明确保留真实语言。
struct DailyRadarQuery: Hashable, Sendable {
    var category: String?
    var period = "daily"
    var language = "en"
    var fallback = false
    var dateFrom: String?
    var dateTo: String?
    var catalogRevision: String?
    var cursor: String?
    var limit = 20

    var parameters: [URLQueryItem] {
        var values = [
            URLQueryItem(name: "period", value: period),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "fallback", value: fallback ? "true" : "false"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        for (name, value) in [
            ("category", category), ("date_from", dateFrom), ("date_to", dateTo),
            ("catalog_revision", catalogRevision), ("cursor", cursor)
        ] {
            if let value { values.append(.init(name: name, value: value)) }
        }
        return values
    }
}

/// 目录及日期均携带版本，跨请求版本不同必须重新开始分页。
/// 计数字段为可选解码：旧版后端不返回时保持 nil，侧边栏徽标随之隐藏。
struct DailyRadarCatalog: Decodable, Sendable {
    struct Category: Decodable, Sendable, Identifiable {
        let id: String
        let title: String
        let period: String
    }
    let catalogRevision: String
    let categories: [Category]
    let availableLanguages: [String]
    let latestAvailableDate: String?
    /// 按请求语言去重后的各分类报告总数（覆盖全部期次，不按 period 过滤）。
    let categoryCounts: [String: Int]?
    let totalCount: Int?
    enum CodingKeys: String, CodingKey {
        case catalogRevision = "catalog_revision", categories
        case availableLanguages = "available_languages", latestAvailableDate = "latest_available_date"
        case categoryCounts = "category_counts", totalCount = "total_count"
    }
}

extension DailyRadarCatalog.Category {

    /// 分类展示名：按 id 走 Catalog（`dailyRadar.category.<id>`），未收录 id 回退
    /// 服务端 title。服务端 title 只有英文基准（weekly-api `Categories` 表），
    /// 各语言文案由客户端 Catalog 提供。
    var localizedTitle: String {
        Self.localizedTitle(for: id, fallback: title)
    }

    /// 只有分类 id 的场景（如 `DailyRadarReport.category`）用这个；
    /// id 未收录时回退 fallback，调用方不传则显示 id 原文（与旧行为一致）。
    static func localizedTitle(for id: String, fallback: String? = nil) -> String {
        String.l10n("dailyRadar.category.\(id)", defaultValue: fallback ?? id)
    }
}

/// 设置页在本地还没有 catalog 缓存时的静态回退清单；
/// 与 weekly-api `internal/dailyradar/model.go` 的 `Categories` 单一信任源同步维护，
/// 后端新增分类时这里同步补一条（设置区先展示，首次拉取后以服务端为准）。
extension DailyRadarCatalog {
    static let fallbackCategories: [Category] = [
        .init(id: "ai-cli", title: "AI CLI", period: "daily"),
        .init(id: "ai-agents", title: "AI Agents", period: "daily"),
        .init(id: "ai-infra", title: "AI Infrastructure", period: "daily"),
        .init(id: "ai-web", title: "AI Official", period: "daily"),
        .init(id: "ai-trending", title: "AI Open Source", period: "daily"),
        .init(id: "ai-hn", title: "Hacker News", period: "daily"),
        .init(id: "ai-ph", title: "Product Hunt", period: "daily"),
        .init(id: "ai-arxiv", title: "ArXiv", period: "daily"),
        .init(id: "ai-hf", title: "Hugging Face", period: "weekly"),
        .init(id: "ai-community", title: "Community", period: "daily"),
        .init(id: "ai-weekly", title: "AI Weekly Archive", period: "weekly"),
        // 独立编辑栏目，保留历史生态周报的分类身份与归档
        .init(id: "ai-weekly-events", title: "Weekly AI Highlights", period: "weekly"),
        .init(id: "ai-monthly", title: "AI Monthly Archive", period: "monthly"),
    ]
}

struct DailyRadarDates: Decodable, Sendable {
    struct Edition: Decodable, Sendable, Identifiable {
        let date: String
        let count: Int
        var id: String { date }
    }
    let catalogRevision: String
    let dates: [Edition]
    let latestAvailableDate: String?
    enum CodingKeys: String, CodingKey {
        case catalogRevision = "catalog_revision", dates, latestAvailableDate = "latest_available_date"
    }
}

struct DailyRadarPage: Decodable, Sendable {
    let catalogRevision: String
    let requestedLanguage: String
    let items: [DailyRadarReport]
    let total: Int
    let nextCursor: String?
    let featuredID: String?
    enum CodingKeys: String, CodingKey {
        case catalogRevision = "catalog_revision", requestedLanguage = "requested_language"
        case items, total, nextCursor = "next_cursor", featuredID = "featured_id"
    }
}

/// 同一 DTO 解码摘要及详情；正文与项目字段只有详情返回，禁止摘要伪造正文。
struct DailyRadarReport: Decodable, Sendable, Identifiable {
    struct Cover: Decodable, Sendable {
        let kind: String
        let cardURL: URL?
        let heroURL: URL?
        let fallback: String
        let alt: String
        enum CodingKeys: String, CodingKey {
            case kind, cardURL = "card_url", heroURL = "hero_url", fallback, alt
        }
    }
    struct Source: Decodable, Sendable {
        let name: String
        let url: URL
        let commit: String
        let path: String
    }
    struct Project: Decodable, Sendable, Identifiable {
        let repo: StarcatRepoCardDTO
        let evidenceURL: URL
        let sectionAnchor: String?
        var id: String { repo.fullName }
        var summary: String { repo.description ?? "" }
        var url: URL { repo.htmlUrl ?? URL(string: "https://github.com/\(repo.fullName)")! }
        enum CodingKeys: String, CodingKey {
            case repo, evidenceURL = "evidence_url", sectionAnchor = "section_anchor"
        }
    }

    let id: String
    let revision: String
    let editionDate: String
    let category: String
    let period: String
    let title: String
    let summary: String
    let readingMinutes: Int
    let cover: Cover
    let relatedProjectCount: Int
    let contentLanguage: String
    let availableLanguages: [String]
    let source: Source?
    let markdown: String?
    let relatedProjects: [Project]?
    let relatedProjectsStatus: String?
    let generatedAt: String?
    let updatedAt: String?

    var date: Date {
        // 业务日期固定上海正午，避免系统时区把日报显示到前一天。
        ISO8601DateFormatter().date(from: "\(editionDate)T12:00:00+08:00") ?? .distantPast
    }
    var minutes: Int { readingMinutes }
    var contentIdentity: String { "\(id)|\(contentLanguage)|\(revision)" }
    enum CodingKeys: String, CodingKey {
        case id, revision, editionDate = "edition_date", category, period, title, summary
        case readingMinutes = "reading_minutes", cover, relatedProjectCount = "related_project_count"
        case contentLanguage = "content_language", availableLanguages = "available_languages"
        case source, markdown, relatedProjects = "related_projects", relatedProjectsStatus = "related_projects_status"
        case generatedAt = "generated_at", updatedAt = "updated_at"
    }
}
