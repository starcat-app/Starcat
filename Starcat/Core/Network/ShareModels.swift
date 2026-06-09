//
//  ShareModels.swift
//  Starcat
//
//  分享相关的 DTO 模型。
//
//  R-01 v1.2 改造（2026-06-09）：
//  - 后端 sharing-api 升级到 envelope 响应（schema_version + data）
//  - 响应 data 字段集扩到 `shareUrl + shareId + expiresAt + createdAt`
//  - `expiresAt` 改 nullable（永不过期 = null）
//  - 旧的非 envelope 顶层 `ShareResponseDTO` 已删除，改走 `ShareCreateResponse`
//

import Foundation

// MARK: - 请求

/// 分享创建请求体（POST /api/v1/share 的 body）。
///
/// 字段命名 camelCase 是历史遗留：sharing 后端的 ShareRepoRequest 也用 camelCase
/// （与 trending/weekly 的 snake_case 不同）；本 DTO 仅作为请求体使用，与后端保持一致。
struct ShareRepoRequest: Codable, Sendable {
    let repo: ShareRepoDTO
    let aiSummary: ShareAISummaryDTO
}

struct ShareRepoDTO: Codable, Sendable {
    let fullName: String
    let description: String?
    let language: String?
    let starsCount: Int
    let forksCount: Int
    let topics: [String]
    let homepage: String?
    let url: String
}

struct ShareTagDTO: Codable, Sendable {
    let name: String
    let confidence: Double?
}

struct ShareAISummaryDTO: Codable, Sendable {
    let oneLiner: String
    let summary: String
    let platforms: [String]
    let suitableFor: [String]
    let strengths: [String]
    let risks: [String]
    let suggestedTags: [ShareTagDTO]
}

// MARK: - 响应

/// `POST /api/v1/share` 200 响应里 envelope 的 `data` 部分。
///
/// 后端 Go 类型：`internal/model/share.go` `ShareCreateResponse`。
/// 字段命名 camelCase 与请求 body 一致（同款历史遗留）。
///
/// 字段说明：
/// - `shareUrl`：完整的分享页 URL（如 `https://starcat.ink/s/abc12345`）
/// - `shareId`：短 ID（用于后续重分享 / 撤回 / 统计；目前前端只展示 url，留着备用）
/// - `expiresAt`：过期时间 ISO8601 字符串；`nil` = **永不过期**（R-01 设计 §3.1）
/// - `createdAt`：创建时间 ISO8601 字符串
struct ShareCreateResponse: Codable, Sendable, Equatable {
    let shareUrl: String
    let shareId: String
    let expiresAt: String?
    let createdAt: String
}
