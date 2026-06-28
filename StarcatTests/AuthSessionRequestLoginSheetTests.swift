//
//  AuthSessionRequestLoginSheetTests.swift
//  StarcatTests
//
//  2026-06-29 `AuthSession.requestLoginSheet()` 单测。
//
//  覆盖范围：
//  - 默认值：shouldShowLoginSheet 初始为 false
//  - 未登录调 requestLoginSheet → flag 变 true
//  - 已登录调 requestLoginSheet → flag 保持 false（守门）
//  - 多次调用幂等（flag 始终 true）
//  - 5 个收尾路径都自动清 flag：
//    ① signIn 成功（runDeviceFlow 走通）
//    ② signInWithPAT 成功
//    ③ cancelSignIn
//    ④ signOut
//    ⑤ invalidateSession
//
//  设计取舍：
//  - 不打网络（用 MockGithubOAuthService + MockGitHubAPIClient）
//  - 测试方法标 @MainActor（AuthSession 是 @MainActor @Observable）
//  - 用 InMemoryKeychain 隔离 Keychain I/O
//

import Testing
import Foundation
@testable import Starcat

@Suite("Request login sheet")
struct AuthSessionRequestLoginSheetTests {

    // MARK: - 默认值

    @Test("shouldShowLoginSheet 默认 false")
    @MainActor
    func defaultFlagIsFalse() async {
        let session = Self.makeAuthSession()
        #expect(session.shouldShowLoginSheet == false)
    }

    // MARK: - requestLoginSheet 基本行为

    @Test("未登录调 requestLoginSheet → flag 变 true")
    @MainActor
    func requestLoginSheet_unauthenticated_setsFlagTrue() async {
        let session = Self.makeAuthSession()
        #expect(session.shouldShowLoginSheet == false)
        session.requestLoginSheet()
        #expect(session.shouldShowLoginSheet == true)
    }

    @Test("已登录调 requestLoginSheet → flag 保持 false（守门）")
    @MainActor
    func requestLoginSheet_alreadyAuthenticated_flagStaysFalse() async throws {
        let session = Self.makeAuthSession()
        // 直接构造 authenticated 状态
        session.state = .authenticated(user: Self.makeMockUser(id: 1))
        #expect(session.shouldShowLoginSheet == false)

        session.requestLoginSheet()
        // 已登录时不应该弹登录页（用户已经在登录态）
        #expect(session.shouldShowLoginSheet == false)
    }

    @Test("多次 requestLoginSheet 幂等（flag 始终 true）")
    @MainActor
    func requestLoginSheet_idempotent() async {
        let session = Self.makeAuthSession()
        session.requestLoginSheet()
        session.requestLoginSheet()
        session.requestLoginSheet()
        #expect(session.shouldShowLoginSheet == true)
    }

    // MARK: - 5 个收尾路径都清 flag

    @Test("signIn 成功（Device Flow 走通）→ flag 自动清")
    @MainActor
    func signIn_success_clearsFlag() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        api.getCurrentUserHandler = { Self.makeMockUser(id: 99) }
        let session = AuthSession(
            // simulatedDelay = 0 让 MockGithubOAuthService 立即返回 token
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain
        )

        session.requestLoginSheet()
        #expect(session.shouldShowLoginSheet == true)

        // 启动 Device Flow（后台 task 跑 runDeviceFlow）
        session.signIn()

        // 等 Device Flow 走完：isAuthenticating 回到 false 说明 defer 块已执行
        var waitedMs = 0
        while session.isAuthenticating, waitedMs < 2000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waitedMs += 10
        }
        #expect(session.isAuthenticating == false, "Device Flow 应在 2s 内走完")
        #expect(session.state.isAuthenticated)

        // 关键断言：登录成功后 flag 必须自动清
        #expect(session.shouldShowLoginSheet == false,
                "登录成功后 shouldShowLoginSheet 必须清，否则 sheet 不会 dismiss")
    }

    @Test("signInWithPAT 成功 → flag 自动清")
    @MainActor
    func signInWithPAT_success_clearsFlag() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        api.getCurrentUserHandler = { Self.makeMockUser(id: 7) }
        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain
        )

        session.requestLoginSheet()
        #expect(session.shouldShowLoginSheet == true)

        await session.signInWithPAT("ghp_test_token")
        #expect(session.state.isAuthenticated)

        #expect(session.shouldShowLoginSheet == false)
    }

    @Test("cancelSignIn → flag 清")
    @MainActor
    func cancelSignIn_clearsFlag() async {
        let session = Self.makeAuthSession()

        session.requestLoginSheet()
        #expect(session.shouldShowLoginSheet == true)

        session.cancelSignIn()

        #expect(session.shouldShowLoginSheet == false)
    }

    @Test("signOut → flag 清")
    @MainActor
    func signOut_clearsFlag() async throws {
        let session = Self.makeAuthSession()
        session.state = .authenticated(user: Self.makeMockUser(id: 11))
        session.requestLoginSheet()  // state.isAuthenticated 为 true → flag 不变（守门）
        // 构造一个让 flag 为 true 的场景
        // 切换到 unauthenticated 后再 requestLoginSheet
        // 但我们没 signOut 测试 — 直接手工设 state 模拟
        session.state = .unauthenticated
        session.requestLoginSheet()
        #expect(session.shouldShowLoginSheet == true)

        // 重新登回再 signOut
        session.state = .authenticated(user: Self.makeMockUser(id: 11))
        await session.signOut()

        #expect(session.shouldShowLoginSheet == false)
    }

    @Test("invalidateSession → flag 清")
    @MainActor
    func invalidateSession_clearsFlag() async throws {
        let session = Self.makeAuthSession()
        session.state = .authenticated(user: Self.makeMockUser(id: 13))
        session.state = .unauthenticated
        session.requestLoginSheet()
        #expect(session.shouldShowLoginSheet == true)

        // 重新登录再触发 401
        session.state = .authenticated(user: Self.makeMockUser(id: 13))
        await session.invalidateSession()

        #expect(session.shouldShowLoginSheet == false)
    }

    // MARK: - 防误伤：requestLoginSheet 不污染 Device Flow 状态机

    @Test("requestLoginSheet 不影响后续 signIn() 启动 Device Flow")
    @MainActor
    func requestLoginSheet_doesNotBlockSubsequentSignIn() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        api.getCurrentUserHandler = { Self.makeMockUser(id: 21) }
        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain
        )

        // 用户在 sheet 内选了 Device Flow 主 CTA（signIn）
        // requestLoginSheet 之前调过 + 之后调 signIn，都应正常工作
        session.requestLoginSheet()
        #expect(session.shouldShowLoginSheet == true)

        session.signIn()

        var waitedMs = 0
        while session.isAuthenticating, waitedMs < 2000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waitedMs += 10
        }
        #expect(session.isAuthenticating == false)
        #expect(session.state.isAuthenticated)
        #expect(session.shouldShowLoginSheet == false)
    }

    // MARK: - Helpers

    @MainActor
    private static func makeAuthSession() -> AuthSession {
        AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: MockGitHubAPIClient(),
            keychain: InMemoryKeychain()
        )
    }

    private static func makeMockUser(id: Int64) -> GitHubUserDTO {
        GitHubUserDTO(
            id: id,
            login: "user\(id)",
            name: nil,
            avatarUrl: nil,
            publicRepos: nil,
            followers: nil,
            following: nil,
            bio: nil,
            company: nil,
            location: nil,
            email: nil,
            blog: nil,
            twitterUsername: nil,
            htmlUrl: nil
        )
    }
}
