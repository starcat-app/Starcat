//
//  DiscoveryAPI.swift
//  Starcat
//
//  starcat-discovery-api 客户端。
//
//  与 TrendingAPI / RecommendAPI 同款：actor 独立持有 baseURL 与 API Key，设置页修改后
//  通过 update 方法热生效。客户端只消费 Starcat Discovery 契约，不直连 GitHub。
//

import Foundation

actor DiscoveryAPI {
    /// 自动加载有本地缓存兜底，应尽快失败；手动刷新允许更长等待，但也不能让 UI
    /// 在服务下线时保持数十秒刷新状态。
    private static let automaticRequestTimeout: TimeInterval = 5
    private static let manualRefreshTimeout: TimeInterval = 10

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
            configuration.timeoutIntervalForRequest = Self.automaticRequestTimeout
            configuration.timeoutIntervalForResource = Self.manualRefreshTimeout
            self.session = URLSession(configuration: configuration)
        }
        self.decoder = JSONDecoder()
    }

    func fetchFeed(query: DiscoveryListQuery = DiscoveryListQuery()) async throws -> DiscoveryPage {
        try await fetchList(path: AppEndpoints.Discovery.Paths.feed, query: query)
    }

    func fetchMostPopular(query: DiscoveryListQuery = DiscoveryListQuery()) async throws -> DiscoveryPage {
        try await fetchList(path: AppEndpoints.Discovery.Paths.mostPopular, query: query)
    }

    func fetchNewReleases(query: DiscoveryListQuery = DiscoveryListQuery()) async throws -> DiscoveryPage {
        try await fetchList(path: AppEndpoints.Discovery.Paths.newReleases, query: query)
    }

    func fetchLanguages() async throws -> [DiscoveryLanguageDTO] {
        try await fetchMetadata(path: AppEndpoints.Discovery.Paths.languages)
    }

    func fetchTopics() async throws -> [DiscoveryTopicDTO] {
        try await fetchMetadata(path: AppEndpoints.Discovery.Paths.topics)
    }

    func fetchPlatforms() async throws -> [DiscoveryPlatformDTO] {
        try await fetchMetadata(path: AppEndpoints.Discovery.Paths.platforms)
    }

    func fetchSummary() async throws -> DiscoverySummaryDTO {
        let url = AppEndpoints.appendPath(AppEndpoints.Discovery.Paths.summary, to: baseURL)
        let (data, response) = try await performRequest(url: url)
        return try StarcatEnvelopeDecoder.decode(
            DiscoverySummaryDTO.self,
            data: data,
            response: response,
            decoder: decoder
        )
    }

    /// 拉取 discovery bulk endpoint。
    ///
    /// 与 Weekly bulk 同款：客户端拿到完整公开 catalog 后在本地 SQLite 做筛选、排序和分页。
    /// 这里不做 conditional GET；是否发请求由 Repository/ViewModel 的 TTL 负责。
    func fetchBulk(ignoresCache: Bool = false) async throws -> DiscoveryBulkResult {
        let url = AppEndpoints.appendPath(AppEndpoints.Discovery.Paths.bulk, to: baseURL)
        let (data, response) = try await performRequest(url: url, ignoresCache: ignoresCache)

        guard let http = response as? HTTPURLResponse else {
            throw StarcatEnvelopeNetworkError.transport(URLError(.badServerResponse))
        }
        let envelope = try decodeEnvelope(DiscoveryBulkDataDTO.self, data: data, response: response)
        return DiscoveryBulkResult(
            repos: envelope.data.repos,
            summary: envelope.data.summary,
            etag: http.value(forHTTPHeaderField: "ETag"),
            generatedAt: envelope.meta?.generatedAt,
            total: envelope.meta?.total ?? envelope.data.repos.count
        )
    }

    /// 拉取精选 Awesome 来源目录。304 是正常缓存状态，不能交给通用 envelope decoder 当错误。
    func fetchAwesomeSources(ifNoneMatch: String? = nil) async throws -> AwesomeCatalogResult {
        let url = AppEndpoints.appendPath(AppEndpoints.Discovery.Paths.awesomeSources, to: baseURL)
        let (data, response) = try await performRequest(url: url, ifNoneMatch: ifNoneMatch)
        let http = try requireHTTPResponse(response)
        if http.statusCode == 304 {
            return AwesomeCatalogResult(
                sources: [],
                etag: http.value(forHTTPHeaderField: "ETag") ?? ifNoneMatch,
                generatedAt: nil,
                notModified: true
            )
        }
        let envelope = try decodeEnvelope([AwesomeSourceDTO].self, data: data, response: response)
        return AwesomeCatalogResult(
            sources: envelope.data,
            etag: http.value(forHTTPHeaderField: "ETag"),
            generatedAt: envelope.meta?.generatedAt,
            notModified: false
        )
    }

    /// 拉取一个已发布 Awesome 来源的完整 GitHub Repo 条目快照。
    func fetchAwesomeEntries(
        sourceID: String,
        ifNoneMatch: String? = nil
    ) async throws -> AwesomeEntriesResult {
        let path = AppEndpoints.Discovery.Paths.awesomeEntries(sourceID: sourceID)
        let url = AppEndpoints.appendPath(path, to: baseURL)
        let (data, response) = try await performRequest(url: url, ifNoneMatch: ifNoneMatch)
        let http = try requireHTTPResponse(response)
        if http.statusCode == 304 {
            return AwesomeEntriesResult(
                snapshot: nil,
                etag: http.value(forHTTPHeaderField: "ETag") ?? ifNoneMatch,
                generatedAt: nil,
                notModified: true
            )
        }
        let envelope = try decodeEnvelope(AwesomeEntriesSnapshotDTO.self, data: data, response: response)
        return AwesomeEntriesResult(
            snapshot: envelope.data,
            etag: http.value(forHTTPHeaderField: "ETag"),
            generatedAt: envelope.meta?.generatedAt,
            notModified: false
        )
    }

    func updateBaseURL(_ url: URL) {
        baseURL = url
    }

    func updateAPIKey(_ key: String?) {
        apiKey = key
    }

    private func fetchList(path: String, query: DiscoveryListQuery) async throws -> DiscoveryPage {
        let endpoint = AppEndpoints.appendPath(path, to: baseURL)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(query.page)"),
            URLQueryItem(name: "limit", value: "\(query.limit)")
        ]
        appendQueryItem(&queryItems, name: "language", value: query.language)
        appendQueryItem(&queryItems, name: "platform", value: query.platform)
        appendQueryItem(&queryItems, name: "topic", value: query.topic)
        appendQueryItem(&queryItems, name: "sort", value: query.sort)
        components?.queryItems = queryItems

        guard let url = components?.url else {
            throw StarcatEnvelopeNetworkError.invalidURL
        }

        let (data, response) = try await performRequest(url: url)
        let envelope = try decodeEnvelope([DiscoveryRepoDTO].self, data: data, response: response)
        return DiscoveryPage(
            items: envelope.data,
            total: envelope.meta?.total ?? envelope.data.count,
            page: envelope.meta?.page ?? query.page,
            pageSize: envelope.meta?.pageSize ?? query.limit,
            nextPage: envelope.meta?.nextPage
        )
    }

    private func fetchMetadata<T: Decodable & Sendable>(path: String) async throws -> [T] {
        let url = AppEndpoints.appendPath(path, to: baseURL)
        let (data, response) = try await performRequest(url: url)
        return try StarcatEnvelopeDecoder.decode(
            [T].self,
            data: data,
            response: response,
            decoder: decoder
        )
    }

    private func performRequest(
        url: URL,
        ignoresCache: Bool = false,
        ifNoneMatch: String? = nil
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = ignoresCache
            ? Self.manualRefreshTimeout
            : Self.automaticRequestTimeout
        if ignoresCache {
            // 手动刷新必须越过 URLCache，否则后端 bulk 已更新时仍可能拿到系统缓存的旧快照。
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")
        if let ifNoneMatch, !ifNoneMatch.isEmpty {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        StarcatGatewayRouting.applyServiceHeader(to: &request, service: .discovery)
        do {
            return try await session.data(for: request)
        } catch {
            throw StarcatEnvelopeNetworkError.transport(error)
        }
    }

    private func requireHTTPResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw StarcatEnvelopeNetworkError.transport(URLError(.badServerResponse))
        }
        return http
    }

    private func decodeEnvelope<T: Decodable & Sendable>(
        _ type: T.Type,
        data: Data,
        response: URLResponse
    ) throws -> StarcatEnvelope<T> {
        guard let http = response as? HTTPURLResponse else {
            throw StarcatEnvelopeNetworkError.transport(URLError(.badServerResponse))
        }
        guard (200...299).contains(http.statusCode) else {
            if let envelopeError = try? decoder.decode(StarcatErrorEnvelope.self, from: data) {
                throw StarcatEnvelopeNetworkError.serverError(
                    status: http.statusCode,
                    code: envelopeError.error.code,
                    message: envelopeError.error.message
                )
            }
            let raw = String(data: data, encoding: .utf8)
            throw StarcatEnvelopeNetworkError.serverError(
                status: http.statusCode,
                code: nil,
                message: raw ?? "HTTP \(http.statusCode)"
            )
        }
        do {
            return try decoder.decode(StarcatEnvelope<T>.self, from: data)
        } catch {
            throw StarcatEnvelopeNetworkError.decoding(error)
        }
    }

    private func appendQueryItem(_ items: inout [URLQueryItem], name: String, value: String?) {
        guard let value, !value.isEmpty else { return }
        items.append(URLQueryItem(name: name, value: value))
    }
}
