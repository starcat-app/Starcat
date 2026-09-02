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
    case firecrawl
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
        case .firecrawl:
            return "Firecrawl"
        }
    }

    /// Provider API Key 的本机加密存储命名空间。
    ///
    /// 使用新的 `external-search.*` 前缀，是为了避免通用服务 Key、AI Key 与搜索
    /// Provider Key 混在一起；这些 Key 明确不进入 CloudKit。
    var keychainServiceID: String {
        "external-search.\(rawValue)"
    }

    /// 是否支持匿名（keyless）访问。
    ///
    /// 统一从 `ExternalSearchCapabilities.capabilities(for:)` 派生，避免各处硬编码
    /// `provider == .anySearch || provider == .firecrawl`——新增支持匿名的 provider 时
    /// 只需在 capabilities 里声明 `supportsAnonymous: true`，无需逐个改 UI / Registry 判断。
    var supportsAnonymous: Bool {
        ExternalSearchCapabilities.capabilities(for: self).supportsAnonymous
    }

    /// Automatic External Context 的第一版固定优先级。
    static let automaticContextPriority: [ExternalSearchProviderID] = [
        .exa,
        .tavily,
        .braveLLMContext,
        .anySearch,
        .firecrawl
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
    case firecrawl

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
        case .firecrawl:
            return .firecrawl
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
        case .firecrawl:
            return .firecrawl
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
    /// 是否请求全文内容。目前仅 Firecrawl 使用：控制 `scrapeOptions.formats=["markdown"]`。
    /// 默认关闭——全文会触发每个结果的 scrape，显著变慢并消耗 credits。
    var fetchFullText: Bool

    init(
        isEnabled: Bool = false,
        anonymousMode: Bool = false,
        defaultMaxResults: Int = 10,
        credentialVerifiedAt: Date? = nil,
        fetchFullText: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.anonymousMode = anonymousMode
        self.defaultMaxResults = Self.clampMaxResults(defaultMaxResults)
        self.credentialVerifiedAt = credentialVerifiedAt
        self.fetchFullText = fetchFullText
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case anonymousMode
        case defaultMaxResults
        case credentialVerifiedAt
        case fetchFullText
    }

    /// 向后兼容：旧缓存没有 `fetchFullText`，decode 时缺省 false，不丢其它字段。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        self.anonymousMode = try container.decode(Bool.self, forKey: .anonymousMode)
        self.defaultMaxResults = Self.clampMaxResults(try container.decode(Int.self, forKey: .defaultMaxResults))
        self.credentialVerifiedAt = try container.decodeIfPresent(Date.self, forKey: .credentialVerifiedAt)
        self.fetchFullText = try container.decodeIfPresent(Bool.self, forKey: .fetchFullText) ?? false
    }

    var hasVerifiedCredential: Bool {
        credentialVerifiedAt != nil
    }

    static func defaultSettings(for provider: ExternalSearchProviderID) -> ExternalSearchProviderSettings {
        // 匿名能力由 capabilities 决定默认值：支持 keyless 的 provider 默认匿名开启。
        ExternalSearchProviderSettings(
            isEnabled: false,
            anonymousMode: provider.supportsAnonymous,
            defaultMaxResults: 10
        )
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
        case .firecrawl:
            return ExternalSearchCapabilities(
                supportsAnonymous: true,
                supportsFreshness: false,
                supportsDomainFilters: true,
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
    var freshness: String?
    var includeDomains: [String]
    var excludeDomains: [String]
    var anySearchFilters: AnySearchFilters?

    init(
        query: String,
        purpose: ExternalSearchPurpose,
        maxResults: Int = 10,
        freshness: String? = nil,
        includeDomains: [String] = [],
        excludeDomains: [String] = [],
        anySearchFilters: AnySearchFilters? = nil
    ) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.purpose = purpose
        self.maxResults = min(max(maxResults, 1), 100)
        self.freshness = freshness
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
            return String(format: String.l10n("externalSearch.error.disabledFormat"), provider.displayName)
        case .missingAPIKey(let provider):
            return String(format: String.l10n("externalSearch.error.missingAPIKeyFormat"), provider.displayName)
        case .unverifiedCredential(let provider):
            return String(format: String.l10n("externalSearch.error.unverifiedCredentialFormat"), provider.displayName)
        case .invalidCredential(let provider, _, _):
            return String(format: String.l10n("externalSearch.error.invalidCredentialFormat"), provider.displayName)
        case .paymentRequired(let provider, _, _):
            return String(format: String.l10n("externalSearch.error.paymentRequiredFormat"), provider.displayName)
        case .rateLimited(let provider, _, _):
            return String(format: String.l10n("externalSearch.error.rateLimitedFormat"), provider.displayName)
        case .serviceUnavailable(let provider, _, _):
            return String(format: String.l10n("externalSearch.error.serviceUnavailableFormat"), provider.displayName)
        case .network(let provider, _):
            return String(format: String.l10n("externalSearch.error.networkFormat"), provider.displayName)
        case .invalidResponse(let provider, _):
            return String(format: String.l10n("externalSearch.error.invalidResponseFormat"), provider.displayName)
        }
    }
}
