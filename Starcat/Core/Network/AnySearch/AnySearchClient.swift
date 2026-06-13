//
//  AnySearchClient.swift
//  Starcat
//
//  AnySearch REST 客户端。匿名模式永不发送 Key；Bearer 模式若收到 401/403 会直接
//  报错，禁止静默降级为匿名，避免用户误以为高额度配置生效。
//

import Foundation

actor AnySearchClient: AnySearchClientProtocol {
    private struct Envelope: Decodable {
        struct Payload: Decodable {
            struct RawResult: Decodable {
                let title: String
                let url: URL
                let snippet: String?
                let content: String?
                let sourceDomain: String?
            }
            let results: [RawResult]
            let metadata: AnySearchMetadata?
        }
        let code: Int
        let message: String
        let data: Payload?
    }

    private let session: URLSession
    private let baseURL: URL
    private let apiKey: String?
    private let anonymous: Bool

    init(
        baseURL: URL = URL(string: "https://api.anysearch.com")!,
        apiKey: String?,
        anonymous: Bool,
        session: URLSession? = nil,
        timeout: TimeInterval = 12
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anonymous = anonymous
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout + 3
            self.session = URLSession(configuration: configuration)
        }
    }

    func search(_ request: AnySearchRequest) async throws -> AnySearchResponse {
        guard !request.query.isEmpty else { return AnySearchResponse(results: [], metadata: nil) }
        do {
            return try await perform(request)
        } catch AnySearchError.server {
            return try await perform(request)
        } catch AnySearchError.transport(let message) where message.contains("timed out") {
            return try await perform(request)
        }
    }

    private func perform(_ body: AnySearchRequest) async throws -> AnySearchResponse {
        guard let url = URL(string: "/v1/search", relativeTo: baseURL)?.absoluteURL else {
            throw AnySearchError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !anonymous, let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder.anySearch.encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AnySearchError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw AnySearchError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw AnySearchError.invalidAPIKey
        case 429: throw AnySearchError.rateLimited
        case 500...599: throw AnySearchError.server(statusCode: http.statusCode)
        default: throw AnySearchError.server(statusCode: http.statusCode)
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder.anySearch.decode(Envelope.self, from: data)
        } catch {
            throw AnySearchError.decoding
        }
        guard envelope.code == 0, let payload = envelope.data else {
            throw AnySearchError.api(code: envelope.code, message: envelope.message)
        }
        let results = payload.results.compactMap { raw -> AnySearchResult? in
            guard let normalized = Self.normalize(raw.url) else { return nil }
            return AnySearchResult(
                title: raw.title,
                url: raw.url,
                normalizedURL: normalized,
                snippet: raw.snippet,
                content: raw.content,
                sourceDomain: raw.sourceDomain ?? normalized.host
            )
        }
        return AnySearchResponse(
            results: results,
            metadata: payload.metadata,
            rateLimit: Self.parseRateLimit(from: http)
        )
    }

    /// 从 `HTTPURLResponse` 解析 `x-ratelimit-*` 三字段。
    ///
    /// 关键约束：
    /// - **三字段全在才返回非 nil**——AnySearch 在 200 响应里总是三个齐发，
    ///   缺一意味着上游格式变化或匿名访问的边缘情况，宁可降级为 nil 也不
    ///   返回半残数据让 UI 出现"剩余 0/0"这种误导性显示。
    /// - `HTTPURLResponse.value(forHTTPHeaderField:)` **大小写无关**（系统行为），
    ///   不论上游返回 `X-RateLimit-Limit` 还是 `x-ratelimit-limit` 都能命中。
    /// - `reset` 字段是 Unix 秒戳（不是毫秒、不是 ISO8601），见 `docs/需求讨论/
    ///   starcat-anysearch-integration-plan.md` §2 / 实测响应头。
    static func parseRateLimit(from response: HTTPURLResponse) -> AnySearchRateLimit? {
        guard
            let limitStr = response.value(forHTTPHeaderField: "x-ratelimit-limit"),
            let limit = Int(limitStr),
            let remainingStr = response.value(forHTTPHeaderField: "x-ratelimit-remaining"),
            let remaining = Int(remainingStr),
            let resetStr = response.value(forHTTPHeaderField: "x-ratelimit-reset"),
            let resetTs = TimeInterval(resetStr)
        else { return nil }
        return AnySearchRateLimit(
            limit: limit,
            remaining: remaining,
            resetAt: Date(timeIntervalSince1970: resetTs)
        )
    }

    static func normalize(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        let trackingNames = Set(["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "gclid", "fbclid"])
        components.queryItems = components.queryItems?.filter { !trackingNames.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }
}

private extension JSONEncoder {
    static let anySearch: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}

private extension JSONDecoder {
    static let anySearch: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
