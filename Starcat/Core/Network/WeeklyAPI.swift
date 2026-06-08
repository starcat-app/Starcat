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
    /// 但这只影响 `/internal/sync`，正常列表查询是本地 SQLite 命中，30s 充裕。
    private static let timeout: TimeInterval = 30

    /// 默认每页大小，与后端 README 默认值保持一致；UI 层不复写。
    static let defaultPageSize: Int = 20

    // MARK: - Properties

    /// 当前 baseURL；通过 `updateBaseURL(_:)` 热更新（设置页改地址后立即生效）。
    /// 之所以是 `var`：用户在 ServicesSettingsTab 改地址会触发 `AppDependencies`
    /// 调本 actor 的 `updateBaseURL`，actor 串行化保证写入与下一次 build URL 的读
    /// 之间不会撕裂。
    private var baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    // MARK: - Initialization

    /// - Parameters:
    ///   - baseURL: 后端域名；DI 装配处由 `AppDependencies` 从 `AppEndpoints.weekly` 注入，
    ///     用户在设置页改地址后 `updateBaseURL(_:)` 热更新。
    ///   - session: 注入自定义 URLSession（一般用于单测 mock）；为 nil 走默认配置。
    init(
        baseURL: URL,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
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

    /// 拉取周刊项目分页列表。
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
        let data = try await performRequest(url: url)
        let dto: WeeklyProjectListDTO
        do {
            dto = try decoder.decode(WeeklyProjectListDTO.self, from: data)
        } catch {
            throw WeeklyAPIError.decodingError(underlying: error)
        }
        return WeeklyProjectListResult(
            items: dto.items.map(WeeklyProject.init(dto:)),
            total: dto.total,
            page: dto.page,
            pageSize: dto.pageSize
        )
    }

    // MARK: - Private

    private func buildProjectsURL(
        page: Int,
        pageSize: Int,
        issue: WeeklyIssueFilter,
        language: String?,
        sort: WeeklySort
    ) throws -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/weekly/projects"), resolvingAgainstBaseURL: false)
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

    private func performRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            return try validateResponse(data: data, response: response)
        } catch let error as WeeklyAPIError {
            throw error
        } catch {
            throw WeeklyAPIError.transport(underlying: error)
        }
    }

    private func validateResponse(data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw WeeklyAPIError.transport(underlying: URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 400...499:
            let message = String(data: data, encoding: .utf8)
            throw WeeklyAPIError.serverError(message: message)
        case 500...599:
            throw WeeklyAPIError.serverError(
                message: String(format: String(localized: "network.error.serverStatusFormat"), http.statusCode)
            )
        default:
            throw WeeklyAPIError.transport(underlying: URLError(.badServerResponse))
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
