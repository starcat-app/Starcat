//
//  OpenSSFScoreAPI.swift
//  Starcat
//
//  OpenSSF Scorecard 公开 REST API 客户端。
//
//  设计约束：
//  - 这是 OpenSSF 独立公开端点，不走 GitHub token，也不复用 GitHubAPIClient。
//  - 默认域名使用官方当前推荐的 `api.scorecard.dev`；旧
//    `api.securityscorecards.dev` 目前可访问，但不作为新代码主路径。
//  - 404 是业务态 notIndexed，需要落库冷却，不等同于网络失败。
//

import Foundation

actor OpenSSFScoreAPI {
    private static let timeout: TimeInterval = 30

    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(
        baseURL: URL = URL(string: "https://api.scorecard.dev")!,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
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

    func fetch(owner: String, repo: String) async throws -> OpenSSFScoreAPIResponse {
        guard Self.isValidRepoPart(owner), Self.isValidRepoPart(repo) else {
            throw OpenSSFScoreAPIError.invalidURL
        }

        let url = baseURL
            .appendingPathComponent("projects")
            .appendingPathComponent("github.com")
            .appendingPathComponent(owner)
            .appendingPathComponent(repo)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Starcat/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw OpenSSFScoreAPIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenSSFScoreAPIError.transport(String.l10n("network.error.invalidResponse"))
        }
        switch http.statusCode {
        case 200..<300:
            do {
                let payload = try decoder.decode(OpenSSFScorePayload.self, from: data)
                return OpenSSFScoreAPIResponse(payload: payload, rawData: data)
            } catch {
                throw OpenSSFScoreAPIError.decoding(error.localizedDescription)
            }
        case 404:
            throw OpenSSFScoreAPIError.notIndexed
        default:
            throw OpenSSFScoreAPIError.serverError(statusCode: http.statusCode)
        }
    }

    /// GitHub owner/repo 的保守字符集校验，提前挡空值和明显非法输入。
    private static func isValidRepoPart(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
