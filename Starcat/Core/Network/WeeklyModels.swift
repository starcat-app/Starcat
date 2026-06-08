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

// MARK: - API Response

/// `/api/weekly/projects` 响应 DTO（外层包装）。
struct WeeklyProjectListDTO: Decodable {
    let items: [WeeklyProjectDTO]
    let total: Int
    let page: Int
    let pageSize: Int

    enum CodingKeys: String, CodingKey {
        case items
        case total
        case page
        case pageSize = "page_size"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.items = try container.decodeIfPresent([WeeklyProjectDTO].self, forKey: .items) ?? []
        self.total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        self.page = try container.decodeIfPresent(Int.self, forKey: .page) ?? 1
        self.pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 20
    }
}

/// 单个项目 DTO。
struct WeeklyProjectDTO: Decodable {
    let owner: String
    let repo: String
    let url: String
    let description: String?
    let stars: Int
    let language: String?
    let firstIssue: Int
    let issueUrl: String

    enum CodingKeys: String, CodingKey {
        case owner
        case repo
        case url
        case description
        case stars
        case language
        case firstIssue = "first_issue"
        case issueUrl = "issue_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.owner = try container.decode(String.self, forKey: .owner)
        self.repo = try container.decode(String.self, forKey: .repo)
        self.url = try container.decode(String.self, forKey: .url)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.stars = try container.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        self.language = try container.decodeIfPresent(String.self, forKey: .language)
        self.firstIssue = try container.decodeIfPresent(Int.self, forKey: .firstIssue) ?? 0
        self.issueUrl = try container.decodeIfPresent(String.self, forKey: .issueUrl) ?? ""
    }
}

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

    var fullName: String { "\(owner)/\(name)" }

    init(dto: WeeklyProjectDTO) {
        self.owner = dto.owner
        self.name = dto.repo
        self.url = URL(string: dto.url) ?? GitHubURLs.repo(owner: dto.owner, repo: dto.repo)
        self.description = dto.description
        self.stars = dto.stars
        self.language = dto.language
        self.firstIssue = dto.firstIssue
        self.issueURL = dto.issueUrl.isEmpty ? nil : URL(string: dto.issueUrl)
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
