//
//  MockGithubOAuthService.swift
//  Starcat
//
//  Mock OAuth Service：开发期跳过真实 GitHub 授权，直接返回固定 token。
//
//  使用场景：
//  - 真实 Client ID 未注册（Constants.swift 占位）
//  - 单元测试中验证登录流程
//  - 离线开发
//
//  关键约束：
//  - DEBUG 编译期默认可用；RELEASE 也可访问，但 UI 层应在 RELEASE 隐藏入口
//  - 假 token 必须明显标记（"mock_"前缀），避免和真 token 混淆
//

import Foundation

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
            verificationURI: URL(string: "https://github.com/login/device")!,
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
}
