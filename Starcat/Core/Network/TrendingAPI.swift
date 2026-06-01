//
//  TrendingAPI.swift
//  Starcat
//
//  GitHub Trending REST API 客户端。
//
//  数据源：https://trend.doforce.dpdns.org/repo
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

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    // MARK: - Initialization

    init(
        baseURL: URL = URL(string: "https://trend.doforce.dpdns.org")!,
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

        // 这个 API 只有一个 snake_case 字段 `build_by`，DTO 已用 CodingKeys 显式映射。
        // 如果再开 `.convertFromSnakeCase`，JSONDecoder 会先把响应 key 转成 `buildBy`，
        // 反而匹配不到 `CodingKeys.buildBy = "build_by"`，导致线上响应解码失败。
        let decoder = JSONDecoder()
        self.decoder = decoder
    }

    // MARK: - Public API

    /// 获取热门仓库列表。
    ///
    /// - Parameters:
    ///   - since: 时间周期（daily/weekly/monthly）
    ///   - language: 编程语言筛选（空字符串表示全部）
    /// - Returns: Trending 仓库数组
    func fetchTrending(
        since: TrendingPeriod,
        language: TrendingLanguage = .all
    ) async throws -> [TrendingRepo] {
        let url = try buildURL(since: since, language: language)
        let data = try await performRequest(url: url)
        let dtos = try decoder.decode([TrendingResponseDTO].self, from: data)

        // 转换为领域模型，带上当前周期用于 periodText
        return dtos.map { TrendingRepo(dto: $0, since: since) }
    }

    // MARK: - Private

    private func buildURL(since: TrendingPeriod, language: TrendingLanguage) throws -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("repo"), resolvingAgainstBaseURL: false)
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

    private func performRequest(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            return try validateResponse(data: data, response: response)
        } catch let error as TrendingAPIError {
            throw error
        } catch {
            throw TrendingAPIError.transport(underlying: error)
        }
    }

    private func validateResponse(data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            throw TrendingAPIError.transport(underlying: URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 400...499:
            let message = String(data: data, encoding: .utf8)
            throw TrendingAPIError.serverError(message: message)
        case 500...599:
            throw TrendingAPIError.serverError(message: String(format: String(localized: "network.error.serverStatusFormat"), http.statusCode))
        default:
            throw TrendingAPIError.transport(underlying: URLError(.badServerResponse))
        }
    }
}
