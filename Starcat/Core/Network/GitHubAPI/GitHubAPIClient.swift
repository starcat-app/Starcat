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
