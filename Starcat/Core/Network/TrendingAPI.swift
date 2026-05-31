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
            return "无效的 URL"
        case .transport(let error):
            return "网络错误：\(error.localizedDescription)"
        case .decodingError(let error):
            return "响应解析失败：\(error.localizedDescription)"
        case .serverError(let message):
            return message ?? "服务器错误"
        }
    }
}

/// GitHub Trending API 客户端。
///
/// 使用 URLSession 直接请求外部 Trending API，不需要 GitHub 认证。
actor TrendingAPI {

    // MARK: - Constants

    /// Trending API 基础 URL
    private static let baseURL = URL(string: "https://trend.doforce.dpdns.org")!

    /// 请求超时时间
    private static let timeout: TimeInterval = 30

    // MARK: - Properties

    private let session: URLSession
    private let decoder: JSONDecoder

    // MARK: - Initialization

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        self.session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
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
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("repo"), resolvingAgainstBaseURL: false)
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
            throw TrendingAPIError.serverError(message: "服务器错误 (\(http.statusCode))")
        default:
            throw TrendingAPIError.transport(underlying: URLError(.badServerResponse))
        }
    }
}
