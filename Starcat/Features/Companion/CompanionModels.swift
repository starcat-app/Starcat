//
//  CompanionModels.swift
//  Starcat
//
//  Chrome Companion 本机 API DTO。
//
//  这些类型是 Starcat App 与 Chrome 插件之间的稳定 JSON 契约。字段保持 Swift
//  camelCase, 由 `CompanionLocalServer` 统一编码成 snake_case, 避免每个 DTO 都手写
//  CodingKeys。业务层后续只负责填充这些 DTO, 不直接拼 JSON。
//

import Foundation

struct CompanionPingResponse: Codable, Equatable {
    let schemaVersion: Int
    let status: String
    let app: String
    let capabilities: [String]

    static let ok = CompanionPingResponse(
        schemaVersion: 1,
        status: "ok",
        app: "Starcat",
        capabilities: ["repo-context", "notes", "actions"]
    )
}

struct CompanionRepoContextResponse: Codable, Equatable {
    let schemaVersion: Int
    let repo: CompanionRepoDTO
    let recommendations: [CompanionRecommendationDTO]
    let wikiLinks: [CompanionWikiLinkDTO]
    let note: CompanionNoteDTO?
    let health: CompanionHealthDTO?
    let openssf: CompanionOpenSSFDTO?
    let actions: CompanionActionsDTO
}

struct CompanionRepoDTO: Codable, Equatable {
    let owner: String
    let name: String
    let fullName: String
    let repoID: Int64?
    let htmlURL: String
    let knownToStarcat: Bool
    let isStarred: Bool
}

struct CompanionRecommendationDTO: Codable, Equatable {
    let repoID: Int64?
    let fullName: String
    let description: String?
    let language: String?
    let stars: Int
    let score: Double?
    let reason: String?
}

struct CompanionWikiLinkDTO: Codable, Equatable {
    let source: String
    let title: String
    let url: String
}

struct CompanionNoteDTO: Codable, Equatable {
    let editable: Bool
    let content: String
    /// ISO-8601 字符串。DTO 层不持有 Date, 避免插件端因时区或编码策略变化破坏兼容。
    let editedAt: String?
}

struct CompanionNoteSaveRequest: Codable, Equatable {
    let owner: String
    let repo: String
    let content: String
}

struct CompanionNoteSaveResponse: Codable, Equatable {
    let schemaVersion: Int
    let status: String
    let note: CompanionNoteDTO
}

struct CompanionOpenActionRequest: Codable, Equatable {
    let owner: String
    let repo: String
    let action: CompanionOpenAction
}

struct CompanionOpenActionResponse: Codable, Equatable {
    let schemaVersion: Int
    let status: String
    let action: CompanionOpenAction
}

struct CompanionHealthDTO: Codable, Equatable {
    let score: Double
    let grade: String
    /// ISO-8601 字符串, 直接对应 Health 缓存生成时间。
    let computedAt: String?
}

struct CompanionOpenSSFDTO: Codable, Equatable {
    let score: Double
    /// OpenSSF API 返回的是日期粒度, 用字符串保留原始语义。
    let scoreDate: String?
}

struct CompanionActionsDTO: Codable, Equatable {
    let openInStarcat: Bool
    let codeflow: Bool
    let codebase: Bool
}
