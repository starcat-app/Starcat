//
//  RecommendAPI.swift
//  Starcat
//
//  starcat-recommend-api 客户端。
//
//  本 actor 和 TrendingAPI / WeeklyAPI / WikiAPI 同款：独立持有 baseURL 与 API Key,
//  设置页修改后通过 update 方法热生效。双渠道只消费 Starcat 自研 v2 推荐契约。
//

import Foundation

/// 缓存快照向推荐服务重验证后的结果。
///
/// `.unsupported` 供不实现重验证的协议测试替身使用；正式客户端统一使用 v2，
/// 明确区分 304 与新页面，才能正确保留缓存或覆盖为新模型结果。
enum RecommendationRevalidationResult: Sendable {
    case unsupported
    case notModified
    case modified(RepoRecommendationPage)
}

actor RecommendAPI {
    private static let timeout: TimeInterval = 30
    /// 保持既有 Direct 自研缓存身份，并与已发布 App Store 的第三方快照隔离。
    private static let cacheKey = "trained-v2-display-score-v1"

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
        let result = try await performRecommendationsRequest(
            repoID: repoID,
            limit: limit,
            offset: offset,
            ifNoneMatch: nil
        )
        guard case .modified(let page) = result else {
            // 未发送条件头时服务端不应返回 304；若代理错误返回，按坏响应处理而不是
            // 伪造空页面覆盖本地缓存。
            throw StarcatEnvelopeNetworkError.transport(URLError(.badServerResponse))
        }
        return page
    }

    /// 用缓存快照里的模型版本重验证自研推荐第一页。
    ///
    /// ETag 由实际 Bundle / 源内容版本和分页参数组成；服务端固定快照后返回 304，
    /// 不传输未变化的推荐正文，两个分发渠道使用完全相同的契约。
    func revalidateRecommendations(
        repoID: Int64,
        limit: Int,
        offset: Int,
        cachedModelVersion: String?
    ) async throws -> RecommendationRevalidationResult {
        let entityTag = cachedModelVersion.flatMap {
            Self.recommendationEntityTag(modelVersion: $0, repoID: repoID, limit: limit, offset: offset)
        }
        return try await performRecommendationsRequest(
            repoID: repoID,
            limit: limit,
            offset: offset,
            ifNoneMatch: entityTag
        )
    }

    private func performRecommendationsRequest(
        repoID: Int64,
        limit: Int,
        offset: Int,
        ifNoneMatch: String?
    ) async throws -> RecommendationRevalidationResult {
        guard repoID > 0, limit > 0, offset >= 0 else {
            throw StarcatEnvelopeNetworkError.invalidURL
        }

        let path = "\(AppEndpoints.Recommend.Paths.trainedRecommendations)/\(repoID)/recommendations"
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
        // 推荐正文由 DiskRecommendationCache 统一管理；关闭 URLCache 的透明 304 合并，
        // 让本 actor 能可靠区分服务端 304 与携带新模型正文的 200。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        StarcatGatewayRouting.applyServiceHeader(to: &request, service: .recommend)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StarcatEnvelopeNetworkError.transport(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode == 304 {
            return .notModified
        }

        return .modified(
            try StarcatEnvelopeDecoder.decode(
                RepoRecommendationPage.self,
                data: data,
                response: response,
                decoder: decoder
            )
        )
    }

    /// 与 Recommend API 的 ETag 契约保持一致。版本字符不满足 Registry 白名单时不发送
    /// 条件头，安全退化成完整 200 请求，避免把异常服务端数据写进 HTTP header。
    private static func recommendationEntityTag(
        modelVersion: String,
        repoID: Int64,
        limit: Int,
        offset: Int
    ) -> String? {
        guard !modelVersion.isEmpty,
              modelVersion.utf8.count <= 128,
              modelVersion.unicodeScalars.allSatisfy({ scalar in
                  let value = scalar.value
                  return (48...57).contains(value)
                      || (65...90).contains(value)
                      || (97...122).contains(value)
                      || value == 46
                      || value == 95
                      || value == 45
              }) else { return nil }
        return "\"recommendation:\(modelVersion):\(repoID):\(limit):\(offset)\""
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
    /// 其他服务结果。作用域不包含 API Key，既能隔离服务又不会把凭据写入磁盘。
    func recommendationCacheScope() async -> String {
        "\(Self.cacheKey)|\(baseURL.absoluteString)"
    }
}
