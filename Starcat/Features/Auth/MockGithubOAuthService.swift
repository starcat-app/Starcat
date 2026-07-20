//
//  MockGithubOAuthService.swift
//  Starcat
//
//  Mock OAuth Service：开发期跳过真实 GitHub 授权，直接返回固定 token。
//
//  使用场景：
//  - DEBUG 环境绕过真实 GitHub 授权，快速验证登录后的 UI 与数据流
//  - 单元测试中验证登录流程
//  - 离线开发
//
//  关键约束：
//  - DEBUG 编译期默认可用；RELEASE 也可访问，但 UI 层应在 RELEASE 隐藏入口
//  - 假 token 必须明显标记（"mock_"前缀），避免和真 token 混淆
//

import Foundation
import CryptoKit

/// 永远返回成功的 Mock 实现。
///
/// `awaitAccessToken` 中插入一个可配置的延迟，模拟真实 OAuth 等待感。
final class MockGithubOAuthService: GithubOAuthServiceProtocol, @unchecked Sendable {

    /// 模拟用户授权的延迟（秒）。
    private let simulatedDelay: TimeInterval

    /// 假 token，可被测试替换。
    private let mockToken: String

    init(simulatedDelay: TimeInterval = 1.0, mockToken: String = "mock_dev_token_\(UUID().uuidString)") {
        self.simulatedDelay = simulatedDelay
        self.mockToken = mockToken
    }

    func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo {
        AppLog.auth.info("MockGithubOAuthService.beginDeviceFlow")
        return OAuthDeviceCodeInfo(
            userCode: "MOCK-DEV",
            verificationURI: AppEndpoints.GitHubOAuth.url(AppEndpoints.GitHubOAuth.Paths.deviceVerification),
            expiresIn: 600,
            pollInterval: 1
        )
    }

    func awaitAccessToken() async throws -> String {
        AppLog.auth.info("MockGithubOAuthService.awaitAccessToken (delay=\(self.simulatedDelay, privacy: .public)s)")
        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }
        try Task.checkCancellation()
        return mockToken
    }

    func reset() async {
        // no-op
    }

    // MARK: - Web Application Flow / PKCE（2026-06-29 新增）

    /// Mock Web Flow 起步：运行时生成真正的 32B verifier + SHA256 challenge（43 chars）+
    /// 16B state + 5min expiresAt。避免 GitHub 报 "code_challenge is expected to be
    /// 43 characters in length"。
    ///
    /// 生成的 state 存到 `mockWebFlowState` 字段，`exchangeCodeForToken` 不校验 state
    /// （Mock 跳过网络），但单元测试可通过此字段断言 state 一致性。
    private var mockWebFlowState: String = ""

    func beginWebFlow() async throws -> WebFlowStartInfo {
        AppLog.auth.info("MockGithubOAuthService.beginWebFlow")

        // 生成真正的 PKCE 参数（运行时计算，非硬编码）
        let verifier = try Self.generateCodeVerifier()
        let challenge = Self.computeCodeChallenge(from: verifier)
        let state = try Self.generateState()

        // 保存 verifier 供 exchangeCodeForToken 使用（Mock 跳过网络但走同样协议路径）
        self._mockVerifier = verifier
        self.mockWebFlowState = state

        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConstants.githubOAuthClientID),
            URLQueryItem(name: "scope", value: AppConstants.githubOAuthScopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: "starcat://callback")
        ]
        let authURL = components.url!

        return WebFlowStartInfo(
            authorizationURL: authURL,
            state: state,
            expiresAt: Date().addingTimeInterval(15 * 60)  // 15 分钟，与 Device Flow 一致
        )
    }

    /// 运行时生成的 PKCE code_verifier（Mock 专用，非网络 Mock 不真调用 /access_token，
    /// 但保留 verifier 以便 `exchangeCodeForToken` 打 log 用）
    private var _mockVerifier: String = ""

    /// Mock Web Flow 阶段 2：直接返回假 token（无网络）。
    /// 真实实现会用 code + code_verifier 调 /login/oauth/access_token，Mock 跳过。
    func exchangeCodeForToken(code: String) async throws -> String {
        AppLog.auth.info("MockGithubOAuthService.exchangeCodeForToken (delay=\(self.simulatedDelay, privacy: .public)s, code=\(code.prefix(8), privacy: .public)...)")
        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }
        try Task.checkCancellation()
        return mockToken
    }

    func resetWebFlow() async {
        _mockVerifier = ""
        mockWebFlowState = ""
    }

    // MARK: - PKCE 算法（Mock 专用，与 GithubWebFlowService 同款）
    // 放在 Mock 类内部而非复用 GithubWebFlowService 的 static 方法：避免 Mock 依赖
    // 真实实现 actor（倒置依赖：Mock 不 import 真实 actor）。

    private static func generateCodeVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            throw GithubOAuthError.unexpectedResponse(message: "SecRandomCopyBytes failed: \(status)")
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func generateState() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            throw GithubOAuthError.unexpectedResponse(message: "SecRandomCopyBytes failed: \(status)")
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func computeCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = CryptoKit.SHA256.hash(data: data)
        return Data(hash).base64URLEncodedString()
    }
}
