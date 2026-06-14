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
            let results: [RawResult]?
            let metadata: AnySearchMetadata?
            // 错误 envelope（402 quota_exhausted）里 `data` 携带配额详情：
            // {"data": {"quota_limit": 1000, "quota_used": 1000, "quota_remaining": 0, "request_id": "..."}}
            // 成功响应里这些字段不存在，故全部 Optional。
            let quotaLimit: Int?
            let quotaUsed: Int?
            let quotaRemaining: Int?
            let retryAfter: Int?  // 429 envelope.data.retry_after
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
        // 空 query 不打网络，直接返回空响应。rateLimit 显式传 nil：未实际请求
        // 就没有"配额信息"语义，UI 也不会渲染 footer（webMetadata 一路 nil）。
        guard !request.query.isEmpty else {
            return AnySearchResponse(results: [], metadata: nil, rateLimit: nil)
        }
        do {
            return try await perform(request)
        } catch AnySearchError.serviceUnavailable {
            // 5xx 一次重试。新 typed case `.serviceUnavailable` 覆盖了大多数
            // 500/503 路径；原 `.server(statusCode:)` 仍作 default 兜底，下面
            // 单独捕获保持向后兼容（理论上 perform 改造后不再抛 .server）。
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

        // 不论 status 是 2xx / 4xx / 5xx 都先把 body 尝试解 envelope —— 4xx/5xx
        // envelope 里有精确的 message / code / quota 字段，是分类的关键信号。
        // 解析失败时 envelope 为 nil，后续走 HTTP status + statusCode 兜底。
        let envelope: Envelope? = try? JSONDecoder.anySearch.decode(Envelope.self, from: data)

        switch http.statusCode {
        case 200..<300:
            return try parseSuccessEnvelope(envelope, http: http, rawData: data)
        case 400:
            throw AnySearchError.invalidRequest(message: envelope?.message ?? "Invalid request")
        case 401:
            // 401 细分：默认 invalid，envelope message 含 "header" 关键字时归 malformedHeader
            // （官方 symbol 是 invalid_auth_header）。这是启发式判断，命中失败也仍然报
            // 「invalid」，对用户的引导文案差异很小（都让用户去设置页检查 Key）。
            let isMalformedHeader = envelope?.message.lowercased().contains("header") == true
            throw AnySearchError.invalidAPIKey(reason: isMalformedHeader ? .malformedHeader : .invalid)
        case 402:
            // 402 区分匿名/Bearer：匿名 → 引导绑 Key；Bearer → 引导升套餐。
            if anonymous {
                throw AnySearchError.anonymousQuotaExhausted
            } else {
                throw AnySearchError.keyQuotaExhausted(
                    limit: envelope?.data?.quotaLimit,
                    used: envelope?.data?.quotaUsed
                )
            }
        case 403:
            // 403 三种 symbol 用 message 启发式区分：
            // - "expired" → invalidAPIKey(.expired)
            // - "disabled" → accountDisabled
            // - 其余（如 private_capability_not_enabled）→ capabilityNotEnabled
            let message = envelope?.message ?? ""
            let lower = message.lowercased()
            if lower.contains("expired") {
                throw AnySearchError.invalidAPIKey(reason: .expired)
            } else if lower.contains("disabled") {
                throw AnySearchError.accountDisabled
            } else {
                throw AnySearchError.capabilityNotEnabled(message: message)
            }
        case 429:
            // 429 用 envelope message 区分账号级 / Key 级；retry-after 同时检查 HTTP
            // header（标准位置）与 envelope.data（API 自定义位置），后者作为 header 缺失时
            // 的 fallback。
            let isAccountScope = envelope?.message.lowercased().contains("user") == true ||
                envelope?.message.lowercased().contains("account") == true
            let scope: AnySearchError.RateLimitScope = isAccountScope ? .account : .key
            let retryFromHeader = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            let retryFromBody = envelope?.data?.retryAfter
            throw AnySearchError.rateLimited(scope: scope, retryAfter: retryFromHeader ?? retryFromBody)
        case 500...599:
            throw AnySearchError.serviceUnavailable(message: envelope?.message)
        default:
            throw AnySearchError.server(statusCode: http.statusCode)
        }
    }

    /// 2xx 路径专用 envelope 解析。
    /// envelope 解析失败 → `.decoding`（与原有行为一致）；envelope.code != 0 →
    /// `.api(code:message:)` 兜底（成功 HTTP 但业务错的边缘场景，理论上不会发生
    /// 但留 case 防御性兜底）。
    private func parseSuccessEnvelope(
        _ envelope: Envelope?,
        http: HTTPURLResponse,
        rawData: Data
    ) throws -> AnySearchResponse {
        guard let envelope else { throw AnySearchError.decoding }
        guard envelope.code == 0, let payload = envelope.data else {
            throw AnySearchError.api(code: envelope.code, message: envelope.message)
        }
        let results = (payload.results ?? []).compactMap { raw -> AnySearchResult? in
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
