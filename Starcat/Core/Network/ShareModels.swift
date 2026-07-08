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
//
//  2026-06-12 修订（dong4j 发现「点击分享 → 响应解析失败：未能读取数据」）：
//  - 改回与 trending/weekly/wiki 同款做法：**显式 CodingKeys 映射 snake_case**，
//    ShareAPI 的 JSONEncoder/JSONDecoder 不再开 `.convertToSnakeCase` /
//    `.convertFromSnakeCase` 策略。
//  - 根因：`StarcatEnvelope` 顶层 `CodingKeys: case schemaVersion = "schema_version"`
//    与 decoder 的 `.convertFromSnakeCase` 策略冲突——策略会先把 JSON 里的
//    `schema_version` 转成 camelCase 的 `schemaVersion`，但 `StarcatEnvelope` 用
//    `CodingKey.stringValue == "schema_version"` 去容器里查 key，结果查不到，
//    抛 `keyNotFound`（即 UI 上看到的 "未能读取数据，因为数据丢失"）。
//  - TrendingAPI / WeeklyAPI 早就踩过这个坑，注释里明确写了「不要开
//    `.convertFromSnakeCase`」。本文件这次回滚到同款规范，避免再翻车。
//

import Foundation

// MARK: - 请求

/// 分享创建请求体（POST /api/v1/share 的 body）。
///
/// 字段命名：Swift 属性 camelCase（语言习惯）；与后端契约对齐的 snake_case 由
/// 各结构体的显式 `CodingKeys` 写死映射，**不依赖** JSONEncoder strategy（详见
/// 文件头 2026-06-12 修订注释）。
struct ShareRepoRequest: Codable, Sendable {
    let repo: ShareRepoDTO
    let aiSummary: ShareAISummaryDTO

    enum CodingKeys: String, CodingKey {
        case repo
        case aiSummary = "ai_summary"
    }
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

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case description
        case language
        case starsCount = "stars_count"
        case forksCount = "forks_count"
        case topics
        case homepage
        case url
    }
}

struct ShareTagDTO: Codable, Sendable {
    let name: String
    let confidence: Double?

    enum CodingKeys: String, CodingKey {
        case name
        case confidence
    }
}

struct ShareAISummaryDTO: Codable, Sendable {
    let oneLiner: String
    let summary: String
    let platforms: [String]
    let suitableFor: [String]
    let strengths: [String]
    let risks: [String]
    let suggestedTags: [ShareTagDTO]

    enum CodingKeys: String, CodingKey {
        case oneLiner = "one_liner"
        case summary
        case platforms
        case suitableFor = "suitable_for"
        case strengths
        case risks
        case suggestedTags = "suggested_tags"
    }
}

// MARK: - 响应

/// `POST /api/v1/share` 200 响应里 envelope 的 `data` 部分。
///
/// 后端 Go 类型：`internal/model/share.go` `ShareCreateResponse`。
/// 字段命名：Swift 属性 camelCase + 网络传输 snake_case，靠下方显式 `CodingKeys`
/// 映射（**不依赖** decoder 的 `.convertFromSnakeCase`，原因见文件头注释）。
///
/// 字段说明：
/// - `shareUrl`：完整的分享页 URL（如 `https://example.com/s/abc12345`，实际域名以后端返回为准）
/// - `shareId`：短 ID（用于后续重分享 / 撤回 / 统计；目前前端只展示 url，留着备用）
/// - `expiresAt`：过期时间 ISO8601 字符串；`nil` = **永不过期**（R-01 设计 §3.1）
/// - `createdAt`：创建时间 ISO8601 字符串
struct ShareCreateResponse: Codable, Sendable, Equatable {
    let shareUrl: String
    let shareId: String
    let expiresAt: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case shareUrl = "share_url"
        case shareId = "share_id"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}
