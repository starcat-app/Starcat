//
//  CuratedPublisherAPI.swift
//  Starcat
//
//  weekly-api 管理员导入客户端。只覆盖精选发布台需要的三个端点。
//
//  安全约束：
//  - admin key 只在构造单次 URLRequest 时进入 Authorization header；
//  - 错误、日志与返回模型都不保留 header 或 key；
//  - actor 隔离 URLSession/JSONEncoder/JSONDecoder 的并发访问。
//

import Foundation

protocol CuratedPublisherAPIProtocol: Sendable {
    func fetchManualSources(adminKey: String) async throws -> [CuratedPublisherSource]
    func submit(
        _ request: CuratedPublisherImportRequest,
        adminKey: String
    ) async throws -> CuratedPublisherBatchAcceptance
    func fetchBatch(id: String, adminKey: String) async throws -> CuratedPublisherBatch
}

enum CuratedPublisherAPIError: Error, LocalizedError {
    case invalidURL
    case unauthorized
    case transport(underlying: Error)
    case decoding(underlying: Error)
    case server(statusCode: Int, code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String.l10n("network.error.invalidURL")
        case .unauthorized:
            return String.l10n("curatedPublisher.error.unauthorized")
        case .transport(let error):
            return String(format: String.l10n("network.error.transportFormat"), error.localizedDescription)
        case .decoding(let error):
            return String(format: String.l10n("network.error.decodingFormat"), error.localizedDescription)
        case .server(_, let code, let message):
            if let code, let message { return "[\(code)] \(message)" }
            return message ?? String.l10n("network.error.serverGeneric")
        }
    }
}

actor CuratedPublisherAPIClient: CuratedPublisherAPIProtocol {
    private static let timeout: TimeInterval = 30

    private var baseURL: URL
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = ThirdPartyService.weekly.normalizedBaseURL(baseURL)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.timeout
            configuration.timeoutIntervalForResource = Self.timeout
            self.session = URLSession(configuration: configuration)
        }
    }

    func updateBaseURL(_ url: URL) {
        baseURL = ThirdPartyService.weekly.normalizedBaseURL(url)
    }

    func fetchManualSources(adminKey: String) async throws -> [CuratedPublisherSource] {
        let endpoint = AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.internalSources, to: baseURL)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw CuratedPublisherAPIError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "manual_import", value: "true")]
        guard let url = components.url else { throw CuratedPublisherAPIError.invalidURL }
        let data = try await perform(url: url, method: "GET", body: nil, adminKey: adminKey)
        return try decodeEnvelope([CuratedPublisherSource].self, from: data)
            .filter { $0.enabled && $0.manualImportEnabled }
            .sorted { lhs, rhs in
                lhs.sortOrder == rhs.sortOrder ? lhs.code < rhs.code : lhs.sortOrder < rhs.sortOrder
            }
    }

    func submit(
        _ request: CuratedPublisherImportRequest,
        adminKey: String
    ) async throws -> CuratedPublisherBatchAcceptance {
        let url = AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.internalImports, to: baseURL)
        let body: Data
        do {
            body = try encoder.encode(request)
        } catch {
            throw CuratedPublisherAPIError.decoding(underlying: error)
        }
        let data = try await perform(url: url, method: "POST", body: body, adminKey: adminKey)
        return try decodeEnvelope(CuratedPublisherBatchAcceptance.self, from: data)
    }

    func fetchBatch(id: String, adminKey: String) async throws -> CuratedPublisherBatch {
        let batchID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !batchID.isEmpty else { throw CuratedPublisherAPIError.invalidURL }
        let base = AppEndpoints.appendPath(AppEndpoints.Weekly.Paths.internalImports, to: baseURL)
        let url = base.appendingPathComponent(batchID)
        let data = try await perform(url: url, method: "GET", body: nil, adminKey: adminKey)
        return try decodeEnvelope(CuratedPublisherBatch.self, from: data)
    }

    private func perform(
        url: URL,
        method: String,
        body: Data?,
        adminKey: String
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")
        StarcatGatewayRouting.applyServiceHeader(to: &request, service: .weekly)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CuratedPublisherAPIError.transport(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CuratedPublisherAPIError.transport(underlying: URLError(.badServerResponse))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CuratedPublisherAPIError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            let envelope = try? decoder.decode(StarcatErrorEnvelope.self, from: data)
            throw CuratedPublisherAPIError.server(
                statusCode: http.statusCode,
                code: envelope?.error.code,
                message: envelope?.error.message
            )
        }
        return data
    }

    private func decodeEnvelope<T: Decodable & Sendable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(StarcatEnvelope<T>.self, from: data).data
        } catch {
            throw CuratedPublisherAPIError.decoding(underlying: error)
        }
    }
}
