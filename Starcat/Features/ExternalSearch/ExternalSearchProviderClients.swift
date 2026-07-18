//
//  ExternalSearchProviderClients.swift
//  Starcat
//
//  External Search Provider 的 HTTP 接入层。
//
//  这里把 Tavily / Exa / Brave LLM Context / AnySearch 统一适配成
//  `ExternalSearchProvider`。Provider 原始 DTO 仅在本文件内使用，避免上游 API 字段
//  扩散到 SearchCenter、AI prompt 或缓存层。
//

import Foundation

/// External Search HTTP 基础能力。
///
/// 该类型只负责 URLRequest、JSON 编解码和 HTTP 错误分类；是否启用、是否有 Key、
/// request purpose 是否允许缓存等业务判断由各 Provider 包装器执行。
struct ExternalSearchHTTPClient: Sendable {
    let session: URLSession
    let timeout: TimeInterval

    init(session: URLSession? = nil, timeout: TimeInterval = 12) {
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout + 3
            self.session = URLSession(configuration: configuration)
        }
    }

    func perform<Response: Decodable>(
        _ request: URLRequest,
        provider: ExternalSearchProviderID,
        decoder: JSONDecoder = .externalSearch
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ExternalSearchError.network(provider: provider, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ExternalSearchError.invalidResponse(provider: provider, message: "Missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTPError(provider: provider, http: http, body: data)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw ExternalSearchError.invalidResponse(provider: provider, message: error.localizedDescription)
        }
    }

    static func mapHTTPError(
        provider: ExternalSearchProviderID,
        http: HTTPURLResponse,
        body: Data
    ) -> ExternalSearchError {
        let message = decodeErrorMessage(from: body)
        switch http.statusCode {
        case 401, 403:
            return .invalidCredential(provider: provider, statusCode: http.statusCode, message: message)
        case 402:
            return .paymentRequired(provider: provider, statusCode: http.statusCode, message: message)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(provider: provider, retryAfter: retryAfter, message: message)
        case 500...599:
            return .serviceUnavailable(provider: provider, statusCode: http.statusCode, message: message)
        default:
            return .invalidResponse(
                provider: provider,
                message: message ?? "HTTP \(http.statusCode)"
            )
        }
    }

    private static func decodeErrorMessage(from body: Data) -> String? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return nil
        }
        if let detail = object["detail"] as? String { return detail }
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String { return message }
            if let code = error["code"] as? String { return code }
        }
        return nil
    }
}

/// AnySearch 的 External Search 适配器。
struct AnySearchExternalSearchProvider: ExternalSearchProvider {
    let id: ExternalSearchProviderID = .anySearch
    let capabilities = ExternalSearchCapabilities.capabilities(for: .anySearch)

    private let apiKey: String?
    private let anonymous: Bool
    private let isEnabled: Bool
    private let client: @Sendable (String?, Bool) -> any AnySearchClientProtocol

    init(
        apiKey: String?,
        anonymous: Bool,
        isEnabled: Bool,
        client: @escaping @Sendable (String?, Bool) -> any AnySearchClientProtocol = { apiKey, anonymous in
            AnySearchClient(apiKey: apiKey, anonymous: anonymous)
        }
    ) {
        self.apiKey = apiKey
        self.anonymous = anonymous
        self.isEnabled = isEnabled
        self.client = client
    }

    func search(_ request: ExternalSearchRequest) async throws -> ExternalSearchResponse {
        guard isEnabled else { throw ExternalSearchError.disabled(provider: id) }
        guard anonymous || apiKey?.isEmpty == false else {
            throw ExternalSearchError.missingAPIKey(provider: id)
        }
        let response: AnySearchResponse
        do {
            response = try await client(apiKey, anonymous).search(anySearchRequest(from: request))
        } catch {
            throw Self.mapAnySearchError(error)
        }
        return ExternalSearchResponse(
            hits: response.results.map(Self.mapAnySearchResult),
            metadata: ExternalSearchMetadata(
                provider: id,
                requestID: response.metadata?.requestId,
                totalResults: response.metadata?.totalResults,
                searchTimeMs: response.metadata?.searchTimeMs
            )
        )
    }

    private func anySearchRequest(from request: ExternalSearchRequest) -> AnySearchRequest {
        let filters = request.anySearchFilters
        return AnySearchRequest(
            query: request.query,
            maxResults: request.maxResults,
            domain: filters?.domain ?? request.includeDomains.first,
            contentTypes: filters?.contentTypes.isEmpty == false ? Array(filters!.contentTypes).sorted() : nil,
            zone: filters?.zone?.rawValue,
            language: Locale.current.language.languageCode?.identifier
        )
    }

    private static func mapAnySearchResult(_ result: AnySearchResult) -> ExternalSearchHit {
        ExternalSearchHit(
            id: result.normalizedURL.absoluteString,
            title: result.title,
            url: result.normalizedURL,
            snippet: result.snippet,
            extractedText: result.content
        )
    }

    private static func mapAnySearchError(_ error: Error) -> ExternalSearchError {
        guard let anySearch = error as? AnySearchError else {
            return .network(provider: .anySearch, message: error.localizedDescription)
        }
        switch anySearch {
        case .disabled:
            return .disabled(provider: .anySearch)
        case .invalidAPIKey, .accountDisabled, .capabilityNotEnabled:
            return .invalidCredential(provider: .anySearch, statusCode: nil, message: anySearch.localizedDescription)
        case .anonymousQuotaExhausted, .keyQuotaExhausted:
            return .paymentRequired(provider: .anySearch, statusCode: 402, message: anySearch.localizedDescription)
        case .rateLimited(_, let retryAfter):
            return .rateLimited(provider: .anySearch, retryAfter: retryAfter.map(TimeInterval.init), message: anySearch.localizedDescription)
        case .serviceUnavailable, .server:
            return .serviceUnavailable(provider: .anySearch, statusCode: nil, message: anySearch.localizedDescription)
        case .transport:
            return .network(provider: .anySearch, message: anySearch.localizedDescription)
        case .invalidURL, .invalidRequest, .invalidResponse, .api, .decoding:
            return .invalidResponse(provider: .anySearch, message: anySearch.localizedDescription)
        }
    }
}

/// Tavily Search Provider。
struct TavilySearchProvider: ExternalSearchProvider {
    let id: ExternalSearchProviderID = .tavily
    let capabilities = ExternalSearchCapabilities.capabilities(for: .tavily)

    private let apiKey: String?
    private let isEnabled: Bool
    private let baseURL: URL
    private let http: ExternalSearchHTTPClient

    init(
        apiKey: String?,
        isEnabled: Bool,
        baseURL: URL = URL(string: "https://api.tavily.com")!,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.http = ExternalSearchHTTPClient(session: session)
    }

    func search(_ request: ExternalSearchRequest) async throws -> ExternalSearchResponse {
        guard isEnabled else { throw ExternalSearchError.disabled(provider: id) }
        guard let apiKey, !apiKey.isEmpty else { throw ExternalSearchError.missingAPIKey(provider: id) }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("search"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder.externalSearch.encode(TavilyRequest(from: request))
        let response: TavilyResponse = try await http.perform(urlRequest, provider: id)
        return response.externalSearchResponse(provider: id)
    }
}

/// Exa Search Provider。
struct ExaSearchProvider: ExternalSearchProvider {
    let id: ExternalSearchProviderID = .exa
    let capabilities = ExternalSearchCapabilities.capabilities(for: .exa)

    private let apiKey: String?
    private let isEnabled: Bool
    private let baseURL: URL
    private let http: ExternalSearchHTTPClient

    init(
        apiKey: String?,
        isEnabled: Bool,
        baseURL: URL = URL(string: "https://api.exa.ai")!,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.http = ExternalSearchHTTPClient(session: session)
    }

    func search(_ request: ExternalSearchRequest) async throws -> ExternalSearchResponse {
        guard isEnabled else { throw ExternalSearchError.disabled(provider: id) }
        guard let apiKey, !apiKey.isEmpty else { throw ExternalSearchError.missingAPIKey(provider: id) }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("search"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.httpBody = try JSONEncoder.externalSearch.encode(ExaRequest(from: request))
        let response: ExaResponse = try await http.perform(urlRequest, provider: id)
        return response.externalSearchResponse(provider: id)
    }
}

/// Brave LLM Context Provider。
struct BraveLLMContextSearchProvider: ExternalSearchProvider {
    let id: ExternalSearchProviderID = .braveLLMContext
    let capabilities = ExternalSearchCapabilities.capabilities(for: .braveLLMContext)

    private let apiKey: String?
    private let isEnabled: Bool
    private let baseURL: URL
    private let http: ExternalSearchHTTPClient

    init(
        apiKey: String?,
        isEnabled: Bool,
        baseURL: URL = URL(string: "https://api.search.brave.com/res/v1/llm/context")!,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.http = ExternalSearchHTTPClient(session: session)
    }

    func search(_ request: ExternalSearchRequest) async throws -> ExternalSearchResponse {
        guard isEnabled else { throw ExternalSearchError.disabled(provider: id) }
        guard let apiKey, !apiKey.isEmpty else { throw ExternalSearchError.missingAPIKey(provider: id) }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "q", value: Self.domainScopedQuery(for: request)),
            URLQueryItem(name: "count", value: "\(min(max(request.maxResults, 1), 50))"),
            URLQueryItem(name: "maximum_number_of_urls", value: "\(min(max(request.maxResults, 1), 50))"),
            URLQueryItem(name: "enable_source_metadata", value: "true")
        ]
        if let freshness = Self.braveFreshness(request.freshness) {
            queryItems.append(URLQueryItem(name: "freshness", value: freshness))
        }
        components.queryItems = queryItems
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        let response: BraveLLMContextResponse = try await http.perform(urlRequest, provider: id)
        return response.externalSearchResponse(provider: id)
    }

    /// Brave LLM Context 不提供独立 domain allowlist 参数；将 allowlist 收窄为标准
    /// `site:` 查询，保证 Agent 声明的来源边界不会被静默忽略。
    private static func domainScopedQuery(for request: ExternalSearchRequest) -> String {
        guard !request.includeDomains.isEmpty else { return request.query }
        let domains = request.includeDomains.map { "site:\($0)" }.joined(separator: " OR ")
        return "\(request.query) (\(domains))"
    }

    private static func braveFreshness(_ freshness: String?) -> String? {
        switch freshness {
        case "day": return "pd"
        case "week": return "pw"
        case "month": return "pm"
        case "year": return "py"
        default: return nil
        }
    }
}

// MARK: - Tavily DTO

private struct TavilyRequest: Encodable {
    let query: String
    let searchDepth: String
    let maxResults: Int
    let includeRawContent: Bool
    let includeDomains: [String]?
    let excludeDomains: [String]?
    let timeRange: String?

    init(from request: ExternalSearchRequest) {
        self.query = request.query
        self.searchDepth = "basic"
        self.maxResults = min(request.maxResults, 20)
        self.includeRawContent = true
        self.includeDomains = request.includeDomains.isEmpty ? nil : request.includeDomains
        self.excludeDomains = request.excludeDomains.isEmpty ? nil : request.excludeDomains
        self.timeRange = request.freshness
    }
}

private struct TavilyResponse: Decodable {
    struct Result: Decodable {
        let title: String?
        let url: URL
        let content: String?
        let rawContent: String?
        let score: Double?
    }

    let results: [Result]
    let responseTime: Double?
    let requestId: String?

    func externalSearchResponse(provider: ExternalSearchProviderID) -> ExternalSearchResponse {
        ExternalSearchResponse(
            hits: results.map { result in
                ExternalSearchHit(
                    title: result.title ?? result.url.host ?? result.url.absoluteString,
                    url: result.url,
                    snippet: result.content,
                    extractedText: result.rawContent,
                    score: result.score
                )
            },
            metadata: ExternalSearchMetadata(
                provider: provider,
                requestID: requestId,
                totalResults: results.count,
                searchTimeMs: responseTime.map { Int($0 * 1000) }
            )
        )
    }
}

// MARK: - Exa DTO

private struct ExaRequest: Encodable {
    struct Contents: Encodable {
        let text: Bool
        let highlights: Bool
        let summary: Bool
    }

    let query: String
    let numResults: Int
    let includeDomains: [String]?
    let excludeDomains: [String]?
    let startPublishedDate: String?
    let contents: Contents

    init(from request: ExternalSearchRequest) {
        self.query = request.query
        self.numResults = request.maxResults
        self.includeDomains = request.includeDomains.isEmpty ? nil : request.includeDomains
        self.excludeDomains = request.excludeDomains.isEmpty ? nil : request.excludeDomains
        self.startPublishedDate = Self.startDate(for: request.freshness)
        self.contents = Contents(text: true, highlights: true, summary: true)
    }

    /// Exa 使用绝对 ISO 8601 时间，而 Agent 暴露相对时间窗口；转换在 Provider DTO
    /// 内完成，避免把 Exa 字段泄漏进统一请求模型。
    private static func startDate(for freshness: String?) -> String? {
        let days: Int
        switch freshness {
        case "day": days = 1
        case "week": days = 7
        case "month": days = 31
        case "year": days = 365
        default: return nil
        }
        guard let date = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: Date()) else {
            return nil
        }
        return ISO8601DateFormatter.shared.string(from: date)
    }
}

private struct ExaResponse: Decodable {
    struct Result: Decodable {
        let id: String?
        let title: String?
        let url: URL
        let publishedDate: Date?
        let text: String?
        let highlights: [String]?
        let summary: String?
        let highlightScores: [Double]?
    }

    let results: [Result]
    let requestId: String?

    func externalSearchResponse(provider: ExternalSearchProviderID) -> ExternalSearchResponse {
        ExternalSearchResponse(
            hits: results.map { result in
                ExternalSearchHit(
                    id: result.id,
                    title: result.title ?? result.url.host ?? result.url.absoluteString,
                    url: result.url,
                    snippet: result.summary ?? result.highlights?.first,
                    extractedText: result.text,
                    publishedAt: result.publishedDate,
                    score: result.highlightScores?.first
                )
            },
            metadata: ExternalSearchMetadata(provider: provider, requestID: requestId, totalResults: results.count)
        )
    }
}

// MARK: - Brave DTO

private struct BraveLLMContextResponse: Decodable {
    struct Source: Decodable {
        let title: String?
        let url: URL?
        let siteName: String?
    }

    struct Grounding: Decodable {
        let generic: [Generic]?
    }

    struct Generic: Decodable {
        let title: String?
        let url: URL?
        let snippets: [Snippet]?
    }

    struct Snippet: Decodable {
        let text: String?
        let content: String?
        let snippet: String?

        private enum CodingKeys: String, CodingKey {
            case text
            case content
            case snippet
        }

        init(from decoder: Decoder) throws {
            if let container = try? decoder.singleValueContainer(),
               let text = try? container.decode(String.self) {
                self.text = text
                self.content = nil
                self.snippet = nil
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.text = try container.decodeIfPresent(String.self, forKey: .text)
            self.content = try container.decodeIfPresent(String.self, forKey: .content)
            self.snippet = try container.decodeIfPresent(String.self, forKey: .snippet)
        }
    }

    let grounding: Grounding?
    let sources: [String: Source]?

    func externalSearchResponse(provider: ExternalSearchProviderID) -> ExternalSearchResponse {
        let genericHits = grounding?.generic?.compactMap { item -> ExternalSearchHit? in
            guard let url = item.url else { return nil }
            let snippets = item.snippets?.compactMap { $0.text ?? $0.content ?? $0.snippet } ?? []
            return ExternalSearchHit(
                title: item.title ?? sources?[url.absoluteString]?.title ?? url.host ?? url.absoluteString,
                url: url,
                snippet: snippets.first,
                extractedText: snippets.joined(separator: "\n\n")
            )
        } ?? []

        let sourceHits: [ExternalSearchHit] = (sources ?? [:]).compactMap { key, source in
            guard let url = source.url ?? URL(string: key) else { return nil }
            return ExternalSearchHit(
                title: source.title ?? source.siteName ?? url.host ?? url.absoluteString,
                url: url,
                snippet: nil,
                extractedText: nil
            )
        }

        return ExternalSearchResponse(
            hits: genericHits.isEmpty ? sourceHits : genericHits,
            metadata: ExternalSearchMetadata(provider: provider, totalResults: genericHits.isEmpty ? sourceHits.count : genericHits.count)
        )
    }
}

private extension JSONEncoder {
    static let externalSearch: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let externalSearch: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ISO8601DateFormatter.externalSearchDate(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(raw)")
        }
        return decoder
    }()
}

private extension ISO8601DateFormatter {
    static func externalSearchDate(from raw: String) -> Date? {
        externalSearchWithFractionalSeconds.date(from: raw) ?? externalSearchWithoutFractionalSeconds.date(from: raw)
    }

    private static var externalSearchWithFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static var externalSearchWithoutFractionalSeconds: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }
}
