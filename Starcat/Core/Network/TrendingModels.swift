//
//  TrendingModels.swift
//  Starcat
//
//  GitHub Trending API 响应 DTO。
//
//  数据源：https://trend.doforce.dpdns.org/repo
//  API 参数：since (daily/weekly/monthly), lang (语言筛选)
//
//  设计约束：
//  - DTO 字段名与上游 API 保持一致（snake_case）
//  - 不做业务逻辑转换，只做解码
//

import Foundation

// MARK: - API Response

/// Trending API 响应包装。
struct TrendingResponseDTO: Decodable {
    let repo: String          // "/owner/repo" 格式
    let desc: String?         // 仓库描述
    let lang: String?         // 编程语言
    let stars: Int            // 当前总 stars
    let forks: Int            // 当前 forks
    let buildBy: [TrendingContributorDTO]  // 贡献者列表
    let change: Int?          // 周期内新增 stars（对应 starsInPeriod）

    enum CodingKeys: String, CodingKey {
        case repo
        case desc
        case lang
        case stars
        case forks
        case buildBy = "build_by"
        case change
    }

    init(
        repo: String,
        desc: String?,
        lang: String?,
        stars: Int,
        forks: Int,
        buildBy: [TrendingContributorDTO],
        change: Int?
    ) {
        self.repo = repo
        self.desc = desc
        self.lang = lang
        self.stars = stars
        self.forks = forks
        self.buildBy = buildBy
        self.change = change
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.repo = try container.decode(String.self, forKey: .repo)
        self.desc = try container.decodeIfPresent(String.self, forKey: .desc)
        self.lang = try container.decodeIfPresent(String.self, forKey: .lang)
        self.stars = try container.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        self.forks = try container.decodeIfPresent(Int.self, forKey: .forks) ?? 0
        self.buildBy = try container.decodeIfPresent([TrendingContributorDTO].self, forKey: .buildBy) ?? []
        self.change = try container.decodeIfPresent(Int.self, forKey: .change)
    }
}

/// 贡献者 DTO。
struct TrendingContributorDTO: Decodable {
    let avatar: String   // 头像 URL
    let by: String       // GitHub 用户名（格式 "/username"）
}

// MARK: - Domain Model

/// Trending 仓库领域模型。
///
/// 从 TrendingResponseDTO 转换而来，用于 UI 展示。
/// 包含计算属性用于格式化显示。
struct TrendingRepo: Identifiable, Equatable {
    /// 唯一标识（使用 fullName 作为 id）
    var id: String { fullName }

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

    /// 当前总 stars
    let starsCount: Int

    /// 当前 forks
    let forksCount: Int

    /// 周期内新增 stars
    let starsInPeriod: Int

    /// 周期文本描述（如 "321 stars today"）
    let periodText: String

    /// 贡献者列表
    let contributors: [Contributor]

    /// 初始化。
    /// - Parameter dto: API 响应 DTO
    init(dto: TrendingResponseDTO, since: TrendingPeriod) {
        // 解析 fullName："/owner/repo" -> "owner/repo"
        let cleanPath = dto.repo.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.fullName = cleanPath

        let parts = cleanPath.split(separator: "/", maxSplits: 1)
        self.owner = parts.count > 0 ? String(parts[0]) : ""
        self.name = parts.count > 1 ? String(parts[1]) : cleanPath

        self.url = URL(string: "https://github.com/\(cleanPath)")!
        self.description = dto.desc
        self.language = dto.lang
        self.starsCount = dto.stars
        self.forksCount = dto.forks
        self.starsInPeriod = dto.change ?? 0

        // 生成周期文本
        let periodName: String
        switch since {
        case .daily:   periodName = "today"
        case .weekly:  periodName = "this week"
        case .monthly: periodName = "this month"
        }
        self.periodText = "\(self.starsInPeriod) stars \(periodName)"

        // 转换贡献者
        self.contributors = dto.buildBy.map { c in
            let username = c.by.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return Contributor(
                username: username,
                avatarURL: URL(string: c.avatar),
                profileURL: URL(string: "https://github.com/\(username)")
            )
        }
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

    /// 用户可见的显示名称
    var displayName: String {
        switch self {
        case .daily:   return "今日"
        case .weekly:  return "本周"
        case .monthly: return "本月"
        }
    }

    /// 英文名称（用于 API 参数）
    var apiValue: String { rawValue }
}

// MARK: - Language

/// 支持的语言筛选选项。
enum TrendingLanguage: String, CaseIterable, Identifiable {
    case all = ""
    case swift = "Swift"
    case python = "Python"
    case typescript = "TypeScript"
    case javascript = "JavaScript"
    case go = "Go"
    case rust = "Rust"
    case java = "Java"
    case kotlin = "Kotlin"
    case dart = "Dart"

    var id: String { rawValue }

    var displayName: String {
        if self == .all { return "全部语言" }
        return rawValue
    }

    /// API 参数值（空字符串表示全部）
    var apiValue: String { rawValue }
}
