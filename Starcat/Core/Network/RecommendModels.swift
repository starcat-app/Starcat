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
    let source: String
    let reasons: [String]

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
        case source
        case reasons
    }
}

/// 推荐接口 data 段。
struct RepoRecommendationPage: Decodable, Sendable, Equatable {
    let source: String
    let fallback: Bool
    let repoID: Int64
    /// v1 SimRepo 不返回该字段；v2 用它标识当前原子激活的 ServingBundle。
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
