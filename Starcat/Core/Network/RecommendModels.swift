//
//  RecommendModels.swift
//  Starcat
//
//  starcat-recommend-api 的 endpoint-specific DTO。
//
//  设计约束：
//  - 不扩写 `StarcatRepoCardDTO`：推荐接口有自己的分页、来源和推荐理由语义。
//  - 字段按后端 snake_case 显式 CodingKeys 映射，JSONDecoder 不开 convertFromSnakeCase。
//

import Foundation

/// 单张相似仓库推荐卡片。
///
/// **2026-06-29 补 `Encodable`（→ `Codable`）**：`DiskRecommendationCache` 把整个
/// `[RepoRecommendationItem]` 直接落盘，与 `DiskWikiCache` 给 `WikiStatusItem` 加
/// `Encodable` 同款做法（详见 `DiskWikiCache.swift` 注释）。原始 DTO 仍只需
/// server→client 单向解码，加上 `Encodable` 只是为了让 Codable 合成。
struct RepoRecommendationItem: Codable, Identifiable, Sendable, Equatable {
    let repoID: Int64
    let fullName: String
    let description: String?
    let language: String?
    let stars: Int
    let forks: Int
    let archived: Bool
    let score: Double
    /// 模型内全局百分位，仅自研单仓推荐返回；原始 score 继续用于排序和诊断。
    let displayScore: Double?
    let source: String
    let reasons: [String]
    /// 实际正向来源的公开快照；旧服务尚未部署此字段时保持缺省，不能由客户端猜测关联。
    var matchedSeeds: [RecommendationSeed]?

    init(
        repoID: Int64,
        fullName: String,
        description: String?,
        language: String?,
        stars: Int,
        forks: Int,
        archived: Bool,
        score: Double,
        displayScore: Double? = nil,
        source: String,
        reasons: [String],
        matchedSeeds: [RecommendationSeed]? = nil
    ) {
        self.repoID = repoID
        self.fullName = fullName
        self.description = description
        self.language = language
        self.stars = stars
        self.forks = forks
        self.archived = archived
        self.score = score
        self.displayScore = displayScore
        self.source = source
        self.reasons = reasons
        self.matchedSeeds = matchedSeeds
    }

    var id: Int64 { repoID }

    var githubURL: URL? {
        URL(string: "https://github.com/\(fullName)")
    }

    enum CodingKeys: String, CodingKey {
        case repoID = "repo_id"
        case fullName = "full_name"
        case description
        case language
        case stars
        case forks
        case archived
        case score
        case displayScore = "display_score"
        case source
        case reasons
        case matchedSeeds = "matched_seeds"
    }
}

/// 一条推荐边的来源资料随历史保存，来源取消 Star 后仍能解释当时的推荐事实。
struct RecommendationSeed: Codable, Sendable, Equatable {
    let repoID: Int64
    let fullName: String
    let description: String?
    let language: String?
    let reasons: [String]?

    enum CodingKeys: String, CodingKey {
        case repoID = "repo_id", fullName = "full_name"
        case description, language, reasons
    }
}

/// 推荐接口 data 段。
struct RepoRecommendationPage: Decodable, Sendable, Equatable {
    let source: String
    let fallback: Bool
    let repoID: Int64
    /// 标识活动 ServingBundle / 源内容快照；可空以便解码缺少版本的旧缓存。
    let modelVersion: String?
    let items: [RepoRecommendationItem]
    let hasMore: Bool
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case source
        case fallback
        case repoID = "repo_id"
        case modelVersion = "model_version"
        case items
        case hasMore = "has_more"
        case nextOffset = "next_offset"
    }
}
