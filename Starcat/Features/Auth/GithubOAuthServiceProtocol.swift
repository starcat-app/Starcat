//
//  GithubOAuthServiceProtocol.swift
//  Starcat
//
//  OAuth Service 协议 + 共享数据类型。
//
//  Device Flow 流程（GitHub 官方文档）：
//
//  1. POST https://github.com/login/device/code
//     body: { client_id, scope }
//     resp: { device_code, user_code, verification_uri, expires_in, interval }
//
//  2. UI 展示 user_code，引导用户在浏览器打开 verification_uri 并输入
//
//  3. 客户端按 interval 秒间隔轮询 POST https://github.com/login/oauth/access_token
//     body: { client_id, device_code, grant_type=urn:ietf:params:oauth:grant-type:device-code }
//     可能响应：
//       - authorization_pending: 用户还未授权，继续轮询
//       - slow_down: 加大间隔（GitHub 要求 interval += 5）
//       - expired_token: device_code 过期，需重新发起
//       - access_denied: 用户拒绝
//       - 成功: { access_token, token_type, scope }
//
//  协议保持中性：不依赖具体流程，便于 PKCE / 服务端中转等替代实现。
//

import Foundation

/// Device Flow 起步阶段返回的展示信息。
struct OAuthDeviceCodeInfo: Equatable, Sendable {
    /// 显示给用户的 8-9 位 code（用户在浏览器中输入）。
    let userCode: String
    /// 用户应该打开的 URL。
    let verificationURI: URL
    /// 距离 device_code 过期还有多少秒。
    let expiresIn: TimeInterval
    /// 客户端轮询的最小间隔（秒）。
    let pollInterval: TimeInterval
}

/// 2026-06-29 Web Application Flow 起步阶段返回的展示信息。
///
/// 专用于 PKCE Authorization Code Flow（区别于 Device Flow）：
/// - Device Flow 起步返回的是「user_code」+ verification URL（用户去 GitHub 输 code）
/// - Web Flow 起步返回的是「直接可打开的 authorization URL」（GitHub 处理完后回调
///   `starcat://callback?code=...&state=...`）
///
/// `state` 防 CSRF：GitHub 回调时会回传，必须本地校验一致才接受 code。
/// `expiresAt` 兜底：超过这个时间仍未收到回调视为过期。
struct WebFlowStartInfo: Equatable, Sendable {
    /// 给用户浏览器打开的 /login/oauth/authorize URL（已带 client_id / scope / code_challenge / state / redirect_uri）
    let authorizationURL: URL
    /// 本次会话的 state（GitHub 回调时回传），用于防 CSRF
    let state: String
    /// state 过期截止时间（默认 5 分钟）
    let expiresAt: Date
}

/// OAuth 错误。
enum GithubOAuthError: Error, LocalizedError {
    case configurationMissing(reason: String)
    case userDeclined
    case codeExpired
    case network(underlying: Error)
    case unexpectedResponse(message: String)

    var errorDescription: String? {
        switch self {
        case .configurationMissing(let reason):
            return String(format: String.l10n("auth.error.configurationMissingFormat"), reason)
        case .userDeclined:
            return String.l10n("auth.error.userDeclined")
        case .codeExpired:
            return String.l10n("auth.error.codeExpired")
        case .network(let error):
            return String(format: String.l10n("auth.error.networkFormat"), error.localizedDescription)
        case .unexpectedResponse(let msg):
            return String(format: String.l10n("auth.error.unexpectedResponseFormat"), msg)
        }
    }
}

/// OAuth Service 协议。
///
/// 暴露两阶段方法以便 UI 在第一阶段拿到 user_code 后展示给用户，
/// 第二阶段（轮询）由 UI 在用户已知晓 user_code 后再启动。
///
/// 2026-06-29：扩展支持 Web Application Flow（PKCE），新增 3 个方法
/// `beginWebFlow` / `exchangeCodeForToken` / `resetWebFlow`。
/// Device Flow 的 3 个方法保持不变。
protocol GithubOAuthServiceProtocol: Sendable {
    // MARK: - Device Flow（既有，2026-05 落地）

    /// 阶段 1：发起 Device Flow，获取 user_code 等展示信息。
    /// 内部不开始轮询。
    func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo

    /// 阶段 2：等待用户授权，返回 access token。
    /// 调用方应当传入第一阶段返回的 deviceInfo（实现可能需要 deviceCode）。
    /// 此方法**会阻塞直到拿到 token 或抛错**；调用方应在 Task 中调用并支持取消。
    func awaitAccessToken() async throws -> String

    /// 重置内部状态（用户取消、错误重试时调用）。
    func reset() async

    // MARK: - Web Application Flow / PKCE（2026-06-29 新增）

    /// 阶段 1：生成 PKCE verifier/challenge + state + 完整 authorization URL。
    ///
    /// 纯本地计算（SecRandomCopyBytes + SHA256 + URL 拼装），不发起任何网络请求——
    /// `/login/oauth/authorize` 是 Web 授权端点，客户端只负责构造 URL。
    ///
    /// 返回的 `WebFlowStartInfo`：
    /// - `authorizationURL` 交给 `ASWebAuthenticationSession` 展示系统认证页
    /// - `state` 必须保存（用于校验 callback 回来的 state 防 CSRF）
    /// - `expiresAt` 兜底（超过 5 分钟未收到回调视为过期）
    func beginWebFlow() async throws -> WebFlowStartInfo

    /// 阶段 2：用 GitHub 回调 URL 里的 `code` 换 `access_token`。
    ///
    /// 实现内部已保存 `code_verifier`，调用方**不**传 verifier——避免 verifier 离开 actor 边界。
    /// 此方法会：
    /// 1. POST `/login/oauth/access_token` with `client_id` + `code` + `code_verifier`
    /// 2. 解码响应里的 `access_token` 并返回
    ///
    /// 失败抛错：401（code 过期）→ `GithubOAuthError.codeExpired` / 网络错 / unexpected response。
    func exchangeCodeForToken(code: String) async throws -> String

    /// 重置 Web Flow 内部状态（verifier / state），用户取消或错误重试时调用。
    func resetWebFlow() async
}
