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
            return "OAuth 配置缺失：\(reason)"
        case .userDeclined:
            return "用户已拒绝授权"
        case .codeExpired:
            return "授权 code 已过期，请重新发起登录"
        case .network(let error):
            return "OAuth 网络错误：\(error.localizedDescription)"
        case .unexpectedResponse(let msg):
            return "GitHub 返回异常：\(msg)"
        }
    }
}

/// OAuth Service 协议。
///
/// 暴露两阶段方法以便 UI 在第一阶段拿到 user_code 后展示给用户，
/// 第二阶段（轮询）由 UI 在用户已知晓 user_code 后再启动。
protocol GithubOAuthServiceProtocol: Sendable {
    /// 阶段 1：发起 Device Flow，获取 user_code 等展示信息。
    /// 内部不开始轮询。
    func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo

    /// 阶段 2：等待用户授权，返回 access token。
    /// 调用方应当传入第一阶段返回的 deviceInfo（实现可能需要 deviceCode）。
    /// 此方法**会阻塞直到拿到 token 或抛错**；调用方应在 Task 中调用并支持取消。
    func awaitAccessToken() async throws -> String

    /// 重置内部状态（用户取消、错误重试时调用）。
    func reset() async
}
