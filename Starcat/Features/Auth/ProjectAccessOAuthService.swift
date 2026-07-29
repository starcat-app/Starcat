//
//  ProjectAccessOAuthService.swift
//  Starcat
//
//  “我的项目”GitHub App 安装期间 OAuth 回调、token 交换与刷新实现。
//
//  安全边界：
//  - 现有 Starcat 登录 OAuth / Device Flow 完全独立，本服务只管理 GitHub App user token；
//  - 安装 URL 携带一次性随机 state，回调必须同时匹配 scheme、host、path 和 state；
//  - macOS 原生应用属于 public client，Client Secret 无法真正隐藏，只用于 user token；
//  - GitHub App private key 权限更大，严禁进入客户端；
//  - access / refresh token 只作为返回值交给 Keychain，不写日志或数据库。
//

import Foundation
import Security

struct ProjectAccessCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let accessExpiresAt: Date?
    let refreshToken: String?
    let refreshExpiresAt: Date?
}

struct ProjectAccessAuthorizationInfo: Equatable, Sendable {
    let installationURL: URL
    let expiresAt: Date
}

enum ProjectAccessOAuthError: Error, Equatable {
    case configurationMissing
    case flowNotStarted
    case codeExpired
    case userDeclined
    case badRefreshToken
    case invalidCallback
    case stateMismatch
    case httpStatus(Int)
    case invalidResponse
    case network
}

protocol ProjectAccessOAuthServiceProtocol: Sendable {
    func beginAuthorization() async throws -> ProjectAccessAuthorizationInfo
    func exchangeCallback(_ callbackURL: URL) async throws -> ProjectAccessCredential
    func refreshCredential(using refreshToken: String) async throws -> ProjectAccessCredential
    func reset() async
}

actor ProjectAccessOAuthService: ProjectAccessOAuthServiceProtocol {
    typealias StateGenerator = @Sendable () throws -> String

    private let clientID: String
    private let clientSecret: String
    private let appSlug: String
    private let callbackURL: URL
    private let session: URLSession
    private let oauthBaseURL: URL
    private let now: @Sendable () -> Date
    private let stateGenerator: StateGenerator

    private var storedState: String?
    private var expiresAt: Date?

    init(
        clientID: String = AppConstants.githubAppClientID,
        clientSecret: String = AppConstants.githubAppClientSecret,
        appSlug: String = AppConstants.githubAppSlug,
        callbackURL: URL = URL(string: AppConstants.githubAppCallbackURL)!,
        session: URLSession = .shared,
        oauthBaseURL: URL = AppEndpoints.GitHubOAuth.baseURL,
        now: @escaping @Sendable () -> Date = Date.init,
        stateGenerator: @escaping StateGenerator = ProjectAccessOAuthService.generateState
    ) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appSlug = appSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        self.callbackURL = callbackURL
        self.session = session
        self.oauthBaseURL = oauthBaseURL
        self.now = now
        self.stateGenerator = stateGenerator
    }

    /// 创建“安装 GitHub App + 用户授权”的单次浏览器流程。
    ///
    /// GitHub 的 installation URL 会把 `state` 原样带回安装后的 OAuth callback。
    /// 自动安装授权由 GitHub 发起 `/login/oauth/authorize`，客户端不能在该中转请求里
    /// 追加 PKCE challenge，因此这里用强随机 state 防止伪造回调，并在 token 交换时
    /// 同时提交 Client Secret。该限制只属于 GitHub App 安装联动，不影响主登录 PKCE。
    func beginAuthorization() throws -> ProjectAccessAuthorizationInfo {
        guard !clientID.isEmpty,
              !clientSecret.isEmpty,
              !appSlug.isEmpty
        else {
            throw ProjectAccessOAuthError.configurationMissing
        }

        let state = try stateGenerator()
        guard !state.isEmpty,
              let installationURL = AppConstants.makeGitHubAppInstallationURL(
                slug: appSlug,
                state: state
              )
        else {
            throw ProjectAccessOAuthError.configurationMissing
        }

        let expiresAt = now().addingTimeInterval(15 * 60)
        storedState = state
        self.expiresAt = expiresAt
        return ProjectAccessAuthorizationInfo(
            installationURL: installationURL,
            expiresAt: expiresAt
        )
    }

    /// 校验 GitHub App callback，并用一次性 code 换取独立项目凭据。
    func exchangeCallback(_ callbackURL: URL) async throws -> ProjectAccessCredential {
        guard callbackURL.scheme == self.callbackURL.scheme,
              callbackURL.host == self.callbackURL.host,
              callbackURL.path == self.callbackURL.path
        else {
            throw ProjectAccessOAuthError.invalidCallback
        }
        guard let expectedState = storedState, let expiresAt else {
            throw ProjectAccessOAuthError.flowNotStarted
        }
        guard now() < expiresAt else {
            reset()
            throw ProjectAccessOAuthError.codeExpired
        }

        let queryItems = URLComponents(
            url: callbackURL,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        let parameters = Dictionary(
            queryItems.map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        // 拒绝回调也必须先校验 state；否则第三方可以伪造 access_denied，
        // 提前清空当前授权上下文，形成登录 CSRF / 拒绝服务。
        guard parameters["state"] == expectedState else {
            throw ProjectAccessOAuthError.stateMismatch
        }
        if parameters["error"] == "access_denied" {
            reset()
            throw ProjectAccessOAuthError.userDeclined
        }
        guard let code = parameters["code"], !code.isEmpty else {
            throw ProjectAccessOAuthError.invalidCallback
        }

        let payload = try await postToken(body: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "code": code,
            "redirect_uri": self.callbackURL.absoluteString
        ])
        let credential = try decodeCredential(payload)
        reset()
        return credential
    }

    /// Web Flow 产生的 refresh token 轮换时必须同时携带 Client Secret。
    func refreshCredential(using refreshToken: String) async throws -> ProjectAccessCredential {
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw ProjectAccessOAuthError.configurationMissing
        }
        let payload = try await postToken(body: [
            "client_id": clientID,
            "client_secret": clientSecret,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
        do {
            return try decodeCredential(payload)
        } catch ProjectAccessOAuthError.badRefreshToken {
            throw ProjectAccessOAuthError.badRefreshToken
        } catch {
            throw error
        }
    }

    func reset() {
        storedState = nil
        expiresAt = nil
    }

    private func postToken(body: [String: String]) async throws -> Data {
        let url = AppEndpoints.appendPath(
            AppEndpoints.GitHubOAuth.Paths.accessToken,
            to: oauthBaseURL
        )
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

    private func decodeCredential(_ data: Data) throws -> ProjectAccessCredential {
        let response: TokenResponse
        do {
            response = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw ProjectAccessOAuthError.invalidResponse
        }
        if let accessToken = response.accessToken, !accessToken.isEmpty {
            return ProjectAccessCredential(
                accessToken: accessToken,
                accessExpiresAt: response.expiresIn.map {
                    now().addingTimeInterval(TimeInterval($0))
                },
                refreshToken: response.refreshToken,
                refreshExpiresAt: response.refreshTokenExpiresIn.map {
                    now().addingTimeInterval(TimeInterval($0))
                }
            )
        }
        switch response.error {
        case "access_denied":
            throw ProjectAccessOAuthError.userDeclined
        case "bad_refresh_token", "expired_token":
            throw ProjectAccessOAuthError.badRefreshToken
        default:
            throw ProjectAccessOAuthError.invalidResponse
        }
    }

    /// 生成不可预测的 state；只在内存保存，成功、取消或过期后立即清理。
    private static func generateState() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else {
            throw ProjectAccessOAuthError.invalidResponse
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
