//
//  MockGithubOAuthServiceTests.swift
//  StarcatTests
//
//  验证 Mock OAuth Service 的两阶段流程符合预期。
//

import Testing
import Foundation
@testable import Starcat

@Suite("MockGithubOAuthService")
struct MockGithubOAuthServiceTests {

    @Test("beginDeviceFlow 返回固定 user_code")
    func beginReturnsCode() async throws {
        let svc = MockGithubOAuthService(simulatedDelay: 0)
        let info = try await svc.beginDeviceFlow()
        #expect(info.userCode == "MOCK-DEV")
        #expect(info.verificationURI.absoluteString.contains("github.com"))
    }

    @Test("awaitAccessToken 返回非空 token")
    func awaitReturnsToken() async throws {
        let svc = MockGithubOAuthService(simulatedDelay: 0, mockToken: "test-token-abc")
        let token = try await svc.awaitAccessToken()
        #expect(token == "test-token-abc")
    }

    @Test("awaitAccessToken 在 Task 取消时抛 CancellationError")
    func awaitCancellation() async throws {
        let svc = MockGithubOAuthService(simulatedDelay: 5, mockToken: "x")
        let task = Task { try await svc.awaitAccessToken() }
        task.cancel()
        await #expect(throws: (any Error).self) {
            _ = try await task.value
        }
    }
}
