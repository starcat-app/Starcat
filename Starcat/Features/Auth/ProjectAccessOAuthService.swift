//
//  ProjectAccessOAuthService.swift
//  Starcat
//
//  “我的项目”GitHub App user access token 的 Device Flow 与刷新实现。
//
//  安全边界：
//  - 客户端只持有公开 Client ID；不包含 GitHub App private key 或 client secret；
//  - Device Flow 生成的 refresh token 可按 GitHub 契约仅凭 client_id 刷新；
//  - access / refresh token 只作为返回值交给独立安全存储，不写日志或数据库；
//  - 错误只暴露稳定分类，不拼接可能含 token 的响应 body。
//

import Foundation

struct ProjectAccessCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let accessExpiresAt: Date?
    let refreshToken: String?
    let refreshExpiresAt: Date?
}

enum ProjectAccessOAuthError: Error, Equatable {
    case configurationMissing
    case flowNotStarted
    case codeExpired
    case userDeclined
    case badRefreshToken
    case httpStatus(Int)
    case invalidResponse
    case network
}

protocol ProjectAccessOAuthServiceProtocol: Sendable {
    func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo
    func awaitCredential() async throws -> ProjectAccessCredential
    func refreshCredential(using refreshToken: String) async throws -> ProjectAccessCredential
    func reset() async
}

actor ProjectAccessOAuthService: ProjectAccessOAuthServiceProtocol {
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private let clientID: String
    private let session: URLSession
    private let oauthBaseURL: URL
    private let now: @Sendable () -> Date
    private let sleep: Sleep

    private var deviceCode: String?
    private var pollInterval: TimeInterval = 5
    private var expiresAt: Date?

    init(
        clientID: String = AppConstants.githubAppClientID,
        session: URLSession = .shared,
        oauthBaseURL: URL = AppEndpoints.GitHubOAuth.baseURL,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping Sleep = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.oauthBaseURL = oauthBaseURL
        self.now = now
        self.sleep = sleep
    }

    func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo {
        guard !clientID.isEmpty else {
            throw ProjectAccessOAuthError.configurationMissing
        }
        let payload = try await post(
            path: AppEndpoints.GitHubOAuth.Paths.deviceCode,
            body: ["client_id": clientID]
        )
        let response: DeviceCodeResponse
        do {
            response = try JSONDecoder().decode(DeviceCodeResponse.self, from: payload)
        } catch {
            throw ProjectAccessOAuthError.invalidResponse
        }
        guard let verificationURI = URL(string: response.verificationUri) else {
            throw ProjectAccessOAuthError.invalidResponse
        }

        deviceCode = response.deviceCode
        pollInterval = max(1, TimeInterval(response.interval))
        expiresAt = now().addingTimeInterval(TimeInterval(response.expiresIn))
        return OAuthDeviceCodeInfo(
            userCode: response.userCode,
            verificationURI: verificationURI,
            expiresIn: TimeInterval(response.expiresIn),
            pollInterval: pollInterval
        )
    }

    func awaitCredential() async throws -> ProjectAccessCredential {
        guard let deviceCode, let expiresAt else {
            throw ProjectAccessOAuthError.flowNotStarted
        }
        while now() < expiresAt {
            try Task.checkCancellation()
            try await sleep(pollInterval)
            let payload = try await post(
                path: AppEndpoints.GitHubOAuth.Paths.accessToken,
                body: [
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                ]
            )
            switch try decodeTokenResult(payload) {
            case .credential(let credential):
                reset()
                return credential
            case .pending:
                continue
            case .slowDown:
                pollInterval += 5
            case .expired:
                reset()
                throw ProjectAccessOAuthError.codeExpired
            case .denied:
                reset()
                throw ProjectAccessOAuthError.userDeclined
            case .badRefreshToken:
                throw ProjectAccessOAuthError.invalidResponse
            }
        }
        reset()
        throw ProjectAccessOAuthError.codeExpired
    }

    func refreshCredential(using refreshToken: String) async throws -> ProjectAccessCredential {
        guard !clientID.isEmpty else {
            throw ProjectAccessOAuthError.configurationMissing
        }
        let payload = try await post(
            path: AppEndpoints.GitHubOAuth.Paths.accessToken,
            body: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]
        )
        switch try decodeTokenResult(payload) {
        case .credential(let credential):
            return credential
        case .badRefreshToken, .expired:
            throw ProjectAccessOAuthError.badRefreshToken
        default:
            throw ProjectAccessOAuthError.invalidResponse
        }
    }

    func reset() {
        deviceCode = nil
        expiresAt = nil
        pollInterval = 5
    }

    private func post(path: String, body: [String: String]) async throws -> Data {
        let url = AppEndpoints.appendPath(path, to: oauthBaseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProjectAccessOAuthError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ProjectAccessOAuthError.httpStatus(http.statusCode)
            }
            return data
        } catch let error as ProjectAccessOAuthError {
            throw error
        } catch {
            throw ProjectAccessOAuthError.network
        }
    }

    private enum TokenResult {
        case credential(ProjectAccessCredential)
        case pending
        case slowDown
        case expired
        case denied
        case badRefreshToken
    }

    private func decodeTokenResult(_ data: Data) throws -> TokenResult {
        let response: TokenResponse
        do {
            response = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw ProjectAccessOAuthError.invalidResponse
        }
        if let accessToken = response.accessToken, !accessToken.isEmpty {
            return .credential(ProjectAccessCredential(
                accessToken: accessToken,
                accessExpiresAt: response.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) },
                refreshToken: response.refreshToken,
                refreshExpiresAt: response.refreshTokenExpiresIn.map {
                    now().addingTimeInterval(TimeInterval($0))
                }
            ))
        }
        return switch response.error {
        case "authorization_pending": .pending
        case "slow_down": .slowDown
        case "expired_token": .expired
        case "access_denied": .denied
        case "bad_refresh_token": .badRefreshToken
        default: throw ProjectAccessOAuthError.invalidResponse
        }
    }

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

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let expiresIn: Int?
        let refreshToken: String?
        let refreshTokenExpiresIn: Int?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case refreshTokenExpiresIn = "refresh_token_expires_in"
            case error
        }
    }
}
