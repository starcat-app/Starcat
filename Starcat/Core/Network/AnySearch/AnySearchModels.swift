//
//  AnySearchModels.swift
//  Starcat
//
//  AnySearch REST API 的请求、响应与错误模型。
//

import Foundation

struct AnySearchRequest: Codable, Hashable, Sendable {
    let query: String
    let maxResults: Int
    let domain: String?
    let tag: String?
    let contentTypes: [String]?
    let zone: String?
    let language: String?
    let params: [String: String]?

    init(
        query: String,
        maxResults: Int = 10,
        domain: String? = "code",
        tag: String? = nil,
        contentTypes: [String]? = ["web", "doc", "news"],
        zone: String? = nil,
        language: String? = nil,
        params: [String: String]? = nil
    ) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxResults = min(max(1, maxResults), 100)
        self.domain = domain
        self.tag = tag
        self.contentTypes = contentTypes
        self.zone = zone
        self.language = language
        self.params = params
    }
}

struct AnySearchResponse: Codable, Equatable, Sendable {
    let results: [AnySearchResult]
    let metadata: AnySearchMetadata?
    /// HTTP 层的限流元信息（来自 `x-ratelimit-*` header，不在 JSON envelope 内）。
    /// 三字段缺一不全 → nil（健壮容错，见 `AnySearchClient.perform`）。
    ///
    /// **持久化语义**：磁盘缓存写盘前需要把本字段清成 nil —— rateLimit 是"本次请求时刻"
    /// 的快照（remaining 是当时余量、resetAt 是当时定的下次重置时间），读出旧 cache 时
    /// 这些数字早已过期，再回填给 UI 会显示"剩余 -3 / 重置时间已过去 2 小时"等假数字。
    /// 由 `DiskAnySearchCache` 在 save 路径上清空。
    let rateLimit: AnySearchRateLimit?
}

struct AnySearchResult: Identifiable, Codable, Hashable, Sendable {
    var id: String { normalizedURL.absoluteString }
    let title: String
    let url: URL
    let normalizedURL: URL
    let snippet: String?
    let content: String?
    let sourceDomain: String?
}

struct AnySearchMetadata: Codable, Equatable, Sendable {
    let requestId: String?
    let totalResults: Int?
    let searchTimeMs: Int?
}

/// HTTP `x-ratelimit-*` 响应头的结构化表示。
///
/// 来源：AnySearch 网关每次成功响应（200 系列）都会返回
/// - `x-ratelimit-limit`：当前窗口总额度
/// - `x-ratelimit-remaining`：当前窗口剩余次数
/// - `x-ratelimit-reset`：Unix 秒戳，下次配额重置时间
///
/// 注意：
/// - 该结构**不参与 JSON envelope 解码**，由 `AnySearchClient` 从
///   `HTTPURLResponse` header 单独读取并注入。
/// - 429 错误响应理论上也带 reset header，但当前 client 抛 `.rateLimited`
///   时未携带，v2 再扩展（见 `docs/详细设计/28-搜索增强最终方案.md`）。
struct AnySearchRateLimit: Codable, Equatable, Sendable {
    let limit: Int
    let remaining: Int
    let resetAt: Date
}

/// AnySearch 错误。
///
/// **分类策略（dong4j 2026-06-14 拍板）**：按 HTTP status 大类做 typed case，
/// envelope `message` 字段（API 端的人类可读文案，已经本地化为请求语言）作为
/// 细节透传。不依赖官方 envelope `code` 的数字编码（如 `40202`）—— 文档未明
/// 确编码规则，避免 API 升级时大量改动。
///
/// **关键映射**（对照 https://www.anysearch.com/docs 错误码表）：
///
/// | HTTP | API symbol                              | Case                            |
/// |------|-----------------------------------------|---------------------------------|
/// | 400  | invalid_request                         | `.invalidRequest(message:)`     |
/// | 401  | invalid_api_key / invalid_auth_header   | `.invalidAPIKey(.invalid/.malformedHeader)` |
/// | 402  | daily_free_quota_exhausted (anon)       | `.anonymousQuotaExhausted`      |
/// | 402  | quota_exhausted / user_daily_quota_*    | `.keyQuotaExhausted(...)`       |
/// | 403  | expired_api_key                         | `.invalidAPIKey(.expired)`      |
/// | 403  | account_disabled                        | `.accountDisabled`              |
/// | 403  | private_capability_not_enabled          | `.capabilityNotEnabled(message:)` |
/// | 429  | rate_limit_exceeded(_user)              | `.rateLimited(scope:, retryAfter:)` |
/// | 500/503 | internal_error / *_unavailable / ... | `.serviceUnavailable(message:)` |
/// | 其余 | 兜底                                     | `.api(code:message:)` / `.server(statusCode:)` |
///
/// **匿名 vs Bearer 区分**：402 错误在两种模式下文案差异大（匿名 → 引导绑 Key；
/// Bearer → 引导升套餐），所以 `AnySearchClient.perform` 拿到 402 时必须感知
/// 当前 `anonymous` 标志才能选对 case。
enum AnySearchError: Error, LocalizedError, Equatable {
    case disabled
    case invalidURL

    /// 400 类请求错误（query 为空 / domain 非法 / content_types 非法等）。
    /// `message` 来自 envelope，已是用户语言。
    case invalidRequest(message: String)

    /// 401 / 403 expired_api_key。`reason` 区分细分原因，UI 用来选不同文案：
    /// - `.invalid`：Key 字符串无效 / 不存在 / 被禁用 → 引导用户重新粘贴
    /// - `.malformedHeader`：Authorization header 格式错（不是 `Bearer xxx`） → 一般是代码 bug，理论不会触发
    /// - `.expired`：Key 已过期 → 引导用户去 console 续费 / 换 Key
    case invalidAPIKey(reason: KeyFailReason)

    /// 403 account_disabled —— 账号整个被封，换 Key 也没用，必须联系 support。
    case accountDisabled

    /// 403 private_capability_not_enabled —— 请求了未对当前 Key 开放的 domain /
    /// 能力。`message` 来自 envelope，指出具体哪个能力。
    case capabilityNotEnabled(message: String)

    /// 402 + 当前是匿名模式 —— 当日 IP 级免费配额耗尽。
    /// UI 应引导用户去设置页绑定 API Key 提额。
    case anonymousQuotaExhausted

    /// 402 + 当前是 Bearer 模式 —— Key / 账号付费配额或当日免费配额耗尽。
    /// `limit / used` 来自 envelope `data` 字段；缺失时为 nil。
    case keyQuotaExhausted(limit: Int?, used: Int?)

    /// 429 —— 请求过于频繁。
    /// `scope` 区分账号级（所有 Key 合计）vs Key 级；`retryAfter` 来自 HTTP
    /// `Retry-After` header（单位：秒），缺失时为 nil。
    case rateLimited(scope: RateLimitScope, retryAfter: Int?)

    /// 500 / 502 / 503 / 504 —— 服务端临时性异常，建议重试。`message` 来自
    /// envelope 或 statusCode 兜底，UI 用来给"内部错误 / 配额检查失败"等差异化提示。
    case serviceUnavailable(message: String?)

    /// 仍保留原 `.server(statusCode:)`，作为前述 typed case 都没命中的兜底。
    case server(statusCode: Int)

    case invalidResponse
    case api(code: Int, message: String)
    case decoding
    case transport(String)

    enum KeyFailReason: Equatable, Sendable {
        case invalid
        case malformedHeader
        case expired
    }

    enum RateLimitScope: Equatable, Sendable {
        case key      // rate_limit_exceeded
        case account  // rate_limit_exceeded_user
    }

    var errorDescription: String? {
        switch self {
        case .disabled:
            return String(localized: "anySearch.error.disabled")
        case .invalidURL:
            return String(localized: "anySearch.error.invalidURL")
        case .invalidRequest(let message):
            return String(format: String(localized: "anySearch.error.invalidRequestFormat"), message)
        case .invalidAPIKey(let reason):
            switch reason {
            case .invalid: return String(localized: "anySearch.error.apiKey.invalid")
            case .malformedHeader: return String(localized: "anySearch.error.apiKey.malformedHeader")
            case .expired: return String(localized: "anySearch.error.apiKey.expired")
            }
        case .accountDisabled:
            return String(localized: "anySearch.error.accountDisabled")
        case .capabilityNotEnabled(let message):
            return String(format: String(localized: "anySearch.error.capabilityNotEnabledFormat"), message)
        case .anonymousQuotaExhausted:
            return String(localized: "anySearch.error.anonymousQuotaExhausted")
        case .keyQuotaExhausted(let limit, let used):
            if let limit, let used {
                return String(format: String(localized: "anySearch.error.keyQuotaExhaustedFormat"), used, limit)
            }
            return String(localized: "anySearch.error.keyQuotaExhausted")
        case .rateLimited(_, let retryAfter):
            if let retryAfter {
                return String(format: String(localized: "anySearch.error.rateLimitedFormat"), retryAfter)
            }
            return String(localized: "anySearch.error.rateLimited")
        case .serviceUnavailable(let message):
            if let message {
                return String(format: String(localized: "anySearch.error.serviceUnavailableFormat"), message)
            }
            return String(localized: "anySearch.error.serviceUnavailable")
        case .server(let code):
            return String(format: String(localized: "anySearch.error.serverFormat"), code)
        case .invalidResponse:
            return String(localized: "anySearch.error.invalidResponse")
        case .api(_, let message):
            return message
        case .decoding:
            return String(localized: "anySearch.error.decoding")
        case .transport(let message):
            return message
        }
    }
}

protocol AnySearchClientProtocol: Sendable {
    func search(_ request: AnySearchRequest) async throws -> AnySearchResponse
}
