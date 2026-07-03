//
//  ExternalSearchModels.swift
//  Starcat
//
//  Starcat 外部搜索服务的领域模型。
//
//  本文件只定义 Starcat 内部稳定语义，不直接暴露 Tavily / Exa / Brave /
//  AnySearch 的原始 DTO。这样 SearchCenter、AI External Context、缓存和设置页
//  都依赖同一套抽象，后续替换 provider 时不会把上游字段扩散到产品层。
//

import Foundation

/// Starcat 支持的外部搜索 Provider。
enum ExternalSearchProviderID: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case anySearch = "anysearch"
    case tavily
    case exa
    case braveLLMContext = "brave-llm-context"

    var id: String { rawValue }

    /// 设置页和日志里使用的短名称。
    var displayName: String {
        switch self {
        case .anySearch:
            return "AnySearch"
        case .tavily:
            return "Tavily"
        case .exa:
            return "Exa"
        case .braveLLMContext:
            return "Brave LLM Context"
        }
    }

    /// Provider API Key 的本机加密存储命名空间。
    ///
    /// 使用新的 `external-search.*` 前缀，是为了避免通用服务 Key、AI Key 与搜索
    /// Provider Key 混在一起；这些 Key 明确不进入 CloudKit。
    var keychainServiceID: String {
        "external-search.\(rawValue)"
    }

    /// Automatic External Context 的第一版固定优先级。
    static let automaticContextPriority: [ExternalSearchProviderID] = [
        .exa,
        .tavily,
        .braveLLMContext,
        .anySearch
    ]
}

/// 外部搜索请求目的。
///
/// `credentialTest` 必须绕过业务缓存、历史和用量计数，因为它是设置页连通性检测，
/// 不是用户的一次真实搜索。
enum ExternalSearchPurpose: String, Codable, Sendable {
    case globalSearch
    case aiContext
    case credentialTest
}

/// AI External Context 的 Provider 选择方式。
enum ExternalContextProviderSelection: String, Codable, Hashable, Sendable {
    case automatic
    case anySearch
    case tavily
    case exa
    case braveLLMContext = "brave-llm-context"

    var explicitProviderID: ExternalSearchProviderID? {
        switch self {
        case .automatic:
            return nil
        case .anySearch:
            return .anySearch
        case .tavily:
            return .tavily
        case .exa:
            return .exa
        case .braveLLMContext:
            return .braveLLMContext
        }
    }

    static func provider(_ id: ExternalSearchProviderID) -> ExternalContextProviderSelection {
        switch id {
        case .anySearch:
            return .anySearch
        case .tavily:
            return .tavily
        case .exa:
            return .exa
        case .braveLLMContext:
            return .braveLLMContext
        }
    }
}

/// 单个 Provider 的本机设置。
///
/// `credentialVerifiedAt` 只表示本机最近一次 Test 成功；用户编辑或删除 Key 后必须清空。
/// AnySearch 的匿名模式不需要该标记，但 bearer mode 与其它 Provider 一样需要验证。
struct ExternalSearchProviderSettings: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var anonymousMode: Bool
    var defaultMaxResults: Int
    var credentialVerifiedAt: Date?

    init(
        isEnabled: Bool = false,
        anonymousMode: Bool = false,
        defaultMaxResults: Int = 10,
        credentialVerifiedAt: Date? = nil
    ) {
        self.isEnabled = isEnabled
        self.anonymousMode = anonymousMode
        self.defaultMaxResults = Self.clampMaxResults(defaultMaxResults)
        self.credentialVerifiedAt = credentialVerifiedAt
    }

    var hasVerifiedCredential: Bool {
        credentialVerifiedAt != nil
    }

    static func defaultSettings(for provider: ExternalSearchProviderID) -> ExternalSearchProviderSettings {
        switch provider {
        case .anySearch:
            return ExternalSearchProviderSettings(isEnabled: false, anonymousMode: true, defaultMaxResults: 10)
        case .tavily, .exa, .braveLLMContext:
            return ExternalSearchProviderSettings(isEnabled: false, anonymousMode: false, defaultMaxResults: 10)
        }
    }

    static func defaultsByProvider() -> [ExternalSearchProviderID: ExternalSearchProviderSettings] {
        Dictionary(uniqueKeysWithValues: ExternalSearchProviderID.allCases.map { provider in
            (provider, defaultSettings(for: provider))
        })
    }

    private static func clampMaxResults(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }
}

/// Provider 的能力声明，供 UI 和请求构造判断可展示的筛选项。
struct ExternalSearchCapabilities: Equatable, Sendable {
    var supportsAnonymous: Bool
    var supportsFreshness: Bool
    var supportsDomainFilters: Bool
    var supportsExtractedText: Bool

    static func capabilities(for provider: ExternalSearchProviderID) -> ExternalSearchCapabilities {
        switch provider {
        case .anySearch:
            return ExternalSearchCapabilities(
                supportsAnonymous: true,
                supportsFreshness: false,
                supportsDomainFilters: true,
                supportsExtractedText: true
            )
        case .tavily:
            return ExternalSearchCapabilities(
                supportsAnonymous: false,
                supportsFreshness: true,
                supportsDomainFilters: true,
                supportsExtractedText: true
            )
        case .exa:
            return ExternalSearchCapabilities(
                supportsAnonymous: false,
                supportsFreshness: true,
                supportsDomainFilters: true,
                supportsExtractedText: true
            )
        case .braveLLMContext:
            return ExternalSearchCapabilities(
                supportsAnonymous: false,
                supportsFreshness: true,
                supportsDomainFilters: false,
                supportsExtractedText: true
            )
        }
    }
}

/// Provider 无关的搜索请求。
struct ExternalSearchRequest: Codable, Equatable, Sendable {
    var query: String
    var purpose: ExternalSearchPurpose
    var maxResults: Int
    var includeDomains: [String]
    var excludeDomains: [String]
    var anySearchFilters: AnySearchFilters?

    init(
        query: String,
        purpose: ExternalSearchPurpose,
        maxResults: Int = 10,
        includeDomains: [String] = [],
        excludeDomains: [String] = [],
        anySearchFilters: AnySearchFilters? = nil
    ) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.purpose = purpose
        self.maxResults = min(max(maxResults, 1), 100)
        self.includeDomains = includeDomains
        self.excludeDomains = excludeDomains
        self.anySearchFilters = anySearchFilters
    }
}

/// Provider 无关的单条搜索命中。
struct ExternalSearchHit: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var url: URL
    var snippet: String?
    var extractedText: String?
    var publishedAt: Date?
    var score: Double?

    init(
        id: String? = nil,
        title: String,
        url: URL,
        snippet: String? = nil,
        extractedText: String? = nil,
        publishedAt: Date? = nil,
        score: Double? = nil
    ) {
        self.id = id ?? url.absoluteString
        self.title = title
        self.url = url
        self.snippet = snippet
        self.extractedText = extractedText
        self.publishedAt = publishedAt
        self.score = score
    }
}

/// Provider 响应元信息。
struct ExternalSearchMetadata: Codable, Equatable, Sendable {
    var provider: ExternalSearchProviderID
    var requestID: String?
    var totalResults: Int?
    var searchTimeMs: Int?
    var fetchedAt: Date

    init(
        provider: ExternalSearchProviderID,
        requestID: String? = nil,
        totalResults: Int? = nil,
        searchTimeMs: Int? = nil,
        fetchedAt: Date = Date()
    ) {
        self.provider = provider
        self.requestID = requestID
        self.totalResults = totalResults
        self.searchTimeMs = searchTimeMs
        self.fetchedAt = fetchedAt
    }
}

/// Provider 无关的搜索响应。
struct ExternalSearchResponse: Codable, Equatable, Sendable {
    var hits: [ExternalSearchHit]
    var metadata: ExternalSearchMetadata

    init(hits: [ExternalSearchHit], metadata: ExternalSearchMetadata) {
        self.hits = hits
        self.metadata = metadata
    }
}

/// Provider 统一协议。
protocol ExternalSearchProvider: Sendable {
    var id: ExternalSearchProviderID { get }
    var capabilities: ExternalSearchCapabilities { get }

    func search(_ request: ExternalSearchRequest) async throws -> ExternalSearchResponse
}

/// 外部搜索统一错误模型。
enum ExternalSearchError: LocalizedError, Equatable, Sendable {
    case disabled(provider: ExternalSearchProviderID)
    case missingAPIKey(provider: ExternalSearchProviderID)
    case unverifiedCredential(provider: ExternalSearchProviderID)
    case invalidCredential(provider: ExternalSearchProviderID, statusCode: Int?, message: String?)
    case paymentRequired(provider: ExternalSearchProviderID, statusCode: Int?, message: String?)
    case rateLimited(provider: ExternalSearchProviderID, retryAfter: TimeInterval?, message: String?)
    case serviceUnavailable(provider: ExternalSearchProviderID, statusCode: Int?, message: String?)
    case network(provider: ExternalSearchProviderID, message: String)
    case invalidResponse(provider: ExternalSearchProviderID, message: String)

    var errorDescription: String? {
        friendlyMessage
    }

    var providerID: ExternalSearchProviderID {
        switch self {
        case .disabled(let provider),
             .missingAPIKey(let provider),
             .unverifiedCredential(let provider),
             .invalidCredential(let provider, _, _),
             .paymentRequired(let provider, _, _),
             .rateLimited(let provider, _, _),
             .serviceUnavailable(let provider, _, _),
             .network(let provider, _),
             .invalidResponse(let provider, _):
            return provider
        }
    }

    /// 设置页和 SearchCenter 使用的友好文案。
    var friendlyMessage: String {
        switch self {
        case .disabled(let provider):
            return "\(provider.displayName) is disabled."
        case .missingAPIKey(let provider):
            return "\(provider.displayName) requires an API key."
        case .unverifiedCredential(let provider):
            return "Test the \(provider.displayName) API key before enabling this provider."
        case .invalidCredential(let provider, _, _):
            return "\(provider.displayName) API key is invalid or lacks permission."
        case .paymentRequired(let provider, _, _):
            return "\(provider.displayName) quota or plan is unavailable."
        case .rateLimited(let provider, _, _):
            return "\(provider.displayName) is rate limited. Try again later."
        case .serviceUnavailable(let provider, _, _):
            return "\(provider.displayName) is temporarily unavailable."
        case .network(let provider, _):
            return "Could not connect to \(provider.displayName). Check the network and try again."
        case .invalidResponse(let provider, _):
            return "\(provider.displayName) returned an unreadable response."
        }
    }
}
