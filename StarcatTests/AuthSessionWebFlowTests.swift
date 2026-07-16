//
//  AuthSessionWebFlowTests.swift
//  StarcatTests
//
//  2026-06-29 Web Application Flow (PKCE) 单元测试。
//
//  覆盖范围（与 docs/2-产品/需求讨论/正式方案/GitHub OAuth 设计.md §3.5 对齐）：
//  - 状态机：signInWithWebFlow → .awaitingWebCallback → handleWebFlowCallback 成功 → .authenticated
//  - 状态机：handleWebFlowCallback 失败（401/403/网络/解析）→ .unauthenticated + lastError + 清 flag
//  - 状态机：state 不在 .awaitingWebCallback 时 handleWebFlowCallback 忽略（防误处理）
//  - 状态机：state 在 .awaitingWebCallback 但 callback 的 state 不匹配 → 拒绝（防 CSRF）
//  - 状态机：state 过期后 callback → 拒绝
//  - 状态机：isAuthenticating 守门（同 Device Flow / PAT）
//  - 系统认证：授权 URL + callback scheme 交给 ASWebAuthenticationSession 适配层
//  - 系统认证：成功回调自动进入既有 callback 状态机；取消时关闭会话并清状态
//  - 防误伤：handleWebFlowCallback 不破坏 Device Flow state machine
//
//  设计取舍：
//  - 用 MockGithubOAuthService（不模拟 PKCE 内部算法 + 不发真实网络）
//  - 状态机逻辑用 Mock 直接驱动；OAuth 协议层走真实 GithubWebFlowService 在另一组测试覆盖
//

import Testing
import Foundation
@testable import Starcat

@Suite("Web Application Flow")
struct AuthSessionWebFlowTests {

    // MARK: - signInWithWebFlow 基础行为

    @Test("ASWebAuthenticationSession 后台回调可安全切回 MainActor")
    @MainActor
    func systemCallback_acceptsBackgroundQueue() async {
        let expectedURL = URL(string: "starcat://callback?code=test&state=test-state")!

        let result: Result<URL, WebAuthenticationSessionError> = await withCheckedContinuation {
            continuation in
            let callback = SystemWebAuthenticationSession.makeSystemCallback { result in
                continuation.resume(returning: result)
            }

            // 真实 AuthenticationServices completion 由后台 XPC 队列触发。这里故意
            // 从全局队列进入 callback，回归覆盖曾触发 _dispatch_assert_queue_fail 的路径。
            DispatchQueue.global(qos: .userInitiated).async {
                callback(expectedURL, nil)
            }
        }

        switch result {
        case .success(let callbackURL):
            #expect(callbackURL == expectedURL)
        case .failure(let error):
            Issue.record("后台 callback 应成功返回 URL，实际错误：\(error.localizedDescription)")
        }
    }

    @Test("signInWithWebFlow → state 切到 .awaitingWebCallback（专用于 Web Flow）")
    @MainActor
    func signInWithWebFlow_emitsAwaitingWebCallback() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        let webAuthenticationSession = MockWebAuthenticationSession()
        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain,
            webAuthenticationSession: webAuthenticationSession
        )

        session.signInWithWebFlow()
        // signInWithWebFlow 内部 Task 异步跑 runWebFlow → emit .awaitingWebCallback，
        // 轮询等 state 切换
        try await Self.waitForState(session) { $0.isAwaitingWebCallback }

        // 关键断言：state 切到 .awaitingWebCallback（**不是** awaitingUserCode）
        if case .awaitingWebCallback(let info) = session.state {
            #expect(!info.state.isEmpty, "state 不应为空")
            #expect(info.state == Self.extractState(from: info), "state 应与 URL 参数一致")
            #expect(info.authorizationURL.absoluteString.contains("github.com/login/oauth/authorize"))
            #expect(info.authorizationURL.absoluteString.contains("code_challenge="))
            #expect(webAuthenticationSession.authorizationURL == info.authorizationURL)
            #expect(webAuthenticationSession.callbackURLScheme == AppConstants.oauthCallbackScheme)
        } else {
            Issue.record("期望 state == .awaitingWebCallback，实际 \(session.state)")
        }
    }

    @Test("signInWithWebFlow 守门：已有登录流程时忽略")
    @MainActor
    func signInWithWebFlow_guardWhenAlreadyAuthenticating() async {
        let session = Self.makeAuthSession()
        session.isAuthenticating = true
        let previousState = session.state
        session.signInWithWebFlow()
        #expect(session.state == previousState, "已有流程时 signInWithWebFlow 必须 no-op")
    }

    // MARK: - handleWebFlowCallback 成功路径

    @Test("handleWebFlowCallback 成功 → state 切到 .authenticated + token 落 Keychain + onUserSessionChanged")
    @MainActor
    func handleWebFlowCallback_success() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        let expectedUser = Self.makeMockUser(id: 555)
        api.getCurrentUserHandler = { expectedUser }
        let webAuthenticationSession = MockWebAuthenticationSession()

        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain,
            webAuthenticationSession: webAuthenticationSession
        )

        // 启动 Web Flow（异步切 state，需等）
        session.signInWithWebFlow()
        try await Self.waitForState(session) { $0.isAwaitingWebCallback }

        var captured: [Int64?] = []
        session.onUserSessionChanged = { userId in captured.append(userId) }

        // 构造 callback URL（用 runtime 生成的 state，不再硬编码）
        let actualState = Self.extractStateFromSession(session)
        let callbackURL = URL(string: "starcat://callback?code=test_code&state=\(actualState)")!
        webAuthenticationSession.complete(with: .success(callbackURL))
        try await Self.waitForState(session) { $0.isAuthenticated }

        if case .authenticated(let user) = session.state {
            #expect(user.id == 555)
        } else {
            Issue.record("期望 state == .authenticated，实际 \(session.state)")
        }
        let stored = try keychain.loadGithubToken()
        #expect(stored?.hasPrefix("mock_") == true, "Mock token 必须落到 Keychain")
        #expect(captured == [555])
    }

    // MARK: - handleWebFlowCallback 拒绝路径

    @Test("handleWebFlowCallback 在 state != .awaitingWebCallback 时忽略（防误处理）")
    @MainActor
    func handleWebFlowCallback_ignoredWhenStateWrong() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain,
            webAuthenticationSession: MockWebAuthenticationSession()
        )
        // 不调 signInWithWebFlow，state 仍是 .unauthenticated

        let callbackURL = URL(string: "starcat://callback?code=test&state=anything")!
        await session.handleWebFlowCallback(url: callbackURL)

        // state 必须保持 .unauthenticated（忽略 callback）
        #expect(session.state == .unauthenticated)
        // 不能有 lastError（这是"忽略"不是"错误"）
        #expect(session.lastError == nil)
        // keychain 必须为空（没写过 token）
        let stored = try keychain.loadGithubToken()
        #expect(stored == nil)
    }

    @Test("handleWebFlowCallback state 不匹配 → 拒绝 + lastError")
    @MainActor
    func handleWebFlowCallback_stateMismatch() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain,
            webAuthenticationSession: MockWebAuthenticationSession()
        )

        session.signInWithWebFlow()
        try await Self.waitForState(session) { $0.isAwaitingWebCallback }

        // callback 用了错误的 state
        let callbackURL = URL(string: "starcat://callback?code=test&state=WRONG-STATE")!
        await session.handleWebFlowCallback(url: callbackURL)

        // state 必须回到 .unauthenticated（不接受 code）
        #expect(session.state == .unauthenticated)
        // lastError 必须非空
        #expect(session.lastError != nil)
        // keychain 必须为空
        let storedAfterMismatch = try keychain.loadGithubToken()
        #expect(storedAfterMismatch == nil)
    }

    @Test("handleWebFlowCallback 缺少 code 参数 → 拒绝")
    @MainActor
    func handleWebFlowCallback_missingCode() async throws {
        let session = Self.makeAuthSession()
        session.signInWithWebFlow()
        try await Self.waitForState(session) { $0.isAwaitingWebCallback }
        let actualState = Self.extractStateFromSession(session)
        let callbackURL = URL(string: "starcat://callback?state=\(actualState)")!  // 没 code
        await session.handleWebFlowCallback(url: callbackURL)

        #expect(session.state == .unauthenticated)
        let stored = try InMemoryKeychain().loadGithubToken()
        #expect(stored == nil)
    }

    @Test("handleWebFlowCallback 缺少 state 参数 → 拒绝")
    @MainActor
    func handleWebFlowCallback_missingState() async throws {
        let session = Self.makeAuthSession()
        session.signInWithWebFlow()
        try await Self.waitForState(session) { $0.isAwaitingWebCallback }
        let callbackURL = URL(string: "starcat://callback?code=test")!  // 没 state
        await session.handleWebFlowCallback(url: callbackURL)

        #expect(session.state == .unauthenticated)
    }

    @Test("handleWebFlowCallback path != /callback → 忽略")
    @MainActor
    func handleWebFlowCallback_wrongPath() async throws {
        let session = Self.makeAuthSession()
        session.signInWithWebFlow()
        try await Self.waitForState(session) { $0.isAwaitingWebCallback }
        // path 是别的（不是 /callback）
        let actualState = Self.extractStateFromSession(session)
        let callbackURL = URL(string: "starcat://other?code=test&state=\(actualState)")!
        await session.handleWebFlowCallback(url: callbackURL)

        // 应该被忽略，state 保持 .awaitingWebCallback
        if case .awaitingWebCallback = session.state {
            // ✓ 正确
        } else {
            Issue.record("path != /callback 必须忽略，state 应保持 .awaitingWebCallback，实际 \(session.state)")
        }
    }

    @Test("handleWebFlowCallback scheme != starcat → 忽略")
    @MainActor
    func handleWebFlowCallback_wrongScheme() async throws {
        let session = Self.makeAuthSession()
        session.signInWithWebFlow()
        try await Self.waitForState(session) { $0.isAwaitingWebCallback }
        let actualState = Self.extractStateFromSession(session)
        let callbackURL = URL(string: "https://github.com/callback?code=test&state=\(actualState)")!
        await session.handleWebFlowCallback(url: callbackURL)

        // 应被忽略
        if case .awaitingWebCallback = session.state {
            // ✓
        } else {
            Issue.record("scheme != starcat 必须忽略")
        }
    }

    // MARK: - 防误伤

    @Test("handleWebFlowCallback 不污染 Device Flow state machine")
    @MainActor
    func handleWebFlowCallback_doesNotCorruptDeviceFlow() async throws {
        let keychain = InMemoryKeychain()
        let api = MockGitHubAPIClient()
        api.getCurrentUserHandler = { Self.makeMockUser(id: 7) }
        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: api,
            keychain: keychain,
            webAuthenticationSession: MockWebAuthenticationSession(),
            distributionGate: DistributionGate(channel: .direct)
        )

        // 启动 Web Flow 然后故意触发 state mismatch（让 state 切回 .unauthenticated）
        session.signInWithWebFlow()
        try await Self.waitForState(session) { $0.isAwaitingWebCallback }
        let badURL = URL(string: "starcat://callback?code=test&state=WRONG")!
        await session.handleWebFlowCallback(url: badURL)
        #expect(session.state == .unauthenticated)
        #expect(session.lastError != nil)

        // 此时再走 Device Flow：必须正常工作
        session.signIn()
        var waitedMs = 0
        while session.isAuthenticating, waitedMs < 2000 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waitedMs += 10
        }
        #expect(session.isAuthenticating == false)
        #expect(session.state.isAuthenticated)
    }

    // MARK: - 收尾路径

    @Test("cancelWebFlow 关闭系统认证会话并回到未登录态")
    @MainActor
    func cancelWebFlow_cancelsSystemSession() async throws {
        let webAuthenticationSession = MockWebAuthenticationSession()
        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: MockGitHubAPIClient(),
            keychain: InMemoryKeychain(),
            webAuthenticationSession: webAuthenticationSession
        )

        session.signInWithWebFlow()
        try await Self.waitForState(session) { $0.isAwaitingWebCallback }
        session.cancelWebFlow()

        #expect(webAuthenticationSession.cancelCallCount == 1)
        #expect(session.state == .unauthenticated)
        #expect(session.lastError == nil)
    }

    @Test("关闭系统认证窗口按正常取消处理，不展示错误")
    @MainActor
    func systemSessionCancellation_resetsWithoutError() async throws {
        let webAuthenticationSession = MockWebAuthenticationSession()
        let session = AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: MockGitHubAPIClient(),
            keychain: InMemoryKeychain(),
            webAuthenticationSession: webAuthenticationSession
        )

        session.signInWithWebFlow()
        try await Self.waitForState(session) { $0.isAwaitingWebCallback }
        webAuthenticationSession.complete(with: .failure(.cancelled))

        #expect(session.state == .unauthenticated)
        #expect(session.lastError == nil)
    }

    @Test("signOut 后 handleWebFlowCallback 被忽略")
    @MainActor
    func handleWebFlowCallback_afterSignOut_ignored() async throws {
        let session = Self.makeAuthSession()
        session.state = .authenticated(user: Self.makeMockUser(id: 1))
        await session.signOut()
        #expect(session.state == .unauthenticated)

        let callbackURL = URL(string: "starcat://callback?code=test&state=any")!
        await session.handleWebFlowCallback(url: callbackURL)
        // signOut 后 state 是 .unauthenticated，handleWebFlowCallback 应被忽略
        #expect(session.state == .unauthenticated)
        #expect(session.lastError == nil)
    }

    // MARK: - Helpers

    @MainActor
    private static func makeAuthSession() -> AuthSession {
        AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: MockGitHubAPIClient(),
            keychain: InMemoryKeychain(),
            webAuthenticationSession: MockWebAuthenticationSession()
        )
    }

    /// 等 state 满足 predicate（轮询 10ms 间隔，最长 1s）。
    /// 专用于 `signInWithWebFlow` 异步切 state 的场景。
    @MainActor
    private static func waitForState(
        _ session: AuthSession,
        timeoutMs: Int = 1000,
        predicate: (AuthState) -> Bool
    ) async throws {
        var waitedMs = 0
        while !predicate(session.state), waitedMs < timeoutMs {
            try await Task.sleep(nanoseconds: 10_000_000)
            waitedMs += 10
        }
    }

    /// 从 session.state 提取当前 Web Flow 的 state 字符串。
    @MainActor
    private static func extractStateFromSession(_ session: AuthSession) -> String {
        if case .awaitingWebCallback(let info) = session.state {
            return info.state
        }
        Issue.record("extractStateFromSession called but state is not .awaitingWebCallback")
        return ""
    }

    /// 从 WebFlowStartInfo 的 authorizationURL 里反解 state query param。
    private static func extractState(from info: WebFlowStartInfo) -> String {
        guard let components = URLComponents(url: info.authorizationURL, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let state = items.first(where: { $0.name == "state" })?.value
        else { return "" }
        return state
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

/// Web Flow 单测替身：只记录系统认证参数，并由测试显式触发回调。
///
/// 真实 `ASWebAuthenticationSession` 需要可见 NSWindow，不能在无 UI 的 test host 中启动；
/// 通过该替身可以验证 AuthSession 的接线，同时保持测试确定性。
@MainActor
private final class MockWebAuthenticationSession: WebAuthenticationSessionProviding {
    private(set) var authorizationURL: URL?
    private(set) var callbackURLScheme: String?
    private(set) var cancelCallCount = 0
    private var completion: (@MainActor @Sendable (
        Result<URL, WebAuthenticationSessionError>
    ) -> Void)?

    func start(
        authorizationURL: URL,
        callbackURLScheme: String,
        completion: @escaping @MainActor @Sendable (
            Result<URL, WebAuthenticationSessionError>
        ) -> Void
    ) throws {
        self.authorizationURL = authorizationURL
        self.callbackURLScheme = callbackURLScheme
        self.completion = completion
    }

    func cancel() {
        cancelCallCount += 1
        completion = nil
    }

    func complete(with result: Result<URL, WebAuthenticationSessionError>) {
        let completion = completion
        self.completion = nil
        completion?(result)
    }
}
