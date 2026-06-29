//
//  RecommendAPI.swift
//  Starcat
//
//  starcat-recommend-api 客户端。
//
//  本 actor 和 TrendingAPI / WeeklyAPI / WikiAPI 同款：独立持有 baseURL 与 API Key,
//  设置页修改后通过 update 方法热生效。客户端只消费 Starcat 推荐契约, 不感知 SimRepo/Qdrant。
//

import Foundation

actor RecommendAPI {
    private static let timeout: TimeInterval = 30

    private var baseURL: URL
    private var apiKey: String?
    private let session: URLSession
    private let decoder: JSONDecoder

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
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            self.session = URLSession(configuration: configuration)
        }
        self.decoder = JSONDecoder()
    }

    /// 拉取某个 GitHub repo id 的相似仓库推荐。
    func fetchRecommendations(repoID: Int64, limit: Int = 10, offset: Int = 0) async throws -> RepoRecommendationPage {
        guard repoID > 0, limit > 0, offset >= 0 else {
            throw StarcatEnvelopeNetworkError.invalidURL
        }

        let path = "\(AppEndpoints.Recommend.Paths.repoRecommendations)/\(repoID)/recommendations"
        let endpoint = AppEndpoints.appendPath(path, to: baseURL)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]
        guard let url = components?.url else {
            throw StarcatEnvelopeNetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StarcatEnvelopeNetworkError.transport(error)
        }

        return try StarcatEnvelopeDecoder.decode(
            RepoRecommendationPage.self,
            data: data,
            response: response,
            decoder: decoder
        )
    }

    func updateBaseURL(_ url: URL) {
        baseURL = url
    }

    func updateAPIKey(_ key: String?) {
        apiKey = key
    }
}
