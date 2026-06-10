//
//  TrendingAPI.swift
//  Starcat
//
//  GitHub Trending REST API 客户端。
//
//  数据源：https://starcat-trending-api.fly.dev/repo
//
//  设计约束：
//  - 独立于 GitHubAPIClient，直接使用 URLSession（无需 GitHub token）
//  - 不走 Keychain/OAuth，单次请求独立完成
//  - 错误处理映射到 NetworkError
//

import Foundation

/// Trending API 网络错误。
enum TrendingAPIError: Error, LocalizedError {
    case invalidURL
    case transport(underlying: Error)
    case decodingError(underlying: Error)
    case serverError(message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "network.error.invalidURL")
        case .transport(let error):
            return String(format: String(localized: "network.error.transportFormat"), error.localizedDescription)
        case .decodingError(let error):
            return String(format: String(localized: "network.error.decodingFormat"), error.localizedDescription)
        case .serverError(let message):
            return message ?? String(localized: "network.error.serverGeneric")
        }
    }
}

/// GitHub Trending API 客户端。
///
/// 使用 URLSession 直接请求外部 Trending API，不需要 GitHub 认证。
actor TrendingAPI {

    // MARK: - Constants

    /// 请求超时时间
    private static let timeout: TimeInterval = 30

    // MARK: - Properties

    /// 当前 baseURL；通过 `updateBaseURL(_:)` 热更新（设置页改地址后立即生效）。
    /// actor 串行化保证写入与下一次 build URL 的读之间不会撕裂。
    private var baseURL: URL

    /// 当前 API Key（Bearer Token）；通过 `updateAPIKey(_:)` 热更新。
    /// R-01 v1.2 后端强制 Bearer Auth；nil 或空字符串 = 不带 Authorization 头（后端会 401）。
    /// 详细设计见 `StarcatAPIKey.swift` 顶部注释。
    private var apiKey: String?

    private let session: URLSession
    private let decoder: JSONDecoder

    // MARK: - Initialization

    /// - Parameters:
    ///   - baseURL: 后端域名；DI 装配处由 `AppDependencies` 从 `AppEndpoints.trending` 注入，
    ///     用户在设置页改地址后 `updateBaseURL(_:)` 热更新。
    ///   - apiKey: Bearer Token；DI 装配处由 `AppDependencies` 从 `StarcatAPIKeyResolver`
    ///     解析后注入；用户在设置页改 key 后 `updateAPIKey(_:)` 热更新。
    ///   - session: 注入自定义 URLSession（一般用于单测 mock）；为 nil 走默认配置。
    init(
        baseURL: URL,
        apiKey: String? = nil,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = Self.timeout
            config.timeoutIntervalForResource = Self.timeout
            self.session = URLSession(configuration: config)
        }

        // R-01 v1.2 后端走 envelope，所有响应 key 都用 snake_case，DTO 已用 CodingKeys 显式映射。
        // 不开 `.convertFromSnakeCase`，否则 JSONDecoder 会先把响应 key 转成 camelCase，
        // 反而匹配不到 `CodingKeys.fooBar = "foo_bar"`，导致线上响应解码失败。
        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    // MARK: - Public API

    /// 热更新 baseURL（用户在设置页改地址后由 `AppDependencies` 推送进来）。
    /// actor 串行化让 URL 切换无需重启 App。
    func updateBaseURL(_ url: URL) {
        AppLog.network.info("TrendingAPI baseURL updated to \(url.absoluteString, privacy: .public)")
        self.baseURL = url
    }

    /// 热更新 API Key（用户在设置页改 key 后由 `AppDependencies` 推送进来）。
    /// 出于日志安全考虑不打印 key 本体，只打 prefix。
    func updateAPIKey(_ key: String?) {
        let preview = key.flatMap { $0.isEmpty ? nil : String($0.prefix(7)) } ?? "<nil>"
        AppLog.network.info("TrendingAPI apiKey updated (prefix=\(preview, privacy: .public)****)")
        self.apiKey = key
    }

    /// 获取热门仓库列表。
    ///
    /// R-01 v1.2：响应改 envelope（`StarcatEnvelope<[StarcatRepoCardDTO]>`）。
    /// 内部仍把 DTO 转成 `TrendingRepo` UI 模型返回，让 ViewModel / GRDB 持久化层零改动。
    ///
    /// - Parameters:
    ///   - since: 时间周期（daily/weekly/monthly）
    ///   - language: 编程语言筛选（空字符串表示全部）
    /// - Returns: Trending 仓库数组（已从 DTO 转换为 UI 模型）
    func fetchTrending(
        since: TrendingPeriod,
        language: TrendingLanguage = .all
    ) async throws -> [TrendingRepo] {
        let url = try buildURL(since: since, language: language)
        let (data, response) = try await performRequestWithResponse(url: url)

        // envelope 解码 + schema_version warning + 401 / 4xx / 5xx 错误识别
        do {
            let cards = try StarcatEnvelopeDecoder.decode(
                [StarcatRepoCardDTO].self,
                data: data,
                response: response,
                decoder: decoder
            )
            return cards.map { TrendingRepo(card: $0, since: since) }
        } catch let error as StarcatEnvelopeNetworkError {
            // 把 envelope 错误翻译成本地的 TrendingAPIError，让 ViewModel 调用层零变更
            throw error.asTrendingAPIError
        }
    }

    // MARK: - Private

    private func buildURL(since: TrendingPeriod, language: TrendingLanguage) throws -> URL {
        let endpoint = AppEndpoints.appendPath(AppEndpoints.Trending.Paths.repos, to: baseURL)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = []

        queryItems.append(URLQueryItem(name: "since", value: since.apiValue))

        if !language.apiValue.isEmpty {
            queryItems.append(URLQueryItem(name: "lang", value: language.apiValue))
        }

        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw TrendingAPIError.invalidURL
        }

        return url
    }

    /// 走 GET + 注入 Bearer + 拿到 (data, response)，**不解析 status code**——
    /// 由 `StarcatEnvelopeDecoder.decode` 接管成功 / 错误判定（v1.2 后端非 2xx 也是 envelope）。
    ///
    /// 老的 `performRequest` / `validateResponse` 已合并到这里，因为 envelope 时代不再需要前端单独
    /// 把 4xx / 5xx 翻译成 TrendingAPIError —— envelope decoder 里能拿到 ErrorEnvelope 的 code+message。
    private func performRequestWithResponse(url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")

        // R-01 v1.2：后端强制 Bearer Auth；apiKey 为 nil/空时不发头（后端会 401，
        // 由 envelope 解码层翻译成 isUnauthorized 错误，UI 引导去设置页配置 key）。
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            return try await session.data(for: request)
        } catch {
            throw TrendingAPIError.transport(underlying: error)
        }
    }
}

// MARK: - Envelope 错误 → TrendingAPIError 翻译

private extension StarcatEnvelopeNetworkError {
    /// 把统一的 envelope 错误翻译成本地化的 TrendingAPIError，让 ViewModel 调用层零变更。
    /// R-01 v1.2 兼容措施：后续可考虑把 ViewModel 也直接用 StarcatEnvelopeNetworkError，省去本翻译。
    var asTrendingAPIError: TrendingAPIError {
        switch self {
        case .invalidURL:
            return .invalidURL
        case .transport(let err):
            return .transport(underlying: err)
        case .decoding(let err):
            return .decodingError(underlying: err)
        case .serverError(_, let code, let message):
            // 把 code + message 拼成可读的字符串塞 serverError，UI 直接展示
            if let code, !code.isEmpty {
                return .serverError(message: "[\(code)] \(message)")
            }
            return .serverError(message: message)
        }
    }
}
