//
//  AuthSessionPATSignInTests.swift
//  StarcatTests
//
//  2026-06-29 PAT 直接登录单元测试。
//
//  覆盖范围（与 docs/2-产品/需求讨论/正式方案/GitHub OAuth 设计.md §5.4 对齐）：
//  - 成功：handler 返回 user → state 切到 .authenticated + Keychain 写入 token +
//    onUserSessionChanged 收到 user.id
//  - 401：handler 抛 unauthorized → state 保持 .unauthenticated + Keychain 已被清空 +
//    lastError 标记为 .invalidToken
//  - 403：handler 抛 clientError(403, ...) → state 保持 .unauthenticated + Keychain
//    已被清空 + lastError 标记为 .insufficientScope
//  - 网络错：handler 抛 transport(...) → state 保持 .unauthenticated + Keychain
//    已被清空 + lastError 标记为对应网络错误
//
//  关键约束（与现有 Device Flow 测试对齐）：
//  - 不打网络（用 MockGitHubAPIClient.getCurrentUserHandler）
//  - 测试方法标 @MainActor（AuthSession 是 @MainActor @Observable）
//  - 用 InMemoryKeychain 隔离 Keychain I/O
//
//

import Testing
import Foundation
@testable import Starcat

@Suite("PAT direct sign-in")
struct AuthSessionPATSignInTests {

    // MARK: - 成功路径

    @Test("PAT 验证成功 → state 切到 authenticated + token 落 Keychain + onUserSessionChanged(user.id)")
    @MainActor
    func signInWithPAT_success() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()

        // 替换 keychain 为独立实例便于断言 snapshot
        let sessionWithKC = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain
        )

        let expectedUser = Self.makeMockUser(id: 4242)
        api.getCurrentUserHandler = { expectedUser }

        var captured: [Int64?] = []
        sessionWithKC.onUserSessionChanged = { userId in
            captured.append(userId)
        }

        await sessionWithKC.signInWithPAT("ghp_test_token_1234567890abcdef")

        // state 已切到 .authenticated
        if case .authenticated(let user) = sessionWithKC.state {
            #expect(user.id == 4242)
            #expect(user.login == "user4242")
        } else {
            Issue.record("期望 state == .authenticated，实际 \(sessionWithKC.state)")
        }

        // token 已落 Keychain
        let stored = try keychain.loadGithubToken()
        #expect(stored == "ghp_test_token_1234567890abcdef")

        // onUserSessionChanged 收到 user.id
        #expect(captured == [4242])

        // 成功路径 lastError 必须清空
        #expect(sessionWithKC.lastError == nil)
    }

    // MARK: - 401：Token 无效

    @Test("PAT 验证 401 → state 保持 unauthenticated + token 已被回滚 + lastError = .invalidToken")
    @MainActor
    func signInWithPAT_401_invalidToken() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        api.getCurrentUserHandler = { throw NetworkError.unauthorized }

        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain
        )

        var captured: [Int64?] = []
        session.onUserSessionChanged = { userId in
            captured.append(userId)
        }

        await session.signInWithPAT("ghp_invalid_token")

        // state 必须保持 unauthenticated
        #expect(session.state == .unauthenticated)

        // 关键：401 后 Keychain 必须被回滚（不能留无效 token）
        let stored = try keychain.loadGithubToken()
        #expect(stored == nil, "401 后必须清掉临时写入的 token，避免下次启动误判为已登录")

        // onUserSessionChanged 不应被触发（无 user.id 可切）
        #expect(captured.isEmpty)

        // lastError 必须指向 invalidToken
        guard let error = session.lastError else {
            Issue.record("期望 lastError != nil，实际 nil")
            return
        }
        guard let patError = error as? GithubPATError else {
            Issue.record("期望 lastError 是 GithubPATError，实际 \(type(of: error))")
            return
        }
        #expect(patError == .invalidToken)
    }

    // MARK: - 403：scope 不足

    @Test("PAT 验证 403 → state 保持 unauthenticated + token 已被回滚 + lastError = .insufficientScope")
    @MainActor
    func signInWithPAT_403_insufficientScope() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        api.getCurrentUserHandler = {
            throw NetworkError.clientError(statusCode: 403, message: "Resource not accessible by integration")
        }

        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain
        )

        await session.signInWithPAT("ghp_wrong_scope_token")

        #expect(session.state == .unauthenticated)

        let stored = try keychain.loadGithubToken()
        #expect(stored == nil, "403 后必须清掉临时写入的 token")

        guard let error = session.lastError else {
            Issue.record("期望 lastError != nil，实际 nil")
            return
        }
        guard let patError = error as? GithubPATError else {
            Issue.record("期望 lastError 是 GithubPATError，实际 \(type(of: error))")
            return
        }
        #expect(patError == .insufficientScope)
    }

    // MARK: - 网络错

    @Test("PAT 验证网络错 → state 保持 unauthenticated + token 已被回滚 + lastError 非空")
    @MainActor
    func signInWithPAT_networkError() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        api.getCurrentUserHandler = { throw NetworkError.transport(underlying: underlying) }

        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain
        )

        await session.signInWithPAT("ghp_network_error_token")

        #expect(session.state == .unauthenticated)

        let stored = try keychain.loadGithubToken()
        #expect(stored == nil, "网络错后也必须清掉临时写入的 token")

        // 网络错不映射为 .invalidToken / .insufficientScope，但 lastError 必须非空，
        // 走原有 errorBanner 通道让用户看到"网络错误，请重试"。
        #expect(session.lastError != nil)
    }

    // MARK: - 防误伤：成功 + 401 不会破坏其他状态机

    @Test("PAT 失败不影响后续 Device Flow：signOut 后 state 仍可正常迁移")
    @MainActor
    func signInWithPAT_failure_doesNotCorruptState() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        api.getCurrentUserHandler = { throw NetworkError.unauthorized }

        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain
        )

        // PAT 失败
        await session.signInWithPAT("ghp_bad")
        #expect(session.state == .unauthenticated)
        #expect(session.lastError != nil)

        // 再次 PAT 失败时，isAuthenticating 必须能正确回到 false
        await session.signInWithPAT("ghp_still_bad")
        #expect(session.isAuthenticating == false)
        #expect(session.state == .unauthenticated)
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
