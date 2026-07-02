//
//  CompanionModels.swift
//  Starcat
//
//  Browser Plugin 本机 API DTO。
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
        capabilities: ["repo-context", "notes", "tags", "ai-summary", "actions", "events"]
    )
}

struct CompanionRepoContextResponse: Codable, Equatable {
    let schemaVersion: Int
    let repo: CompanionRepoDTO
    let recommendations: [CompanionRecommendationDTO]
    let wikiLinks: [CompanionWikiLinkDTO]
    let tags: [CompanionTagDTO]
    let availableTags: [CompanionTagDTO]
    let aiSummary: CompanionAISummaryDTO?
    let note: CompanionNoteDTO?
    let health: CompanionHealthDTO?
    let openssf: CompanionOpenSSFDTO?
    let actions: CompanionActionsDTO
    let entitlement: CompanionEntitlementDTO
}

struct CompanionRepoDTO: Codable, Equatable {
    let owner: String
    let name: String
    let fullName: String
    let repoID: Int64?
    let htmlURL: String
    let knownToStarcat: Bool
    let isStarred: Bool
    let libraryState: String
    let isInLibrary: Bool
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

struct CompanionTagDTO: Codable, Equatable {
    let id: String
    let name: String
    let color: String?
    let icon: String?
}

struct CompanionAISummaryDTO: Codable, Equatable {
    let markdown: String
    let model: String?
    let generatedAt: String?
}

struct CompanionTagsUpdateRequest: Codable, Equatable {
    let owner: String
    let repo: String
    let tagIds: [String]
}

struct CompanionTagsUpdateResponse: Codable, Equatable {
    let schemaVersion: Int
    let status: String
    let tags: [CompanionTagDTO]
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

struct CompanionLibraryStateUpdateRequest: Codable, Equatable {
    let owner: String
    let repo: String
    let state: String
    let downgradeUsingStatus: Bool?
}

struct CompanionLibraryStateUpdateResponse: Codable, Equatable {
    let schemaVersion: Int
    let status: String
    let repoID: Int64
    let libraryState: String
}

struct CompanionEventEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let type: String
    let repoID: Int64?
    let note: CompanionNoteDTO?
    let tags: [CompanionTagDTO]?
    let aiSummary: CompanionAISummaryDTO?
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
    let generateSummary: Bool
    let codeflow: Bool
    let codebase: Bool
}

struct CompanionEntitlementDTO: Codable, Equatable {
    let isPro: Bool
}
