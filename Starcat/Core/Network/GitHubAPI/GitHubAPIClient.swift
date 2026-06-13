//
//  GitHubAPIClient.swift
//  Starcat
//
//  通用 GitHub REST API 客户端。
//
//  职责：
//  - 拼 URL（基于 AppEndpoints.GitHubREST.baseURL）
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

/// API 响应包装：业务数据 + 元数据（Link / RateLimit / ETag）。
///
/// W4-4 C2 新增 `etag`：服务端返回的 ETag（含双引号原样保留），
/// 上层将其与 If-None-Match 配套使用做条件请求。
/// 304 响应不会构造 APIResponse —— 会通过 `NetworkError.notModified(etag:)` 抛出。
struct APIResponse<T> {
    let value: T
    let linkHeader: LinkHeader
    let rateLimit: RateLimitInfo
    let statusCode: Int
    let etag: String?
}

/// 裸字节响应包装。
///
/// 用于不走 JSON 解码的端点（README HTML / 原始 markdown / 二进制等）。
/// 携带 ETag / Last-Modified / 304 判定，由调用方决定缓存命中行为。
///
/// 命名注意：Phase 2 改名（原 `RawAPIResponse` → `BytesResponse`）。
/// 原 `Raw` 在 GitHub 语境里容易与 `Accept: application/vnd.github.raw`（原始 markdown）
/// 混淆，而我们的 README 实际拿的是 `Accept: application/vnd.github.html`（已渲染 HTML）。
/// `Bytes` 更准确表达"不解码 JSON 的字节响应"。
struct BytesResponse {
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

    /// 集中式 401 回调。
    ///
    /// 任何请求被映射成 401（含 403 鉴权失败）时触发一次，由 `AppDependencies` 接线到
    /// `AuthSession.invalidateSession()`，实现"使用中 token 失效 → 自动回登录页"。
    /// actor 隔离，通过 `setUnauthorizedHandler` 在依赖装配阶段异步设置。
    private var onUnauthorized: (@Sendable () -> Void)?

    // MARK: - 初始化

    init(
        baseURL: URL = AppEndpoints.GitHubREST.baseURL,
        session: URLSession? = nil,
        tokenProvider: any GitHubTokenProviding = KeychainTokenProvider()
    ) {
        self.baseURL = baseURL
        // 默认 session 必须挂 `GitHubAuthRedirectDelegate`（D-25 防自动登出）。
        // 不能用 `URLSession.shared`：单例不接受 delegate，301 重定向时会丢
        // Authorization → 后续 401 被误判为 token 失效 → 自动登出。
        // 测试侧通过 URLProtocolStub.ephemeralSession() 显式注入 session，
        // 不会走到 makeDefaultSession()。
        self.session = session ?? Self.makeDefaultSession()
        self.tokenProvider = tokenProvider

        let decoder = JSONDecoder()
        // GitHub 返回 snake_case，DTO 用 camelCase
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    /// 构造生产侧默认 URLSession：挂 `GitHubAuthRedirectDelegate` 处理
    /// GitHub 301 重定向时丢 Authorization 的坑（D-25）。
    private static func makeDefaultSession() -> URLSession {
        URLSession(
            configuration: .default,
            delegate: GitHubAuthRedirectDelegate(),
            delegateQueue: nil
        )
    }

    // MARK: - 集中式 401 处理

    /// 设置 401 回调（依赖装配阶段调用一次）。
    func setUnauthorizedHandler(_ handler: @escaping @Sendable () -> Void) {
        self.onUnauthorized = handler
    }

    /// 统一的"抛 401"出口：先触发集中式回调，再返回 `.unauthorized`。
    ///
    /// 所有 `perform*` 方法里映射出 401 的分支都走这里，保证回调只有一个出口、不会漏触发也不会重复实现。
    private func unauthorized() -> NetworkError {
        onUnauthorized?()
        return .unauthorized
    }

    // MARK: - Public API

    /// 发起 GET 请求并解码 JSON。
    /// - Parameters:
    ///   - accept: 自定义 Accept 头（例如 Stars API 要 `application/vnd.github.star+json` 才返回 starred_at）。
    ///   - ifNoneMatch: W4-4 C2，条件请求 ETag。命中(304) 时 perform 抛 `NetworkError.notModified(etag:)`。
    func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        accept: String = "application/vnd.github+json",
        ifNoneMatch: String? = nil,
        as type: T.Type = T.self
    ) async throws -> APIResponse<T> {
        var request = try buildRequest(method: "GET", path: path, queryItems: queryItems, accept: accept, body: nil)
        if let etag = ifNoneMatch, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return try await perform(request)
    }

    /// DELETE 请求，无返回值。
    /// D-03：改走 `performNoBody`，避免原 `perform<T>` 用 `EmptyResponse() as! T` 强转的类型不安全路径。
    func delete(path: String) async throws {
        let request = try buildRequest(method: "DELETE", path: path, queryItems: [], accept: "application/vnd.github+json", body: nil)
        try await performNoBody(request)
    }

    /// PUT 请求，无返回值。
    /// D-03：改走 `performNoBody`，理由同 `delete(path:)`。
    func put(path: String) async throws {
        let request = try buildRequest(method: "PUT", path: path, queryItems: [], accept: "application/vnd.github+json", body: nil)
        try await performNoBody(request)
    }

    /// PUT 请求，带 Body 和 返回值
    func put<T: Encodable, U: Decodable>(
        path: String,
        body: T,
        as type: U.Type = U.self
    ) async throws -> APIResponse<U> {
        let bodyData = try JSONEncoder().encode(body)
        let request = try buildRequest(method: "PUT", path: path, queryItems: [], accept: "application/vnd.github+json", body: bodyData)
        return try await perform(request)
    }

    /// 发起 GraphQL POST 请求（HOM-PROFILE 2026-06-05 引入）。
    ///
    /// 设计动机：GitHub 贡献草坪数据只能通过 GraphQL `contributionsCollection.contributionCalendar`
    /// 拿到，REST API 不暴露。我们不想引入 Apollo 或重型 GraphQL client：单一查询场景下，
    /// 手写 `{ "query": "...", "variables": {...} }` JSON 体 + 让上层解码 `{ data: T }` 包装更直接。
    ///
    /// 路径写死 `/graphql`，base URL 沿用 REST 的 `https://api.github.com`。
    /// - Parameters:
    ///   - query: GraphQL 查询字符串（多行 raw string 即可）
    ///   - variables: 变量字典；只接受 JSONSerialization 兼容类型（String/Int/Bool/[String: Any]/[Any]）
    ///   - type: 顶层期望解码类型；返回的真实 JSON 是 `{ "data": T, "errors": [...] }`，
    ///     本方法自动剥 `data` 包装，failure 时把 `errors[].message` 拼成 `NetworkError.clientError`。
    /// - Returns: 解码后的 `T`（已剥 `data` 包装）
    /// - Throws: 与 REST `perform` 同语义的 `NetworkError`；GraphQL 业务错误归入 `clientError(400)`
    ///
    /// 关键约束：GraphQL 始终 POST 到 `/graphql`，与 REST 的 GET 端点不同；
    /// 返回的 `errors` 数组即使 HTTP 200 也代表查询失败（GraphQL 业务错误约定）。
    func graphql<T: Decodable>(
        query: String,
        variables: [String: Any] = [:],
        as type: T.Type = T.self
    ) async throws -> T {
        // GraphQL 请求体格式：{ "query": "...", "variables": {...} }。
        // 用 JSONSerialization 而不是 Encodable，因为 variables 是异构字典（值类型混合）。
        var bodyDict: [String: Any] = ["query": query]
        if !variables.isEmpty {
            bodyDict["variables"] = variables
        }
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict, options: [])

        var request = try buildRequest(
            method: "POST",
            path: AppEndpoints.GitHubREST.Paths.graphql,
            queryItems: [],
            accept: "application/json",
            body: bodyData
        )
        // GraphQL 端点必须显式设 Content-Type，否则 GitHub 返回 400。
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let envelope: APIResponse<GraphQLEnvelope<T>> = try await perform(request)

        if let errs = envelope.value.errors, !errs.isEmpty {
            let combined = errs.map(\.message).joined(separator: "; ")
            AppLog.network.error("GraphQL errors: \(combined, privacy: .public)")
            throw NetworkError.clientError(statusCode: 400, message: combined)
        }
        guard let payload = envelope.value.data else {
            throw NetworkError.invalidResponse
        }
        return payload
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
    func getBytes(
        path: String,
        accept: String,
        ifNoneMatch: String? = nil,
        ifModifiedSince: String? = nil
    ) async throws -> BytesResponse {
        var request = try buildRequest(method: "GET", path: path, queryItems: [], accept: accept, body: nil)
        if let etag = ifNoneMatch, !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let since = ifModifiedSince, !since.isEmpty {
            request.setValue(since, forHTTPHeaderField: "If-Modified-Since")
        }
        return try await performBytes(request)
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
    ///
    /// D-03：移除原 `allowEmptyBody` 参数及 `as! T` 强转路径。DELETE / PUT 等无 body 端点
    /// 改走 `performNoBody`，本函数只服务"有响应 body 需要 JSON 解码"的场景。
    private func perform<T: Decodable>(
        _ request: URLRequest
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
        let etag = http.value(forHTTPHeaderField: "ETag")

        AppLog.network.debug("\(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public) -> \(http.statusCode, privacy: .public), rl=\(rateLimit.remaining ?? -1, privacy: .public)/\(rateLimit.limit ?? -1, privacy: .public)")

        switch http.statusCode {
        case 200...299:
            do {
                let decoded = try decoder.decode(T.self, from: data)
                return APIResponse(value: decoded, linkHeader: linkHeader, rateLimit: rateLimit, statusCode: http.statusCode, etag: etag)
            } catch {
                AppLog.network.error("Decoding failed for \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
                throw NetworkError.decodingError(underlying: error)
            }

        case 304:
            // W4-4 C2：条件请求命中。把 ETag 透传给上层做缓存判断；body 为空所以不能构造 APIResponse<T>。
            throw NetworkError.notModified(etag: etag)

        case 401:
            throw unauthorized()

        case 403:
            // 双重校验：只有当 rate limit 确实耗尽 AND 响应消息确实是 rate limit 相关，才按 rate limit 处理。
            // 原因：未登录/无效 token 时 GitHub 可能对某些 API 返回 403 + X-RateLimit-Remaining: 0，
            // 此时错误消息通常是 "Forbidden" 而不是 "rate limit"，应按认证失败处理。
            let errorMessage = extractErrorMessage(data) ?? ""
            if rateLimit.isExhausted && errorMessage.lowercased().contains("rate limit") {
                throw NetworkError.rateLimited(retryAfter: rateLimit.retryAfter())
            }
            // 403 + remaining > 0：其他客户端错误（如 ACL 禁止）
            // 403 + remaining = 0 但消息不含 "rate limit"：认证失败（未登录 / token 无效 / 权限不足）
            if rateLimit.remaining != 0 {
                throw NetworkError.clientError(statusCode: 403, message: errorMessage.isEmpty ? nil : errorMessage)
            }
            throw unauthorized()

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

    /// 发起裸字节请求（不解码 JSON），处理 304 / 401 / 404 / Rate Limit / 5xx。
    ///
    /// 与 `perform<T>` 的差异：
    /// - 不做 JSON 解码
    /// - 把 304 翻译为 `BytesResponse(notModified: true)` 而非抛错（调用方需要这个语义来命中缓存）
    /// - 200 时直接返回 data
    private func performBytes(_ request: URLRequest) async throws -> BytesResponse {
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
            AppLog.network.error("Transport error (bytes): \(error.localizedDescription, privacy: .public)")
            throw NetworkError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        let rateLimit = RateLimitInfo.parse(http)
        let etag = http.value(forHTTPHeaderField: "ETag")
        let lastModified = http.value(forHTTPHeaderField: "Last-Modified")

        AppLog.network.debug("GET-bytes \(req.url?.path ?? "?", privacy: .public) -> \(http.statusCode, privacy: .public), bytes=\(data.count, privacy: .public)")

        switch http.statusCode {
        case 200...299:
            return BytesResponse(
                data: data,
                etag: etag,
                lastModified: lastModified,
                statusCode: http.statusCode,
                notModified: false,
                rateLimit: rateLimit
            )

        case 304:
            // 命中 If-None-Match → 服务端未变化，body 为空，调用方应使用本地缓存
            return BytesResponse(
                data: Data(),
                etag: etag,
                lastModified: lastModified,
                statusCode: 304,
                notModified: true,
                rateLimit: rateLimit
            )

        case 401:
            throw unauthorized()

        case 403:
            // 双重校验：只有当 rate limit 确实耗尽 AND 响应消息确实是 rate limit 相关，才按 rate limit 处理。
            // 原因：未登录/无效 token 时 GitHub 可能对某些 API 返回 403 + X-RateLimit-Remaining: 0，
            // 此时错误消息通常是 "Forbidden" 而不是 "rate limit"，应按认证失败处理。
            let errorMessage = extractErrorMessage(data) ?? ""
            if rateLimit.isExhausted && errorMessage.lowercased().contains("rate limit") {
                throw NetworkError.rateLimited(retryAfter: rateLimit.retryAfter())
            }
            // 403 + remaining > 0：其他客户端错误（如 ACL 禁止）
            // 403 + remaining = 0 但消息不含 "rate limit"：认证失败（未登录 / token 无效 / 权限不足）
            if rateLimit.remaining != 0 {
                throw NetworkError.clientError(statusCode: 403, message: errorMessage.isEmpty ? nil : errorMessage)
            }
            throw unauthorized()

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

    /// 发起无响应 body 的请求（DELETE / PUT 等 GitHub API），处理 401 / 403 / 404 / Rate Limit / 5xx。
    ///
    /// D-03：替代原 `perform<T>(allowEmptyBody:)` 路径，避免 `EmptyResponse() as! T` 强转。
    /// 与 `perform<T>` 的差异：不做 JSON 解码，2xx 直接 return；其余状态码错误映射与 `perform<T>` 一致。
    ///
    /// 重复代码说明：本函数与 `perform<T>` / `performBytes` 在 token 注入 / URLSession / 错误处理
    /// 三段上有重复，**本次按 "Surgical Changes" 不抽取**；若未来又新增第 4 种 perform 变体，
    /// 应优先抽取 `executeRequest(_:)` 共享前置层（单独 D-?? 重构项）。
    private func performNoBody(_ request: URLRequest) async throws {
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
            AppLog.network.error("Transport error (no-body): \(error.localizedDescription, privacy: .public)")
            throw NetworkError.transport(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        let rateLimit = RateLimitInfo.parse(http)
        AppLog.network.debug("\(req.httpMethod ?? "?", privacy: .public) \(req.url?.path ?? "?", privacy: .public) -> \(http.statusCode, privacy: .public), rl=\(rateLimit.remaining ?? -1, privacy: .public)/\(rateLimit.limit ?? -1, privacy: .public)")

        switch http.statusCode {
        case 200...299:
            return // 无 body，成功即返回

        case 401:
            throw unauthorized()

        case 403:
            // 双重校验：只有当 rate limit 确实耗尽 AND 响应消息确实是 rate limit 相关，才按 rate limit 处理。
            // 原因：未登录/无效 token 时 GitHub 可能对某些 API 返回 403 + X-RateLimit-Remaining: 0，
            // 此时错误消息通常是 "Forbidden" 而不是 "rate limit"，应按认证失败处理。
            let errorMessage = extractErrorMessage(data) ?? ""
            if rateLimit.isExhausted && errorMessage.lowercased().contains("rate limit") {
                throw NetworkError.rateLimited(retryAfter: rateLimit.retryAfter())
            }
            // 403 + remaining > 0：其他客户端错误（如 ACL 禁止）
            // 403 + remaining = 0 但消息不含 "rate limit"：认证失败（未登录 / token 无效 / 权限不足）
            if rateLimit.remaining != 0 {
                throw NetworkError.clientError(statusCode: 403, message: errorMessage.isEmpty ? nil : errorMessage)
            }
            throw unauthorized()

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

// EmptyResponse 已删（D-03）：原用于 perform<T> 强转 `EmptyResponse() as! T` 占位，
// 现 DELETE / PUT 走 performNoBody 不再需要。

// MARK: - GraphQL Envelope

/// GraphQL 响应包装层（HOM-PROFILE 2026-06-05 引入）。
///
/// GitHub GraphQL 端点（POST /graphql）即使 HTTP 200 也可能返回 `errors` 数组，
/// 调用方需要先剥 `data` 再判 `errors`。挪到文件顶层而非 `graphql<T>` 方法局部，
/// 是因为 Swift 不支持在方法体内声明含泛型参数的嵌套类型（actor 隔离 + generic
/// 局部 struct 会编译报错 "Generic parameters cannot be ..."）。
struct GraphQLEnvelope<T: Decodable>: Decodable {
    let data: T?
    let errors: [GraphQLError]?
}

struct GraphQLError: Decodable {
    let message: String
}
