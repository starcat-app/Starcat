//
//  AIUsageEvent.swift
//  Starcat
//
//  AI 请求用量的本地持久化领域模型。只记录统计元数据，不保存请求与响应正文。
//

import Foundation
import GRDB

/// 面向用户的稳定功能维度。rawValue 会持久化，改名会破坏历史筛选，新增 case 可以兼容旧库。
enum AIUsageFeature: String, Codable, CaseIterable, Identifiable, Sendable {
    case rag
    case knowledgeIndexing = "knowledge_indexing"
    case semanticSearch = "semantic_search"
    case repoSummary = "repo_summary"
    case repoNote = "repo_note"
    case repoTags = "repo_tags"
    case repoGrouping = "repo_grouping"
    case repoChat = "repo_chat"
    case readmeTranslation = "readme_translation"
    case agent
    case mcp
    case unknown

    var id: String { rawValue }
}

enum AIUsageOperation: String, Codable, Sendable {
    case chat
    case embedding
}

enum AIUsageSource: String, Codable, CaseIterable, Sendable {
    /// Provider 返回的 usage，统计面板可以将其视为精确值。
    case provider
    /// Starcat 本地估算；当前采集链路不主动生成，保留给未来兼容无 usage Provider。
    case estimated
    /// Provider 未返回或流在 usage chunk 到达前中断。token 字段必须保持 nil。
    case unavailable
}

enum AIUsageStatus: String, Codable, CaseIterable, Sendable {
    case succeeded
    case failed
    case cancelled
}

enum AIUsageErrorCategory: String, Codable, Sendable {
    case authentication
    case rateLimit = "rate_limit"
    case payment
    case rejected
    case network
    case timeout
    case invalidResponse = "invalid_response"
    case unknown
}

/// 调用方传给底层 AI adapter 的归因信息。
/// `phase` 是功能内部的稳定阶段标识，例如 RAG 的 `planning` / `answer` / `title`。
struct AIUsageContext: Equatable, Sendable {
    var feature: AIUsageFeature
    var phase: String
    var correlationID: String? = nil

    static let unknown = AIUsageContext(feature: .unknown, phase: "unknown")
}

/// Provider 缺少 usage 时的本地估算结果；只携带统计数字，不保存 Prompt 或响应正文。
struct AIUsageTokenEstimate: Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
}

/// `ai_usage_events` 单行记录。
struct AIUsageEvent: Codable, FetchableRecord, PersistableRecord, Equatable, Identifiable, Sendable {
    static let databaseTableName = "ai_usage_events"

    var id: String
    var startedAt: Double
    var completedAt: Double
    var durationMs: Int
    var providerId: String
    var providerKind: String
    var model: String
    var feature: String
    var phase: String
    var operation: String
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var cachedInputTokens: Int?
    var cacheWriteInputTokens: Int? = nil
    var reasoningOutputTokens: Int?
    var itemCount: Int
    var usageSource: String
    var status: String
    var errorCategory: String?
    var correlationId: String?
    /// 费用与定价匹配信息在事件完成时冻结，后续目录更新不会重写历史记录。
    var estimatedCostUSD: Double? = nil
    var costSource: String? = nil
    var pricingModel: String? = nil
    var pricingRevision: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationMs = "duration_ms"
        case providerId = "provider_id"
        case providerKind = "provider_kind"
        case model, feature, phase, operation
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case itemCount = "item_count"
        case usageSource = "usage_source"
        case status, errorCategory = "error_category"
        case correlationId = "correlation_id"
        case estimatedCostUSD = "estimated_cost_usd"
        case costSource = "cost_source"
        case pricingModel = "pricing_model"
        case pricingRevision = "pricing_revision"
    }
}
