//
//  ContributionsAPI.swift
//  Starcat
//
//  GitHub 用户贡献草坪（contribution calendar）拉取端点封装。
//  HOM-PROFILE 2026-06-05 引入。
//
//  设计动机：
//  - 贡献草坪数据只能通过 GraphQL `user.contributionsCollection.contributionCalendar`
//    获取，GitHub REST API 不暴露。这是 GitHub 官方端点，不算第三方依赖。
//  - 我们不引入 Apollo 等 GraphQL 客户端框架；本端点只查询一个 schema，
//    手写 query 字符串 + 普通 Decodable 解码足够。
//  - 用 `GitHubAPIClient.graphql(query:variables:)` 通用方法承载（见同目录 `GitHubAPIClient.swift`）。
//
//  数据形态（示例响应）：
//  ```json
//  {
//    "user": {
//      "contributionsCollection": {
//        "contributionCalendar": {
//          "totalContributions": 1234,
//          "weeks": [
//            {
//              "contributionDays": [
//                { "date": "2025-06-08", "contributionCount": 3, "contributionLevel": "FIRST_QUARTILE", "weekday": 0 },
//                ...
//              ]
//            },
//            ...
//          ]
//        }
//      }
//    }
//  }
//  ```
//
//  关键约束：
//  - GitHub 草坪默认返回 53 周 × 7 天（往前推近 1 年）。如需自定义时间窗，可加 `from`/`to` 变量。
//  - `contributionLevel` 是 GitHub 官方分级（NONE / FIRST_QUARTILE / SECOND_QUARTILE /
//    THIRD_QUARTILE / FOURTH_QUARTILE），UI 按此映射 5 档绿色块。
//  - GraphQL token 鉴权与 REST 共用（同一 OAuth scope）；OAuth Device Flow 的
//    `read:user` scope 已足够读取本人贡献草坪。
//

import Foundation

extension GitHubAPIClient {

    /// 获取指定用户的贡献草坪（近 1 年）。
    ///
    /// - Parameter login: GitHub 登录名（不含 `@`）；通常传当前登录用户 `user.login`，
    ///   但理论上传任意公开用户名都可（GraphQL 返回公开贡献，私有贡献仅自己可见）。
    /// - Returns: 贡献草坪结构（含总数 + 53 周快照）。
    /// - Throws: `NetworkError`；token 失效 → 401 → 触发集中式登出回调。
    func contributionCalendar(login: String) async throws -> ContributionCalendarPayload {
        // 注意：GraphQL schema 中 `weekday` 是 0=Sunday ~ 6=Saturday，与系统 Calendar 不同。
        // UI 渲染时把第一行（weekday=0）放在最上面，与 GitHub 主页布局一致。
        let query = """
        query($login: String!) {
          user(login: $login) {
            contributionsCollection {
              totalCommitContributions
              totalIssueContributions
              totalPullRequestContributions
              totalPullRequestReviewContributions
              totalRepositoryContributions
              contributionCalendar {
                totalContributions
                weeks {
                  contributionDays {
                    date
                    contributionCount
                    contributionLevel
                    weekday
                  }
                }
              }
            }
          }
        }
        """

        // 用 Decodable 嵌套 struct 而非 [String: Any] 字典：自动校验字段名，
        // 字段缺失时立刻报 decodingError，比 runtime 取 dict 安全得多。
        struct Response: Decodable {
            let user: UserNode?
            struct UserNode: Decodable {
                let contributionsCollection: CollectionNode
                struct CollectionNode: Decodable {
                    let totalCommitContributions: Int
                    let totalIssueContributions: Int
                    let totalPullRequestContributions: Int
                    let totalPullRequestReviewContributions: Int
                    let totalRepositoryContributions: Int
                    let contributionCalendar: CalendarNode

                    struct CalendarNode: Decodable {
                        let totalContributions: Int
                        let weeks: [ContributionWeek]
                    }
                }
            }
        }

        let resp = try await graphql(
            query: query,
            variables: ["login": login],
            as: Response.self
        )
        guard let collection = resp.user?.contributionsCollection else {
            throw NetworkError.notFound
        }
        return ContributionCalendarPayload(
            totalContributions: collection.contributionCalendar.totalContributions,
            weeks: collection.contributionCalendar.weeks,
            activityStats: ContributionActivityStats(
                commits: collection.totalCommitContributions,
                issues: collection.totalIssueContributions,
                pullRequests: collection.totalPullRequestContributions,
                reviews: collection.totalPullRequestReviewContributions,
                repositories: collection.totalRepositoryContributions
            )
        )
    }
}

// MARK: - DTO

/// 贡献草坪根节点（GraphQL `ContributionCalendar` 类型）。
///
/// 直接对应 GraphQL schema 字段；不做命名转换（GraphQL 字段已是 camelCase）。
/// 但因 `GitHubAPIClient` 的 decoder 全局开了 `convertFromSnakeCase`，
/// camelCase 字段名会被反向转成 snake_case 查找——对纯 camelCase 字段无影响，
/// 但需注意：若新增字段含全小写复合词（如 `htmlurl`），decoder 仍按 snake_case 规则解析。
///
/// `Codable`（Encodable + Decodable）一并声明，是因为 `ContributionService` 把整份
/// payload 序列化到 UserDefaults 做磁盘缓存。Swift 要求 `Encodable` 自动合成
/// `encode(to:)` 必须与类型声明同源文件，所以这里直接挂 Codable，而非在 service
/// 文件里 extension（会触发 `extension outside of file ... prevents automatic synthesis`）。
struct ContributionCalendarPayload: Codable, Equatable, Sendable {
    /// 近 1 年总贡献数。
    let totalContributions: Int
    /// 53 周快照，每周含 7 天（最后一周可能不满 7 天，因为日历对齐）。
    let weeks: [ContributionWeek]
    /// 同一时间窗口内的五类贡献统计，供桌面 Widget 的雷达图使用。
    let activityStats: ContributionActivityStats

    init(
        totalContributions: Int,
        weeks: [ContributionWeek],
        activityStats: ContributionActivityStats = .empty
    ) {
        self.totalContributions = max(0, totalContributions)
        self.weeks = weeks
        self.activityStats = activityStats
    }

    private enum CodingKeys: String, CodingKey {
        case totalContributions
        case weeks
        case activityStats
    }

    /// 旧版 UserDefaults 缓存没有五维统计；缺失时回落为零，保留草坪秒显能力。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            totalContributions: try container.decode(Int.self, forKey: .totalContributions),
            weeks: try container.decode([ContributionWeek].self, forKey: .weeks),
            activityStats: try container.decodeIfPresent(
                ContributionActivityStats.self,
                forKey: .activityStats
            ) ?? .empty
        )
    }
}

/// GitHub `ContributionsCollection` 在同一时间窗口内提供的五类活动统计。
struct ContributionActivityStats: Codable, Equatable, Sendable {
    let commits: Int
    let issues: Int
    let pullRequests: Int
    let reviews: Int
    let repositories: Int

    init(
        commits: Int,
        issues: Int,
        pullRequests: Int,
        reviews: Int,
        repositories: Int
    ) {
        self.commits = max(0, commits)
        self.issues = max(0, issues)
        self.pullRequests = max(0, pullRequests)
        self.reviews = max(0, reviews)
        self.repositories = max(0, repositories)
    }

    static let empty = ContributionActivityStats(
        commits: 0,
        issues: 0,
        pullRequests: 0,
        reviews: 0,
        repositories: 0
    )
}

/// 一周（7 天）。
struct ContributionWeek: Codable, Equatable, Sendable {
    let contributionDays: [ContributionDay]
}

/// 单天贡献数据。
struct ContributionDay: Codable, Equatable, Sendable {
    /// ISO8601 日期（`YYYY-MM-DD`），用于 tooltip 显示。
    let date: String
    /// 当天贡献数（commit + PR + Issue + Review）。
    let contributionCount: Int
    /// GitHub 官方分级（5 档），UI 按此映射颜色深浅。
    let contributionLevel: ContributionLevel
    /// 一周中的第几天，0=Sunday ~ 6=Saturday。
    let weekday: Int
}

/// 贡献分级（与 GitHub `ContributionLevel` enum 一一对应）。
///
/// 渲染时按分级取颜色，而非按 count 自己分桶——保证与 GitHub 主页视觉完全一致。
/// 解码用 `RawValue: String`，未知值（GitHub 未来扩展）回落到 `.none`。
enum ContributionLevel: String, Codable, Equatable, Sendable {
    case none = "NONE"
    case firstQuartile = "FIRST_QUARTILE"
    case secondQuartile = "SECOND_QUARTILE"
    case thirdQuartile = "THIRD_QUARTILE"
    case fourthQuartile = "FOURTH_QUARTILE"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ContributionLevel(rawValue: raw) ?? .none
    }
}
