//
//  GithubDeviceFlowService.swift
//  Starcat
//
//  Device Flow 真实实现。
//
//  注意：
//  - GitHub 的 Device Flow 端点在 `github.com`（不是 api.github.com）
//  - 必须显式 `Accept: application/json`，否则默认返回 url-encoded
//  - 轮询 access token 时，GitHub 错误码并不是 HTTP 4xx，而是 200 + body 里的 `error` 字段
//  - 用户必须在 OAuth App 设置中启用 "Enable Device Flow"
//
//  当前状态：Constants.swift 中 Client ID 是占位，调用 beginDeviceFlow 会被 GitHub 拒
//  待 OAuth App 注册完成 + 启用 Device Flow + 填入真 Client ID 后即可用。
//

import Foundation

/// 真实 Device Flow 实现。
///
/// 状态机：
/// - idle → beginDeviceFlow → waitingForUser → awaitAccessToken → completed
/// - 可以通过 reset() 回到 idle
actor GithubDeviceFlowService: GithubOAuthServiceProtocol {

    // MARK: - 配置

    private let clientID: String
    private let scopes: [String]
    private let session: URLSession
    /// OAuth 主域 root。2026-06-08 起改为引用 `AppEndpoints.GitHubOAuth.baseURL`
    /// 集中管理，不再保留本地 hardcoded URL。
    private let oauthBaseURL: URL = AppEndpoints.GitHubOAuth.baseURL

    // MARK: - 流程状态

    /// beginDeviceFlow 阶段返回的 deviceCode，awaitAccessToken 需要使用。
    private var deviceCode: String?
    /// 当前轮询间隔（秒），slow_down 时会增大。
    private var pollInterval: TimeInterval = 5
    /// device_code 过期截止时间。
    private var expiresAt: Date?

    // MARK: - 初始化

    init(
        clientID: String = AppConstants.githubOAuthClientID,
        scopes: [String] = AppConstants.githubOAuthScopes,
        session: URLSession = .shared
    ) {
        self.clientID = clientID
        self.scopes = scopes
        self.session = session
    }

    // MARK: - 阶段 1：获取 user_code

    func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo {
        guard !clientID.isEmpty, !clientID.hasPrefix("<") else {
            throw GithubOAuthError.configurationMissing(reason: String(localized: "auth.error.clientIdMissing"))
        }

        let url = AppEndpoints.appendPath(AppEndpoints.GitHubOAuth.Paths.deviceCode, to: oauthBaseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "client_id": clientID,
            "scope": scopes.joined(separator: " ")
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        AppLog.auth.info("Device Flow: requesting device code (client_id_prefix=\(self.clientID.prefix(8), privacy: .public))")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GithubOAuthError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GithubOAuthError.unexpectedResponse(message: "HTTP \(status): \(String(data: data, encoding: .utf8) ?? "")")
        }

        let decoded: DeviceCodeResponse
        do {
            decoded = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch {
            throw GithubOAuthError.unexpectedResponse(message: "Cannot decode device code response: \(error.localizedDescription)")
        }

        // 保存到 actor 状态
        self.deviceCode = decoded.deviceCode
        self.pollInterval = max(1, TimeInterval(decoded.interval))
        self.expiresAt = Date().addingTimeInterval(TimeInterval(decoded.expiresIn))

        guard let verificationURL = URL(string: decoded.verificationUri) else {
            throw GithubOAuthError.unexpectedResponse(message: "Invalid verification_uri: \(decoded.verificationUri)")
        }

        AppLog.auth.info("Device Flow: got user_code=\(decoded.userCode, privacy: .public), interval=\(decoded.interval, privacy: .public)s, expires_in=\(decoded.expiresIn, privacy: .public)s")

        return OAuthDeviceCodeInfo(
            userCode: decoded.userCode,
            verificationURI: verificationURL,
            expiresIn: TimeInterval(decoded.expiresIn),
            pollInterval: pollInterval
        )
    }

    // MARK: - 阶段 2：轮询 access token

    func awaitAccessToken() async throws -> String {
        guard let deviceCode = self.deviceCode else {
            throw GithubOAuthError.configurationMissing(reason: String(localized: "auth.error.deviceFlowNotStarted"))
        }
        guard let expiresAt = self.expiresAt else {
            throw GithubOAuthError.configurationMissing(reason: String(localized: "auth.error.expiresAtMissing"))
        }

        while true {
            try Task.checkCancellation()

            if Date() >= expiresAt {
                throw GithubOAuthError.codeExpired
            }

            // 等待 pollInterval
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))

            try Task.checkCancellation()

            let result = try await pollOnce(deviceCode: deviceCode)
            switch result {
            case .token(let token):
                AppLog.auth.info("Device Flow: received access token")
                return token
            case .pending:
                continue
            case .slowDown:
                pollInterval += 5
                AppLog.auth.info("Device Flow: slow_down, interval -> \(self.pollInterval, privacy: .public)s")
            case .expired:
                throw GithubOAuthError.codeExpired
            case .denied:
                throw GithubOAuthError.userDeclined
            }
        }
    }

    // MARK: - reset

    func reset() {
        deviceCode = nil
        expiresAt = nil
        pollInterval = 5
    }

    // MARK: - 内部：单次轮询

    private enum PollResult {
        case token(String)
        case pending
        case slowDown
        case expired
        case denied
    }

    private func pollOnce(deviceCode: String) async throws -> PollResult {
        let url = AppEndpoints.appendPath(AppEndpoints.GitHubOAuth.Paths.accessToken, to: oauthBaseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch {
            throw GithubOAuthError.network(underlying: error)
        }

        // GitHub Device Flow 在错误时也返回 200，需看 body 里的 error 字段
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GithubOAuthError.unexpectedResponse(message: "Non-JSON poll response")
        }

        if let accessToken = json["access_token"] as? String, !accessToken.isEmpty {
            return .token(accessToken)
        }

        let errorCode = (json["error"] as? String) ?? ""
        switch errorCode {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "expired_token": return .expired
        case "access_denied": return .denied
        default:
            let desc = (json["error_description"] as? String) ?? errorCode
            throw GithubOAuthError.unexpectedResponse(message: "Unknown poll error: \(desc)")
        }
    }

    // MARK: - 内部：DTO

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationUri = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }
}
