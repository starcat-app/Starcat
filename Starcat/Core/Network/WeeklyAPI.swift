//
//  WeeklyAPI.swift
//  Starcat
//
//  阮一峰周刊后端 API 客户端。
//
//  数据源：starcat-weekly-api（独立 Go 服务）
//  契约：见 https://github.com/dong4j/starcat-weekly-api 的 README，与
//  本文件配套设计。
//
//  设计约束：
//  - 与 `TrendingAPI` 保持同款 actor + URLSession 风格，不引第三方 HTTP 库；
//  - 不需要 GitHub OAuth，独立 URLSession，错误映射到 `WeeklyAPIError`；
//  - baseURL 默认指向生产域名（fly.io），允许构造时覆盖以便单测 / Preview 注入。
//

import Foundation

/// Weekly API 网络错误。
enum WeeklyAPIError: Error, LocalizedError {
    case invalidURL
    case transport(underlying: Error)
    case decodingError(underlying: Error)
    case serverError(message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String.l10n("network.error.invalidURL")
        case .transport(let error):
            return String(format: String.l10n("network.error.transportFormat"), error.localizedDescription)
        case .decodingError(let error):
            return String(format: String.l10n("network.error.decodingFormat"), error.localizedDescription)
        case .serverError(let message):
            return message ?? String.l10n("network.error.serverGeneric")
        }
    }
}

/// 三源聚合 Weekly feed 后端 API 客户端。
///
/// 用 `actor` 隔离 URLSession + JSONDecoder 的并发访问；公共方法是 async，
/// 与 TrendingAPI 完全一致，方便 ViewModel 同一种 await 风格调用。
actor WeeklyAPI {

    // MARK: - Constants

    /// 列表请求超时；后端首次启动时会 git clone ruanyf/weekly（可能数十秒），
    /// 但这只影响 `/internal/sync/weekly`，正常列表查询是本地 SQLite 命中，30s 充裕。
    private static let timeout: TimeInterval = 30

    /// 默认每页大小，与 R-05 设计默认请求保持一致。
    static let defaultPageSize: Int = 30

    /// 只有 Weekly bulk 已升级到 schema v2；不能提高全局 envelope 上限，否则会把
    /// 其他自建服务尚未适配的 v2 响应误判为完全支持。
    private static let supportedBulkSchemaVersion = 2

    // MARK: - Properties

    /// 当前 baseURL；通过 `updateBaseURL(_:)` 热更新（设置页改地址后立即生效）。
    /// 之所以是 `var`：用户在 ServicesSettingsTab 改地址会触发 `AppDependencies`
    /// 调本 actor 的 `updateBaseURL`，actor 串行化保证写入与下一次 build URL 的读
    /// 之间不会撕裂。
    private var baseURL: URL

    /// 当前 API Key（Bearer Token）；通过 `updateAPIKey(_:)` 热更新。
    /// R-01 v1.2 后端强制 Bearer Auth；nil 或空字符串 = 不带 Authorization 头（后端会 401）。
    private var apiKey: String?

    private let session: URLSession
    private let decoder: JSONDecoder

    // MARK: - Initialization

    /// - Parameters:
    ///   - baseURL: 后端域名；DI 装配处由 `AppDependencies` 从 `AppEndpoints.weekly` 注入，
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

        // 与 TrendingAPI 同理：上游 JSON 含 snake_case，所有键都已通过 CodingKeys 显式映射，
        // 这里**不要**开 `.convertFromSnakeCase`，否则会先把 key 转成 camelCase，
        // 反而无法匹配 `CodingKeys = "snake_key"`。
        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    // MARK: - Public API

    /// 热更新 baseURL（用户在设置页改地址后由 `AppDependencies` 推送进来）。
    ///
    /// 不需要重启 App：actor 串行化让"更新 URL"与"用新 URL 发请求"按调用顺序执行。
    /// 已经在飞行中的请求（用旧 URL 发出去的）按旧 URL 跑完，不会被中途打断。
    func updateBaseURL(_ url: URL) {
        AppLog.network.info("WeeklyAPI baseURL updated to \(url.absoluteString, privacy: .public)")
        self.baseURL = url
    }

    /// 热更新 API Key（用户在设置页改 key 后由 `AppDependencies` 推送进来）。
    /// 出于日志安全考虑不打印 key 本体，只打 prefix。
    func updateAPIKey(_ key: String?) {
        let preview = key.flatMap { $0.isEmpty ? nil : String($0.prefix(7)) } ?? "<nil>"
        AppLog.network.info("WeeklyAPI apiKey updated (prefix=\(preview, privacy: .public)****)")
        self.apiKey = key
    }

    /// 拉取三源聚合 repo feed。
    ///
    /// 后端负责聚合、排序和去重；客户端可发送 `source` 过滤，但 identity 仍只消费
    /// `gh_repo_id`，不再用 owner/name 推导同一项目。
    func fetchRepos(query: WeeklyFeedQuery = WeeklyFeedQuery()) async throws -> WeeklyFeedListResult {
        let url = try buildReposURL(query: query)
        let (data, response) = try await performRequestWithResponse(url: url)

        do {
            guard let http = response as? HTTPURLResponse else {
                throw WeeklyAPIError.transport(underlying: URLError(.badServerResponse))
            }
            guard (200...299).contains(http.statusCode) else {
                if let envelopeError = try? decoder.decode(StarcatErrorEnvelope.self, from: data) {
                    throw WeeklyAPIError.serverError(
                        message: "[\(envelopeError.error.code)] \(envelopeError.error.message)"
                    )
                }
                let raw = String(data: data, encoding: .utf8)
                throw WeeklyAPIError.serverError(message: raw)
            }

            let envelope = try decoder.decode(StarcatEnvelope<[WeeklyFeedRepoDTO]>.self, from: data)
            if !envelope.isSupported {
                AppLog.network.warning(
                    "weekly envelope schema_version=\(envelope.schemaVersion, privacy: .public) > supported=\(StarcatEnvelopeSchema.supported, privacy: .public); 部分新字段可能未识别，建议升级 Starcat"
                )
            }

            guard let meta = envelope.meta else {
                throw WeeklyAPIError.serverError(message: "missing response meta")
            }

            let items = envelope.data.map(WeeklyFeedItem.init(dto:))
            return WeeklyFeedListResult(
                items: items,
                total: meta.total ?? items.count,
                page: meta.page ?? query.page,
                pageSize: meta.pageSize ?? query.pageSize,
                nextPage: meta.nextPage
            )
        } catch let error as WeeklyAPIError {
            throw error
        } catch {
            throw WeeklyAPIError.decodingError(underlying: error)
        }
    }

    /// 拉取单 repo 聚合详情（repo + source events）。
    func fetchDetail(repoID: Int64) async throws -> WeeklyRepoDetail {
        let endpoint = AppEndpoints.appendPath(
            "\(AppEndpoints.Weekly.Paths.repoDetail)/\(repoID)",
            to: baseURL
        )
        let (data, response) = try await performRequestWithResponse(url: endpoint)

        // 2xx 走 envelope success path；非 2xx 拆 ErrorEnvelope 报错。
        guard let http = response as? HTTPURLResponse else {
            throw WeeklyAPIError.transport(underlying: URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            if let envelopeError = try? decoder.decode(StarcatErrorEnvelope.self, from: data) {
                throw WeeklyAPIError.serverError(
                    message: "[\(envelopeError.error.code)] \(envelopeError.error.message)"
                )
            }
            let raw = String(data: data, encoding: .utf8)
            throw WeeklyAPIError.serverError(message: raw)
        }

        do {
            let envelope = try decoder.decode(StarcatEnvelope<WeeklyRepoDetail>.self, from: data)
            if !envelope.isSupported {
                AppLog.network.warning(
                    "weekly detail envelope schema_version=\(envelope.schemaVersion, privacy: .public) > supported=\(StarcatEnvelopeSchema.supported, privacy: .public)"
                )
            }
            return envelope.data
        } catch {
            throw WeeklyAPIError.decodingError(underlying: error)
        }
    }

    /// 拉取 bulk endpoint：一次性返回 weekly 全量 repos + languages 聚合。
    ///
    /// R-06.4（2026-06-15）客户端接入：
    /// - 不接受任何 query 参数（后端 endpoint 设计为"全量未过滤数据"，客户端拿全量后本地
    ///   做 source/lang/sort/page 过滤）。
    /// - `URLSession` 默认会带 `Accept-Encoding: gzip, deflate, br` 并自动解压（Foundation
    ///   底层 NSURLSessionTask 在 Darwin 上由 CFNetwork 处理），所以我们读到的 `data` 已经
    ///   是解压后的 JSON 字节流；服务端 `Content-Encoding: gzip` 对调用方完全透明。
    /// - 不做 conditional GET 304：本地缓存层（`WeeklyBulkRepository`）已经用 12h TTL 做
    ///   "客户端是否要发请求"的总闸；ETag 304 仅用于"绝对要发 + 但 server 也没变"的极少数
    ///   场景，加 304 处理会让客户端代码量翻倍而收益微小（典型场景是用户在 TTL 内强制刷新，
    ///   此时本来就是为了拿"server 真值"，304 反而需要 fallback 到本地 + 还得维护 ETag）。
    func fetchBulkRepos() async throws -> WeeklyBulkResult {
        let endpoint = AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.reposBulk, to: baseURL)
        let (data, response) = try await performRequestWithResponse(url: endpoint)

        guard let http = response as? HTTPURLResponse else {
            throw WeeklyAPIError.transport(underlying: URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            if let envelopeError = try? decoder.decode(StarcatErrorEnvelope.self, from: data) {
                throw WeeklyAPIError.serverError(
                    message: "[\(envelopeError.error.code)] \(envelopeError.error.message)"
                )
            }
            let raw = String(data: data, encoding: .utf8)
            throw WeeklyAPIError.serverError(message: raw)
        }

        do {
            let envelope = try decoder.decode(StarcatEnvelope<WeeklyBulkDataDTO>.self, from: data)
            if envelope.schemaVersion > Self.supportedBulkSchemaVersion {
                AppLog.network.warning(
                    "weekly bulk envelope schema_version=\(envelope.schemaVersion, privacy: .public) > supported=\(Self.supportedBulkSchemaVersion, privacy: .public); 部分新字段可能未识别，建议升级 Starcat"
                )
            }
            let items = envelope.data.repos.map(WeeklyFeedItem.init(dto:))
            // 服务端 ETag header 透传到客户端用于将来 conditional GET（当前不做 304）。
            let etag = http.value(forHTTPHeaderField: "ETag")
            let generatedAt = envelope.meta?.generatedAt
            return WeeklyBulkResult(
                sources: envelope.data.sources,
                items: items,
                languages: envelope.data.languages,
                etag: etag,
                generatedAt: generatedAt,
                total: envelope.meta?.total ?? items.count
            )
        } catch let error as WeeklyAPIError {
            throw error
        } catch {
            throw WeeklyAPIError.decodingError(underlying: error)
        }
    }

    /// 获取三源聚合语言列表，用于 Weekly 语言筛选。
    func fetchLanguages() async throws -> [TrendingLanguageAggregateDTO] {
        let endpoint = AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.languages, to: baseURL)
        let (data, response) = try await performRequestWithResponse(url: endpoint)

        do {
            return try StarcatEnvelopeDecoder.decode(
                [TrendingLanguageAggregateDTO].self,
                data: data,
                response: response,
                decoder: decoder
            )
        } catch let error as StarcatEnvelopeNetworkError {
            throw WeeklyAPIError.serverError(message: error.localizedDescription)
        } catch {
            throw WeeklyAPIError.decodingError(underlying: error)
        }
    }

    // MARK: - Private

    private func buildReposURL(query: WeeklyFeedQuery) throws -> URL {
        let endpoint = AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.repos, to: baseURL)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(query.page)),
            URLQueryItem(name: "page_size", value: String(query.pageSize)),
            URLQueryItem(name: "sort", value: query.sort.apiSortKey),
            URLQueryItem(name: "order", value: query.sort.apiOrder.rawValue)
        ]
        if let language = query.language, !language.isEmpty {
            queryItems.append(URLQueryItem(name: "lang", value: language))
        }
        if let source = query.source.queryValue {
            queryItems.append(URLQueryItem(name: "source", value: source))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw WeeklyAPIError.invalidURL
        }
        return url
    }

    /// 走 GET + 注入 Bearer + 拿到 (data, response)，**不解析 status code**——
    /// 由调用方接管成功 / 错误判定（v1.2 envelope 时代非 2xx 也是 envelope 形态）。
    private func performRequestWithResponse(url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")

        // R-01 v1.2：后端强制 Bearer Auth；apiKey 为 nil/空时不发头（后端会 401，
        // envelope 错误识别后翻译成 WeeklyAPIError.serverError，UI 引导去设置页配置 key）。
        if let key = apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            return try await session.data(for: request)
        } catch {
            throw WeeklyAPIError.transport(underlying: error)
        }
    }
}

// MARK: - Result

/// 列表查询的领域级返回：DTO 已转成 `WeeklyFeedItem`，分页元数据原样透传。
///
/// 单独抽出来而不是直接复用 DTO，是为了让 ViewModel 不依赖 `Decodable` 类型，
/// 后续若做缓存层（GRDB）替换，签名也不用动。
struct WeeklyFeedListResult: Equatable {
    let items: [WeeklyFeedItem]
    let total: Int
    let page: Int
    let pageSize: Int
    let nextPage: Int?

    /// 是否还有下一页：R-05 规定唯一真源是 `meta.next_page`。
    var hasMore: Bool { nextPage != nil }
}

// MARK: - Bulk

/// `/api/v1/repos/bulk` 返回的 envelope.data 段 schema。
///
/// R-06.4：内部 DTO，仅供 `WeeklyAPI.fetchBulkRepos` 解码后映射到 `WeeklyBulkResult` 后销毁，
/// 不在 ViewModel / Repository 之间传递。
struct WeeklyBulkDataDTO: Decodable, Equatable, Sendable {
    let sources: [WeeklySourceDescriptor]
    let repos: [WeeklyFeedRepoDTO]
    let languages: [TrendingLanguageAggregateDTO]
}

/// bulk endpoint 领域返回：DTO 已转 `WeeklyFeedItem`，languages 透传，meta 字段保留供
/// `WeeklyBulkRepository` 写入 `weekly_bulk_meta` 表。
///
/// R-06.4（2026-06-15）：与 `WeeklyFeedListResult` 并列，区别是 bulk 无分页字段 +
/// 多了 etag / generatedAt 两个 cache meta。
struct WeeklyBulkResult: Equatable, Sendable {
    let sources: [WeeklySourceDescriptor]
    let items: [WeeklyFeedItem]
    let languages: [TrendingLanguageAggregateDTO]
    /// 服务端响应 `ETag` header（如 `W/"abc123de"`）。当前不做 conditional GET 304，但
    /// 落盘是为了将来"server 主动 push schedule 变更后客户端能在 12h TTL 内 ad-hoc 提早
    /// 失效"等扩展场景。
    let etag: String?
    /// 服务端 envelope.meta.generated_at（payload 构建时刻，ISO8601）。与 client-side
    /// `lastFetchedAt` 拉开语义：generated_at 是"服务端 payload 新鲜度"，lastFetchedAt 是
    /// "客户端 byte 到达时刻"，两者可能差几秒（gzip + 网络往返）。
    let generatedAt: String?
    let total: Int
}
