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

/// 周刊后端 API 客户端。
///
/// 用 `actor` 隔离 URLSession + JSONDecoder 的并发访问；公共方法是 async，
/// 与 TrendingAPI 完全一致，方便 ViewModel 同一种 await 风格调用。
actor WeeklyAPI {

    // MARK: - Constants

    /// 列表请求超时；后端首次启动时会 git clone ruanyf/weekly（可能数十秒），
    /// 但这只影响 `/internal/sync/weekly`，正常列表查询是本地 SQLite 命中，30s 充裕。
    private static let timeout: TimeInterval = 30

    /// 默认每页大小，与后端 README 默认值保持一致；UI 层不复写。
    static let defaultPageSize: Int = 20

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

    /// 拉取周刊项目分页列表。
    ///
    /// R-01 v1.2：响应 envelope 化 —— `data: [StarcatRepoCardDTO]` + `meta: {page, page_size, total, ...}`。
    /// 内部把卡片转成 `WeeklyProject` UI 模型 + 从 meta 取分页信息构造 `WeeklyProjectListResult`，
    /// 让 ViewModel 调用层零变更。
    ///
    /// - Parameters:
    ///   - page: 页码，从 1 开始。
    ///   - pageSize: 每页大小。
    ///   - issue: 期号筛选；`.all` 不传该参数。
    ///   - language: 语言筛选；nil 或空串等价于不筛选。
    ///   - sort: 排序方式。
    /// - Returns: 项目列表 + 分页元数据。
    func fetchProjects(
        page: Int = 1,
        pageSize: Int = WeeklyAPI.defaultPageSize,
        issue: WeeklyIssueFilter = .all,
        language: String? = nil,
        sort: WeeklySort = .firstIssueDesc
    ) async throws -> WeeklyProjectListResult {
        let url = try buildProjectsURL(page: page, pageSize: pageSize, issue: issue, language: language, sort: sort)
        let (data, response) = try await performRequestWithResponse(url: url)

        // envelope 解码：直接走 helper，让 schema_version warning / error envelope / 401 都自动处理。
        // 但本 endpoint 还需要拿 meta 段的分页信息，所以解码出 envelope 整体后再拆 data + meta。
        do {
            let envelope = try decoder.decode(StarcatEnvelope<[StarcatRepoCardDTO]>.self, from: data)

            // 复用 helper 的 schema_version / 错误判断逻辑：先扔进去转一次（成功路径会返回 data，
            // 但本方法需要 envelope.meta），所以这里仅手工执行同款步骤：
            // 1) 错误响应（envelope.go 里 4xx/5xx 也是 envelope 形态）→ helper 自动识别
            //    这里先直接判 status code，再走错误路径
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

            // 2) schema_version warning（与 StarcatEnvelopeDecoder 同款语义）
            if !envelope.isSupported {
                AppLog.network.warning(
                    "weekly envelope schema_version=\(envelope.schemaVersion, privacy: .public) > supported=\(StarcatEnvelopeSchema.supported, privacy: .public); 部分新字段可能未识别，建议升级 Starcat"
                )
            }

            // 3) 拼装 WeeklyProjectListResult：items 从 cards 转，分页信息从 meta 取（meta 缺失走传入参数兜底）
            let items = envelope.data.map(WeeklyProject.init(card:))
            let meta = envelope.meta
            return WeeklyProjectListResult(
                items: items,
                total: meta?.total ?? items.count,
                page: meta?.page ?? page,
                pageSize: meta?.pageSize ?? pageSize
            )
        } catch let error as WeeklyAPIError {
            throw error
        } catch {
            throw WeeklyAPIError.decodingError(underlying: error)
        }
    }

    /// 拉取单 repo 聚合详情（用于 `BackendAggregateRepoSource` / 详情页）。
    ///
    /// R-01 v1.2 后端新增 `GET /api/v1/projects/{owner}/{repo}` endpoint（v0.5.2 dong4j 重命名为
    /// `GET /api/v1/weekly/{owner}/{repo}`），返回该项目的最新
    /// `StarcatRepoCardDTO`（含 weekly 扩展段 + 后端 enricher 补的所有元数据）。
    ///
    /// **不**做任何 UI 转换：直接返回 DTO，由调用方（`BackendAggregateRepoSource` /
    /// `Repo.makeMinimal(card:)` 等）决定如何用。
    ///
    /// 错误：
    /// - 404（项目不在周刊收录列表里）→ `WeeklyAPIError.serverError`，调用方应当 catch
    ///   并退化为 nil（让 RepoResolver 链继续询问下一个 source）
    /// - 401（鉴权失败）→ `WeeklyAPIError.serverError(message: "[UNAUTHORIZED] ...")`
    func fetchProject(owner: String, repo: String) async throws -> StarcatRepoCardDTO {
        let endpoint = AppEndpoints.appendPath(
            "\(AppEndpoints.Weekly.Paths.projectsByOwnerRepo)/\(owner)/\(repo)",
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
            let envelope = try decoder.decode(StarcatEnvelope<StarcatRepoCardDTO>.self, from: data)
            if !envelope.isSupported {
                AppLog.network.warning(
                    "weekly project envelope schema_version=\(envelope.schemaVersion, privacy: .public) > supported=\(StarcatEnvelopeSchema.supported, privacy: .public)"
                )
            }
            return envelope.data
        } catch {
            throw WeeklyAPIError.decodingError(underlying: error)
        }
    }

    // MARK: - Private

    private func buildProjectsURL(
        page: Int,
        pageSize: Int,
        issue: WeeklyIssueFilter,
        language: String?,
        sort: WeeklySort
    ) throws -> URL {
        let endpoint = AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.projects, to: baseURL)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "page_size", value: String(pageSize)),
            URLQueryItem(name: "sort", value: sort.apiValue)
        ]
        if let issueValue = issue.apiValue {
            queryItems.append(URLQueryItem(name: "issue", value: issueValue))
        }
        if let language, !language.isEmpty {
            queryItems.append(URLQueryItem(name: "lang", value: language))
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

/// 列表查询的领域级返回：DTO 已转成 `WeeklyProject`，分页元数据原样透传。
///
/// 单独抽出来而不是直接复用 DTO，是为了让 ViewModel 不依赖 `Decodable` 类型，
/// 后续若做缓存层（GRDB）替换，签名也不用动。
struct WeeklyProjectListResult: Equatable {
    let items: [WeeklyProject]
    let total: Int
    let page: Int
    let pageSize: Int

    /// 是否还有下一页：根据 total / page / pageSize 推算，避免 ViewModel 自算出错。
    var hasMore: Bool {
        guard pageSize > 0 else { return false }
        return page * pageSize < total
    }
}
