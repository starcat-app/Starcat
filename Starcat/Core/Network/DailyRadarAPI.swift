//
//  DailyRadarAPI.swift
//  Starcat
//
//  Weekly 日报网络读取。所有请求使用服务读取 Key，不使用 GitHub OAuth，
//  且从不触发采集、生成或任何仓库写入。
//

import Foundation
import CryptoKit

enum DailyRadarError: Error {
    case invalidResponse
    case server(code: String)
    case staleConfiguration
    var catalogChanged: Bool {
        if case .server(let code) = self { return code == "CATALOG_CHANGED" }
        return false
    }
}

/// actor 保证凭据热更新和请求快照分离；迟到响应不能污染新服务的缓存。
actor DailyRadarAPI {
    struct Configuration: Sendable {
        let baseURL: URL
        let key: String?
        let generation: UInt64
        var namespace: String {
            Self.digest("daily-radar-v1|\(baseURL.absoluteString)|\(key ?? "")")
        }
        static func digest(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }
    struct Response: Sendable {
        let data: Data
        let notModified: Bool
        let etag: String?
    }
    private var baseURL: URL
    private var key: String?
    private var generation: UInt64 = 0
    private let session: URLSession

    init(baseURL: URL, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        key = apiKey
        self.session = session
    }
    func configuration() -> Configuration { .init(baseURL: baseURL, key: key, generation: generation) }
    func update(baseURL: URL? = nil, apiKey: String? = nil, replacesKey: Bool = false) {
        if let baseURL { self.baseURL = baseURL }
        if replacesKey { key = apiKey }
        generation &+= 1
    }

    /// 请求使用捕获的配置；HTTP 自带缓存关闭，ETag 由独立日报缓存统一管理。
    func request(path: String, parameters: [URLQueryItem], etag: String?, configuration: Configuration) async throws -> Response {
        var components = URLComponents(url: AppEndpoints.appendPath(path, to: configuration.baseURL), resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.name < $1.name }
        guard let url = components.url else { throw DailyRadarError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        StarcatGatewayRouting.applyServiceHeader(to: &request, service: .weekly)
        if let key = configuration.key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard generation == configuration.generation else { throw DailyRadarError.staleConfiguration }
        guard let http = response as? HTTPURLResponse else { throw DailyRadarError.invalidResponse }
        if http.statusCode == 304 { return .init(data: data, notModified: true, etag: http.value(forHTTPHeaderField: "ETag")) }
        guard http.statusCode == 200 else {
            let envelope = try? JSONDecoder().decode(StarcatErrorEnvelope.self, from: data)
            throw DailyRadarError.server(code: envelope?.error.code ?? "HTTP_\(http.statusCode)")
        }
        return .init(data: data, notModified: false, etag: http.value(forHTTPHeaderField: "ETag"))
    }
}
