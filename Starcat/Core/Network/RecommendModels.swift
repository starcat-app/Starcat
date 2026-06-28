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
struct RepoRecommendationItem: Decodable, Identifiable, Sendable, Equatable {
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
    let items: [RepoRecommendationItem]
    let hasMore: Bool
    let nextOffset: Int?

    enum CodingKeys: String, CodingKey {
        case source
        case fallback
        case repoID = "repo_id"
        case items
        case hasMore = "has_more"
        case nextOffset = "next_offset"
    }
}
