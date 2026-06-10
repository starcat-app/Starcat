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
//  R-01 P1-3b 修订（2026-06-10）：
//  - sharing-api 后端 JSON tag 全量改 snake_case（与 trending/weekly 风格一致）
//  - Swift 属性名保持 camelCase（语言习惯不变）
//  - 序列化转换由 ShareAPI actor 的 JSONEncoder/JSONDecoder 设
//    `keyEncodingStrategy = .convertToSnakeCase` / `keyDecodingStrategy = .convertFromSnakeCase`
//    统一处理，本文件无需写 CodingKeys
//

import Foundation

// MARK: - 请求

/// 分享创建请求体（POST /api/v1/share 的 body）。
///
/// 字段命名：Swift 属性名走 camelCase（语言习惯），网络传输时由 ShareAPI 的
/// `keyEncodingStrategy = .convertToSnakeCase` 自动转 snake_case 与后端契约对齐。
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
/// 字段命名：Swift 属性 camelCase + 网络传输 snake_case，由 ShareAPI 的
/// `keyDecodingStrategy = .convertFromSnakeCase` 自动转换（详见文件头 P1-3b 注释）。
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
