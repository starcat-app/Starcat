//
//  WikiAPI.swift
//  Starcat
//
//  starcat-wiki-api 客户端。首期只接单仓库查询，不接异步 batch/admin 端点。
//
//  设计约束：
//  - actor 独立持有 baseURL / API Key，设置页修改后通过 update 方法热生效。
//  - 请求使用 URLComponents + URLQueryItem，避免 owner/repo 中的字符破坏 query。
//  - 错误统一保留为 StarcatEnvelopeNetworkError，调用 UI 只做静默降级，不影响其他服务。
//

import Foundation

/// 外部 Wiki 索引服务客户端。
actor WikiAPI {
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

    /// 查询一个 GitHub 仓库在三个外部 Wiki 来源中的收录状态。
    func fetchStatus(owner: String, repo: String) async throws -> [WikiStatusItem] {
        guard Self.isValidRepoPart(owner), Self.isValidRepoPart(repo) else {
            throw StarcatEnvelopeNetworkError.invalidURL
        }

        let endpoint = AppEndpoints.appendPath(AppEndpoints.Wiki.Paths.status, to: baseURL)
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "owner", value: owner),
            URLQueryItem(name: "repo", value: repo)
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
        StarcatGatewayRouting.applyServiceHeader(to: &request, service: .wiki)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw StarcatEnvelopeNetworkError.transport(error)
        }

        return try StarcatEnvelopeDecoder.decode(
            [WikiStatusItem].self,
            data: data,
            response: response,
            decoder: decoder
        )
    }

    /// 设置页修改服务地址后热更新；下一次请求立即使用新地址。
    func updateBaseURL(_ url: URL) {
        baseURL = url
    }

    /// 设置页修改 BYOK 后热更新。
    func updateAPIKey(_ key: String?) {
        apiKey = key
    }

    /// GitHub owner/repo 的保守字符集校验，提前拦截空值和明显非法输入。
    private static func isValidRepoPart(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
