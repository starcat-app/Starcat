//
//  GitHubAPIClient.swift
//  Starcat
//
//  通用 GitHub REST API 客户端。
//
//  职责：
//  - 拼 URL（基于 AppConstants.githubAPIBaseURL）
//  - 注入 Authorization / Accept / User-Agent 头
//  - 解码 JSON
//  - 把 HTTP 状态码映射成 NetworkError
//  - 解析 Link 头与 Rate Limit 头，返回 APIResponse 让上层用
//
//  不在本类中做：
//  - 重试策略（由调用方决定）
//  - 业务端点拼装（在 StarsAPI / UserAPI / ...）
//  - Token 管理（由 TokenProvider 解耦，方便 Mock 注入）
//
//  线程模型：actor 串行化所有请求；URLSession 自身线程安全。
//

import Foundation

// MARK: - Token Provider

/// 鉴权 Token 提供者。
///
/// 抽象成协议是为了：
/// - 生产环境：从 Keychain 读
/// - 测试环境：直接返回固定字符串或 nil
/// - 未登录请求：返回 nil（如 Device Flow 起步阶段）
protocol GitHubTokenProviding: Sendable {
    func currentToken() async -> String?
}

/// 默认实现：从 KeychainManager 同步读。
struct KeychainTokenProvider: GitHubTokenProviding {
    func currentToken() async -> String? {
        try? KeychainManager.shared.loadGithubToken()
    }
}

// MARK: - Response

/// API 响应包装：业务数据 + 元数据（Link / RateLimit）。
struct APIResponse<T> {
    let value: T
    let linkHeader: LinkHeader
    let rateLimit: RateLimitInfo
    let statusCode: Int
}

/// 原始字节响应包装。
///
/// 用于不走 JSON 解码的端点（README HTML / Raw markdown / 二进制等）。
/// 携带 ETag / Last-Modified / 304 判定，由调用方决定缓存命中行为。
struct RawAPIResponse {
    /// 响应体字节。`notModified == true` 时为空。
    let data: Data
    /// 服务端返回的 ETag（含双引号，原样保存原样回传）。
    let etag: String?
    /// HTTP Last-Modified 头（RFC 1123 格式）。
    let lastModified: String?
    let statusCode: Int
    /// 命中 If-None-Match → 304 时为 true，调用方应使用本地缓存。
    let notModified: Bool
    let rateLimit: RateLimitInfo
}

// MARK: - Client

/// GitHub REST API 通用客户端。
actor GitHubAPIClient {

    // MARK: - 依赖

    private let baseURL: URL
    private let session: URLSession
    private let tokenProvider: any GitHubTokenProviding
    private let decoder: JSONDecoder

    // MARK: - 初始化

    init(
        baseURL: URL = AppConstants.githubAPIBaseURL,
        session: URLSession = .shared,
        tokenProvider: any GitHubTokenProviding = KeychainTokenProvider()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenProvider = tokenProvider

        let decoder = JSONDecoder()
        // GitHub 返回 snake_case，DTO 用 camelCase
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    // MARK: - Public API

    /// 发起 GET 请求并解码 JSON。
    /// - Parameter accept: 自定义 Accept 头（例如 Stars API 要 `application/vnd.github.star+json` 才返回 starred_at）。
    func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        accept: String = "application/vnd.github+json",
        as type: T.Type = T.self
    ) async throws -> APIResponse<T> {
        let request = try buildRequest(method: "GET", path: path, queryItems: queryItems, accept: accept, body: nil)
        return try await perform(request)
    }

    /// DELETE 请求，无返回值。
    func delete(path: String) async throws {
        let request = try buildRequest(method: "DELETE", path: path, queryItems: [], accept: "application/vnd.github+json", body: nil)
        let _: APIResponse<EmptyResponse> = try await perform(request, allowEmptyBody: true)
    }

    /// PUT 请求，无返回值。
    func put(path: String) async throws {
        let request = try buildRequest(method: "PUT", path: path, queryItems: [], accept: "application/vnd.github+json", body: nil)
        let _: APIResponse<EmptyResponse> = try await perform(request, allowEmptyBody: true)
    }

    /// 发起 GET 请求并返回原始字节，跳过 JSON 解码。
    ///
    /// 主要服务于 README HTML 端点（`Accept: application/vnd.github.html`）。
    /// - Parameters:
    ///   - path: 端点路径（如 `/repos/{owner}/{repo}/readme`）
    ///   - accept: Accept 头。README HTML 用 `application/vnd.github.html`
    ///   - ifNoneMatch: 上次响应保存的 ETag；若服务端未变化会返回 304
    ///   - ifModifiedSince: 上次响应保存的 Last-Modified；与 ifNoneMatch 等效，二选一即可
    /// - Returns: 字节 + ETag / Last-Modified / notModified 标志
    /// - Throws: 与 `get<T>` 同语义的 `NetworkError`（404 / 401 / RateLimit / 5xx）
    func getRaw(
        path: String,
        accept: String,
        ifNoneMatch: String? = nil,
        ifModifiedSince: String? = nil
    ) async throws -> RawAPIResponse {
        var request = try buildRequest(method: "GET", path: path, queryItems: [], accept: accept, body: nil)
        if let etag = ifNoneMatch, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let since = ifModifiedSince, !since.isEmpty {
            request.setValue(since, forHTTPHeaderField: "If-Modified-Since")
        }
        return try await performRaw(request)
    }

    // MARK: - Internal

    private func buildRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem],
        accept: String,
        body: Data?
    ) throws -> URLRequest {
        let pathPrefixed = path.hasPrefix("/") ? path : "/\(path)"
        let urlString = baseURL.absoluteString + pathPrefixed
        guard var components = URLComponents(string: urlString) else {
            throw NetworkError.invalidURL
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw NetworkError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.httpBody = body
        return request
    }

    /// 真正发起请求并按状态码处理。
    private func perform<T: Decodable>(
        _ request: URLRequest,
        allowEmptyBody: Bool = false
    ) async throws -> APIResponse<T> {
        var req = request

        // 鉴权：每次请求都拉一次 token，token 变更（重新登录）立刻生效
        if let token = await tokenProvider.currentToken(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch {
            // URLSession 取消会抛 NSError code = -999
            if (error as NSError).code == NSURLErrorCancelled {
                throw NetworkError.cancelled
            }
            AppLog.network.error("Transport error: \(error.localizedDescription, privacy: .public)")
            throw NetworkError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        let linkHeader = LinkHeader.parse(http.value(forHTTPHeaderField: "Link"))
        let rateLimit = RateLimitInfo.parse(http)

        AppLog.network.debug("\(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public) -> \(http.statusCode, privacy: .public), rl=\(rateLimit.remaining ?? -1, privacy: .public)/\(rateLimit.limit ?? -1, privacy: .public)")

        switch http.statusCode {
        case 200...299:
            if allowEmptyBody, data.isEmpty || T.self == EmptyResponse.self {
                // 强转：T 一定是 EmptyResponse 才会走到这
                let empty = EmptyResponse() as! T
                return APIResponse(value: empty, linkHeader: linkHeader, rateLimit: rateLimit, statusCode: http.statusCode)
            }
            do {
                let decoded = try decoder.decode(T.self, from: data)
                return APIResponse(value: decoded, linkHeader: linkHeader, rateLimit: rateLimit, statusCode: http.statusCode)
            } catch {
                AppLog.network.error("Decoding failed for \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw NetworkError.decodingError(underlying: error)
            }

        case 401:
            throw NetworkError.unauthorized

        case 403:
            // Rate Limit 用 403 + X-RateLimit-Remaining=0 表示
            if rateLimit.isExhausted {
                throw NetworkError.rateLimited(retryAfter: rateLimit.retryAfter())
            }
            // 否则按普通客户端错误
            throw NetworkError.clientError(statusCode: 403, message: extractErrorMessage(data))

        case 404:
            throw NetworkError.notFound

        case 400...499:
            throw NetworkError.clientError(statusCode: http.statusCode, message: extractErrorMessage(data))

        case 500...599:
            throw NetworkError.serverError(statusCode: http.statusCode)

        default:
            throw NetworkError.invalidResponse
        }
    }

    /// 发起原始字节请求（不解码 JSON），处理 304 / 401 / 404 / Rate Limit / 5xx。
    ///
    /// 与 `perform<T>` 的差异：
    /// - 不做 JSON 解码
    /// - 把 304 翻译为 `RawAPIResponse(notModified: true)` 而非抛错（调用方需要这个语义来命中缓存）
    /// - 200 时直接返回 data
    private func performRaw(_ request: URLRequest) async throws -> RawAPIResponse {
        var req = request

        if let token = await tokenProvider.currentToken(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch {
            if (error as NSError).code == NSURLErrorCancelled {
                throw NetworkError.cancelled
            }
            AppLog.network.error("Transport error (raw): \(error.localizedDescription, privacy: .public)")
            throw NetworkError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        let rateLimit = RateLimitInfo.parse(http)
        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")

        AppLog.network.debug("GET-raw \(req.url?.path ?? "?", privacy: .public) -> \(http.statusCode, privacy: .public), bytes=\(data.count, privacy: .public)")

        switch http.statusCode {
        case 200...299:
            return RawAPIResponse(
                data: data,
                etag: etag,
                lastModified: lastModified,
                statusCode: http.statusCode,
                notModified: false,
                rateLimit: rateLimit
            )

        case 304:
            // 命中 If-None-Match → 服务端未变化，body 为空，调用方应使用本地缓存
            return RawAPIResponse(
                data: Data(),
                etag: etag,
                lastModified: lastModified,
                statusCode: 304,
                notModified: true,
                rateLimit: rateLimit
            )

        case 401:
            throw NetworkError.unauthorized

        case 403:
            if rateLimit.isExhausted {
                throw NetworkError.rateLimited(retryAfter: rateLimit.retryAfter())
            }
            throw NetworkError.clientError(statusCode: 403, message: extractErrorMessage(data))

        case 404:
            throw NetworkError.notFound

        case 400...499:
            throw NetworkError.clientError(statusCode: http.statusCode, message: extractErrorMessage(data))

        case 500...599:
            throw NetworkError.serverError(statusCode: http.statusCode)

        default:
            throw NetworkError.invalidResponse
        }
    }

    /// 从错误响应体提取人类可读的 message（GitHub 错误格式：`{"message": "...", "documentation_url": "..."}`）。
    private func extractErrorMessage(_ data: Data) -> String? {
        guard !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["message"] as? String
    }
}

/// 空响应占位（用于 DELETE / PUT 等无 body 的端点）。
struct EmptyResponse: Decodable {}
