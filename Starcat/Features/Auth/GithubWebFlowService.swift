//
//  GithubWebFlowService.swift
//  Starcat
//
//  2026-06-29 Web Application Flow (PKCE) 真实实现。
//
//  与 `GithubDeviceFlowService` 的区别：
//  - Device Flow 走 `urn:ietf:params:oauth:grant-type:device-code`，客户端**轮询** token
//  - Web Flow 走 Authorization Code + PKCE（RFC 7636），客户端**接收浏览器回调**
//    （macOS `starcat://callback?code=...&state=...`）后用 code + code_verifier 换 token
//
//  PKCE 协议三要素：
//  1. `code_verifier` — 客户端生成的 32 字节随机串（base64url），只保存在客户端
//  2. `code_challenge` — `base64url(SHA256(code_verifier))`，提交给 GitHub
//  3. `state` — 16 字节随机串，GitHub 回调时回传，必须本地校验一致（防 CSRF）
//
//  流程：
//  ① beginWebFlow() 生成 verifier + challenge + state + authorizationURL
//  ② UI 调 NSWorkspace.open(authorizationURL) 让用户在浏览器授权
//  ③ GitHub 跳到 starcat://callback?code=...&state=... → macOS 唤起 App
//  ④ AuthSession.handleWebFlowCallback(url:) 调 exchangeCodeForToken(code:)
//  ⑤ POST /login/oauth/access_token with code + code_verifier → access_token
//
//  关键约束：
//  - `code_verifier` 绝不离开 actor 边界（exchangeCodeForToken 内部使用，签名不暴露 verifier）
//  - `state` 校验失败必须拒绝（防 CSRF 攻击）
//  - `expiresAt` 之后未收到回调视为过期（GitHub code 寿命 10 分钟）
//  - URLSession 走默认（无需 GitHubAuthRedirectDelegate，因为 authorize 是浏览器端点）
//

import Foundation
import CryptoKit

/// 真实 Web Application Flow (PKCE) 实现。
actor GithubWebFlowService: GithubOAuthServiceProtocol {

    // MARK: - 配置

    private let clientID: String
    private let scopes: [String]
    private let session: URLSession
    private let oauthBaseURL: URL = AppEndpoints.GitHubOAuth.baseURL
    /// 2026-06-29 OAuth 回调 URL scheme（与 Info.plist CFBundleURLSchemes 一致）。
    private let callbackURL: URL = URL(string: AppConstants.oauthCallbackURL)!

    // MARK: - PKCE 状态（actor 内部，调用方不可访问）

    /// PKCE code_verifier（32 字节随机，base64url 编码）。
    /// 仅在 `exchangeCodeForToken` 阶段被使用，actor 边界外不可访问。
    private var codeVerifier: String?
    /// 防 CSRF 的随机 state，GitHub 回调时回传。
    private var storedState: String?
    /// state 过期时间（5 分钟）。
    private var expiresAt: Date?

    // MARK: - 初始化

    /// Web Flow 专用的 client secret（从 Info.plist `STARCAT_OAUTH_CLIENT_SECRET` 读取）。
    /// nil 时 token 交换会失败（GitHub OAuth App 要求 client_secret）。
    /// 通过 xcconfig 构建时注入，不提交到 git。
    private let clientSecret: String?

    init(
        clientID: String = AppConstants.githubOAuthClientID,
        scopes: [String] = AppConstants.githubOAuthScopes,
        session: URLSession = .shared
    ) {
        self.clientID = clientID
        self.clientSecret = Bundle.main.object(forInfoDictionaryKey: "STARCAT_OAUTH_CLIENT_SECRET") as? String
        self.scopes = scopes
        self.session = session

        if clientSecret?.isEmpty != false {
            AppLog.auth.warning("GithubWebFlowService: STARCAT_OAUTH_CLIENT_SECRET missing or empty — Web Flow token exchange will fail")
        }
    }

    // MARK: - Device Flow 协议（throw 拒绝，actor 不实现 Device Flow）

    func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo {
        throw GithubOAuthError.configurationMissing(reason: "Web Flow actor does not support Device Flow")
    }
    func awaitAccessToken() async throws -> String {
        throw GithubOAuthError.configurationMissing(reason: "Web Flow actor does not support Device Flow")
    }
    func reset() async { }

    // MARK: - 阶段 1：生成 PKCE 参数 + authorizationURL

    func beginWebFlow() async throws -> WebFlowStartInfo {
        guard !clientID.isEmpty, !clientID.hasPrefix("<") else {
            throw GithubOAuthError.configurationMissing(reason: String.l10n("auth.error.clientIdMissing"))
        }

        // 1. 生成 code_verifier (32 字节随机 → base64url)
        let verifier = try Self.generateCodeVerifier()
        // 2. 计算 code_challenge = base64url(SHA256(verifier))
        let challenge = Self.computeCodeChallenge(from: verifier)
        // 3. 生成 state (16 字节随机 → base64url)
        let state = try Self.generateState()

        // 4. 构造 authorizationURL
        //    GitHub OAuth Web Flow 必须带：client_id / scope / state / code_challenge / code_challenge_method=S256 / redirect_uri
        //    code_challenge_method 必须 = S256（GitHub 不支持 plain）
        var components = URLComponents(url: oauthBaseURL.appendingPathComponent("login/oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: callbackURL.absoluteString)
        ]
        guard let authorizationURL = components.url else {
            throw GithubOAuthError.unexpectedResponse(message: "Cannot construct authorization URL")
        }

        // 5. 保存到 actor 状态（actor 内部，外部无法访问）
        self.codeVerifier = verifier
        self.storedState = state
        self.expiresAt = Date().addingTimeInterval(5 * 60)  // 5 分钟

        AppLog.auth.info("Web Flow: PKCE generated (verifier_len=\(verifier.count, privacy: .public), state_len=\(state.count, privacy: .public), expires_in=300s)")

        return WebFlowStartInfo(
            authorizationURL: authorizationURL,
            state: state,
            expiresAt: self.expiresAt!
        )
    }

    // MARK: - 阶段 2：用 code + verifier 换 token

    func exchangeCodeForToken(code: String) async throws -> String {
        // OAuth App token 交换必须有 client_secret（PKCE 只保护 code，不替代 client auth）
        guard let secret = clientSecret, !secret.isEmpty else {
            throw GithubOAuthError.configurationMissing(reason: "Client secret not configured. Set STARCAT_OAUTH_CLIENT_SECRET in xcconfig.")
        }
        guard let verifier = codeVerifier else {
            throw GithubOAuthError.configurationMissing(reason: "Web Flow not started (no code_verifier)")
        }
        guard let _ = storedState else {
            throw GithubOAuthError.configurationMissing(reason: "Web Flow state missing")
        }
        guard let expires = expiresAt, Date() < expires else {
            throw GithubOAuthError.codeExpired
        }

        // 构造 POST /login/oauth/access_token 请求
        // body: client_id + code + code_verifier + grant_type=authorization_code
        let url = AppEndpoints.appendPath(AppEndpoints.GitHubOAuth.Paths.accessToken, to: oauthBaseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppConstants.httpUserAgent, forHTTPHeaderField: "User-Agent")

        // GitHub OAuth App token 交换要求同时带 client_secret + code_verifier。
        // PKCE 保护 authorization code 不被截获，client_secret 认证客户端身份——
        // 两者正交，OAuth App 必须都提供。GitHub App 可以只用 code_verifier。
        var body: [String: Any] = [
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": callbackURL.absoluteString,
            "grant_type": "authorization_code"
        ]
        if let secret = clientSecret, !secret.isEmpty {
            body["client_secret"] = secret
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        AppLog.auth.info("Web Flow: exchanging code for token (code_prefix=\(code.prefix(8), privacy: .public)...)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GithubOAuthError.network(underlying: error)
        }

        // GitHub Web Flow /login/oauth/access_token 响应格式：
        // - 成功：HTTP 200 + JSON { "access_token":"...", "scope":"...", "token_type":"..." }
        // - 失败：HTTP 200 + JSON { "error":"bad_verification_code", "error_description":"..." }
        //   或 HTTP 4xx + JSON/plain error
        // **不像 Device Flow** 的轮询 200 + body 里 error 字段；Web Flow 错误可能是
        // HTTP 4xx 也可能是 200 + JSON error。
        guard let http = response as? HTTPURLResponse else {
            throw GithubOAuthError.network(underlying: URLError(.badServerResponse))
        }
        let bodyStr = String(data: data, encoding: .utf8) ?? ""

        // 先尝试 JSON 解析（成功 + 错误都可能是 JSON）
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // 检查 error 字段（GitHub OAuth 错误码）
            if let errorCode = json["error"] as? String, !errorCode.isEmpty {
                let desc = json["error_description"] as? String ?? errorCode
                AppLog.auth.error("Web Flow: token exchange returned error: \(errorCode, privacy: .public) — \(desc, privacy: .public)")
                switch errorCode {
                case "bad_verification_code":
                    throw GithubOAuthError.codeExpired
                case "incorrect_client_credentials":
                    throw GithubOAuthError.configurationMissing(reason: "Invalid client_id")
                default:
                    throw GithubOAuthError.unexpectedResponse(message: "GitHub error (\(errorCode)): \(desc)")
                }
            }

            // 成功：access_token 必须存在
            if let token = json["access_token"] as? String, !token.isEmpty {
                AppLog.auth.info("Web Flow: received access token (length=\(token.count, privacy: .public))")
                self.codeVerifier = nil  // 一次性消费 verifier
                return token
            }

            // access_token 和 error 都没有 → 意外格式
            AppLog.auth.error("Web Flow: unexpected JSON response: \(bodyStr, privacy: .public)")
            throw GithubOAuthError.unexpectedResponse(message: "Unexpected JSON response (no access_token or error): \(bodyStr)")
        }

        // JSON 解析失败 → 尝试 URL-encoded（GitHub 某些错误走 form-urlencoded）
        let urlEncodedErr = parseOAuthErrorFromURLEncoded(bodyStr)
        if let err = urlEncodedErr {
            AppLog.auth.error("Web Flow: token exchange returned URL-encoded error: \(err, privacy: .public)")
            throw GithubOAuthError.unexpectedResponse(message: "GitHub error: \(err)")
        }

        // 非 200 状态码
        if !(200..<300).contains(http.statusCode) {
            AppLog.auth.error("Web Flow: token exchange HTTP \(http.statusCode, privacy: .public): \(bodyStr, privacy: .public)")
            if http.statusCode == 401 {
                throw GithubOAuthError.codeExpired
            }
            throw GithubOAuthError.unexpectedResponse(message: "HTTP \(http.statusCode): \(bodyStr)")
        }

        AppLog.auth.error("Web Flow: empty or unparseable response: \(bodyStr, privacy: .public)")
        throw GithubOAuthError.unexpectedResponse(message: "Empty or unparseable token response")
    }

    /// 从 URL-encoded 响应体里提取 error_description（GitHub 偶尔不走 JSON 错误）。
    private func parseOAuthErrorFromURLEncoded(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }
        // url-encoded 格式: error=xxx&error_description=yyy&error_uri=zzz
        let pairs = body.components(separatedBy: "&")
        for pair in pairs {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2, kv[0] == "error_description" {
                return kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        // 即使没有 error_description，只要有 error= 就返回它
        for pair in pairs {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2, kv[0] == "error" {
                return kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        return nil
    }

    // MARK: - reset

    func resetWebFlow() async {
        codeVerifier = nil
        storedState = nil
        expiresAt = nil
    }

    // MARK: - 内部：PKCE 算法

    /// 生成 32 字节随机 code_verifier，base64url 编码（无 padding）。
    private static func generateCodeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            throw GithubOAuthError.unexpectedResponse(message: "SecRandomCopyBytes failed: \(status)")
        }
        return Data(bytes).base64URLEncodedString()
    }

    /// 生成 16 字节随机 state，base64url 编码。
    private static func generateState() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            throw GithubOAuthError.unexpectedResponse(message: "SecRandomCopyBytes failed: \(status)")
        }
        return Data(bytes).base64URLEncodedString()
    }

    /// 计算 code_challenge = base64url(SHA256(verifier))。
    /// 必须用 SHA256，GitHub OAuth App 不支持 plain（即 SHA1 或明文）。
    private static func computeCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }

}
