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
        let eventsBaseURL: URL?
        let eventsKey: String?
        init(baseURL: URL, key: String?, generation: UInt64, eventsBaseURL: URL? = nil, eventsKey: String? = nil) {
            self.baseURL = baseURL
            self.key = key
            self.generation = generation
            self.eventsBaseURL = eventsBaseURL
            self.eventsKey = eventsKey
        }
        var namespace: String {
            Self.digest("daily-radar-v1|\(baseURL.absoluteString)|\(key ?? "")")
        }
        var eventsNamespace: String {
            Self.digest("ai-events-v1|\((eventsBaseURL ?? baseURL).absoluteString)|\(eventsKey ?? "")")
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
    private var eventsBaseURL: URL?
    private var eventsKey: String?
    private var generation: UInt64 = 0
    private let session: URLSession

    init(baseURL: URL, apiKey: String?, eventsBaseURL: URL? = nil, eventsAPIKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        key = apiKey
        self.eventsBaseURL = eventsBaseURL
        eventsKey = eventsAPIKey
        self.session = session
    }
    func configuration() -> Configuration {
        .init(baseURL: baseURL, key: key, generation: generation, eventsBaseURL: eventsBaseURL, eventsKey: eventsKey)
    }
    func update(baseURL: URL? = nil, apiKey: String? = nil, replacesKey: Bool = false) {
        if let baseURL { self.baseURL = baseURL }
        if replacesKey { key = apiKey }
        generation &+= 1
    }

    /// 独立服务热更新同样推进代次，旧请求不能写入新凭据对应的缓存
    func updateEvents(baseURL: URL? = nil, apiKey: String? = nil, replacesKey: Bool = false) {
        if let baseURL { eventsBaseURL = baseURL }
        if replacesKey { eventsKey = apiKey }
        generation &+= 1
    }

    /// 分类参数决定目录/列表归属；正文从不可变报告 ID 判断，避免依赖当前 UI 选择
    nonisolated static func isEvents(path: String, parameters: [URLQueryItem]) -> Bool {
        parameters.contains { $0.name == "category" && $0.value == "ai-weekly-events" }
            || path.hasPrefix("/api/v1/daily-radar/reports/ai-weekly-events:")
    }

    /// 请求使用捕获的配置；HTTP 自带缓存关闭，ETag 由独立日报缓存统一管理。
    func request(path: String, parameters: [URLQueryItem], etag: String?, configuration: Configuration) async throws -> Response {
        let events = Self.isEvents(path: path, parameters: parameters)
        let target = events ? (configuration.eventsBaseURL ?? configuration.baseURL) : configuration.baseURL
        let key = events ? configuration.eventsKey : configuration.key
        var components = URLComponents(url: AppEndpoints.appendPath(path, to: target), resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.name < $1.name }
        guard let url = components.url else { throw DailyRadarError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        StarcatGatewayRouting.applyServiceHeader(to: &request, service: events ? .aiEvents : .weekly)
        if let key, !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await DiagnosticHTTP.data(for: request, using: session, service: "dailyRadar")
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
