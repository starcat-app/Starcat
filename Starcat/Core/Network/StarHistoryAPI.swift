//
//  StarHistoryAPI.swift
//  Starcat
//
//  starcat-discovery-api 仓库星标历史客户端。
//
//  关键约束：
//  - 私有仓库在构造 URL 前直接拒绝，任何仓库身份都不会发送给公共 Discovery 服务。
//  - 200 / 202 / 304 都是协议内状态，调用方不应把 building 或 not-modified 当成通用失败。
//  - ETag 只由 Repository 保存和复用；API 层保持纯 HTTP / DTO 映射职责。
//

import Foundation

enum StarHistoryRange: String, CaseIterable, Identifiable, Sendable {
    case threeMonths = "3m"
    case oneYear = "1y"
    case all

    var id: String { rawValue }
}

struct StarHistoryRequest: Equatable, Sendable {
    let repoID: Int64
    let owner: String
    let name: String
    let isPrivate: Bool

    init(repo: Repo) {
        repoID = repo.id
        owner = repo.owner
        name = repo.name
        isPrivate = repo.isPrivate
    }
}

struct StarHistoryRemoteSeries: Equatable, Sendable {
    let repoID: Int64
    let fullName: String
    let currentStars: Int
    let range: StarHistoryRange
    let coverageStart: Date?
    let generatedAt: Date
    let points: [StarHistoryPoint]
}

enum StarHistoryAPIResult: Equatable, Sendable {
    case ready(series: StarHistoryRemoteSeries, etag: String?)
    case notModified(etag: String?)
    case building(retryAfter: TimeInterval)
}

enum StarHistoryAPIError: Error, Equatable, LocalizedError, Sendable {
    case privateRepository
    case invalidRepository
    case repositoryNotFound
    case repositoryIDMismatch
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case providerUnavailable
    case server(status: Int, code: String?, message: String)
    case transport(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .privateRepository:
            return "Private repositories must not use the public star history service."
        case .invalidRepository:
            return "Invalid repository identity."
        case .repositoryNotFound:
            return "Repository was not found."
        case .repositoryIDMismatch:
            return "Repository ID does not match owner/name."
        case .unauthorized:
            return "Star history service authentication failed."
        case .rateLimited:
            return "Star history service is temporarily rate limited."
        case .providerUnavailable:
            return "Star history provider is unavailable."
        case .server(let status, let code, let message):
            return "[\(code ?? "HTTP_\(status)")] \(message)"
        case .transport(let message), .decoding(let message):
            return message
        }
    }
}

protocol StarHistoryAPIProtocol: Sendable {
    func fetch(
        request: StarHistoryRequest,
        range: StarHistoryRange,
        ifNoneMatch: String?
    ) async throws -> StarHistoryAPIResult
}

actor StarHistoryAPI: StarHistoryAPIProtocol {
    private static let timeout: TimeInterval = 15
    private static let defaultRetryAfter: TimeInterval = 5

    private var baseURL: URL
    private var apiKey: String?
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let rfc3339Formatter: ISO8601DateFormatter
    private let fractionalRFC3339Formatter: ISO8601DateFormatter

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

        let rfc3339 = ISO8601DateFormatter()
        rfc3339.formatOptions = [.withInternetDateTime]
        rfc3339Formatter = rfc3339

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalRFC3339Formatter = fractional
    }

    func updateBaseURL(_ url: URL) {
        baseURL = url
    }

    func updateAPIKey(_ key: String?) {
        apiKey = key
    }

    func fetch(
        request: StarHistoryRequest,
        range: StarHistoryRange,
        ifNoneMatch: String?
    ) async throws -> StarHistoryAPIResult {
        guard !request.isPrivate else {
            throw StarHistoryAPIError.privateRepository
        }
        guard request.repoID > 0,
              isValidPathPart(request.owner),
              isValidPathPart(request.name)
        else {
            throw StarHistoryAPIError.invalidRepository
        }

        let path = AppEndpoints.Discovery.Paths.starHistory(
            owner: request.owner,
            repo: request.name
        )
        let endpoint = AppEndpoints.appendPath(path, to: baseURL)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw StarHistoryAPIError.invalidRepository
        }
        components.queryItems = [
            URLQueryItem(name: "repo_id", value: String(request.repoID)),
            URLQueryItem(name: "range", value: range.rawValue)
        ]
        guard let url = components.url else {
            throw StarHistoryAPIError.invalidRepository
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let ifNoneMatch, !ifNoneMatch.isEmpty {
            urlRequest.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            let result = try await session.data(for: urlRequest)
            data = result.0
            guard let http = result.1 as? HTTPURLResponse else {
                throw StarHistoryAPIError.transport(URLError(.badServerResponse).localizedDescription)
            }
            response = http
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as StarHistoryAPIError {
            throw error
        } catch {
            throw StarHistoryAPIError.transport(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            return try decodeReady(data: data, response: response)
        case 202:
            return .building(retryAfter: retryAfter(from: response) ?? Self.defaultRetryAfter)
        case 304:
            return .notModified(etag: response.value(forHTTPHeaderField: "ETag") ?? ifNoneMatch)
        default:
            throw mapError(data: data, response: response)
        }
    }

    private func decodeReady(
        data: Data,
        response: HTTPURLResponse
    ) throws -> StarHistoryAPIResult {
        let envelope: StarcatEnvelope<StarHistoryResponseDTO>
        do {
            envelope = try decoder.decode(StarcatEnvelope<StarHistoryResponseDTO>.self, from: data)
        } catch {
            throw StarHistoryAPIError.decoding(error.localizedDescription)
        }

        let dto = envelope.data
        guard dto.repoID > 0,
              dto.currentStars >= 0,
              let range = StarHistoryRange(rawValue: dto.range),
              let generatedAt = parseRFC3339(dto.generatedAt)
        else {
            throw StarHistoryAPIError.decoding("Invalid star history response metadata.")
        }
        let points = try dto.points.map { point -> StarHistoryPoint in
            guard point.count >= 0,
                  let date = StarHistoryDateCodec.date(from: point.date),
                  let source = StarHistorySource(rawValue: point.source),
                  source.isRemote,
                  let precision = StarHistoryPrecision(rawValue: point.precision)
            else {
                throw StarHistoryAPIError.decoding("Invalid star history point.")
            }
            return StarHistoryPoint(
                date: date,
                count: point.count,
                source: source,
                precision: precision,
                fetchedAt: generatedAt
            )
        }
        let coverageStart = dto.coverageStart.flatMap(StarHistoryDateCodec.date(from:))
        return .ready(
            series: StarHistoryRemoteSeries(
                repoID: dto.repoID,
                fullName: dto.fullName,
                currentStars: dto.currentStars,
                range: range,
                coverageStart: coverageStart,
                generatedAt: generatedAt,
                points: points.sorted { $0.date < $1.date }
            ),
            etag: response.value(forHTTPHeaderField: "ETag")
        )
    }

    private func mapError(data: Data, response: HTTPURLResponse) -> StarHistoryAPIError {
        let envelope = try? decoder.decode(StarcatErrorEnvelope.self, from: data)
        let code = envelope?.error.code
        let message = envelope?.error.message
            ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        switch response.statusCode {
        case 400:
            return .invalidRepository
        case 401:
            return .unauthorized
        case 404:
            return .repositoryNotFound
        case 409:
            return .repositoryIDMismatch
        case 422:
            return .privateRepository
        case 429:
            return .rateLimited(retryAfter: retryAfter(from: response))
        case 503:
            return .providerUnavailable
        default:
            return .server(status: response.statusCode, code: code, message: message)
        }
    }

    private func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    }

    private func parseRFC3339(_ value: String) -> Date? {
        fractionalRFC3339Formatter.date(from: value) ?? rfc3339Formatter.date(from: value)
    }

    /// GitHub owner / repo path 只允许公共 API 已接受的稳定字符，避免 path component 注入。
    private func isValidPathPart(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first)
        else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

private struct StarHistoryResponseDTO: Decodable, Sendable {
    let repoID: Int64
    let fullName: String
    let currentStars: Int
    let range: String
    let coverageStart: String?
    let generatedAt: String
    let points: [StarHistoryPointDTO]

    enum CodingKeys: String, CodingKey {
        case repoID = "repo_id"
        case fullName = "full_name"
        case currentStars = "current_stars"
        case range
        case coverageStart = "coverage_start"
        case generatedAt = "generated_at"
        case points
    }
}

private struct StarHistoryPointDTO: Decodable, Sendable {
    let date: String
    let count: Int
    let source: String
    let precision: String
}
