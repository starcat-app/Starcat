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

/// Starcat 推荐客户端使用的服务端契约。
///
/// v1 和 v2 只在路由与数据来源上不同，返回卡片 DTO 保持兼容。显式建模可以避免
/// 本地 Direct 验证为了切换服务而复制整套客户端或推荐 UI。
enum RecommendationAPIContract: Sendable {
    case simRepoV1
    case trainedV2

    var repositoriesPath: String {
        switch self {
        case .simRepoV1: AppEndpoints.Recommend.Paths.simRepoRecommendations
        case .trainedV2: AppEndpoints.Recommend.Paths.trainedRecommendations
        }
    }

    /// 缓存作用域只需要区分 HTTP 契约，不包含 API Key 等敏感信息。
    var cacheKey: String {
        switch self {
        case .simRepoV1: "simrepo-v1"
        case .trainedV2: "trained-v2"
        }
    }
}

actor RecommendAPI {
    private static let timeout: TimeInterval = 30

    private var baseURL: URL
    private var apiKey: String?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let contract: RecommendationAPIContract

    init(
        baseURL: URL,
        apiKey: String? = nil,
        contract: RecommendationAPIContract = .simRepoV1,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.contract = contract

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

        let path = "\(contract.repositoriesPath)/\(repoID)/recommendations"
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
        StarcatGatewayRouting.applyServiceHeader(to: &request, service: .recommend)

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

    /// 返回当前服务地址与契约组成的稳定缓存作用域。
    ///
    /// 设置页可热切换 URL；缓存若只按 repoID 命中，会把本地模型结果误当成线上
    /// SimRepo 结果。作用域不包含 API Key，既能隔离服务又不会把凭据写入磁盘。
    func recommendationCacheScope() -> String {
        "\(contract.cacheKey)|\(baseURL.absoluteString)"
    }
}
