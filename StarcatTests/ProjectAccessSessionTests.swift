//
//  ProjectAccessSessionTests.swift
//  StarcatTests
//
//  验证独立授权状态、凭据轮换、撤销和 OAuth fallback 不互相污染。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ProjectAccessSession")
struct ProjectAccessSessionTests {
    private final class MockOAuth: ProjectAccessOAuthServiceProtocol, @unchecked Sendable {
        var beginResult = ProjectAccessAuthorizationInfo(
            installationURL: URL(
                string: "https://github.com/apps/starcat-for-github/installations/new?state=test"
            )!,
            expiresAt: Date(timeIntervalSince1970: 10_900)
        )
        var credential: ProjectAccessCredential
        var refreshed: ProjectAccessCredential
        var revokeError: ProjectAccessOAuthError?
        private(set) var refreshInputs: [String] = []
        private(set) var revokedTokens: [String] = []
        private(set) var resetCallCount = 0

        init(credential: ProjectAccessCredential, refreshed: ProjectAccessCredential? = nil) {
            self.credential = credential
            self.refreshed = refreshed ?? credential
        }

        func beginAuthorization() async throws -> ProjectAccessAuthorizationInfo { beginResult }
        func exchangeCallback(_ callbackURL: URL) async throws -> ProjectAccessCredential {
            credential
        }
        func refreshCredential(using refreshToken: String) async throws -> ProjectAccessCredential {
            refreshInputs.append(refreshToken)
            return refreshed
        }
        func revokeAuthorization(accessToken: String) async throws {
            if let revokeError { throw revokeError }
            revokedTokens.append(accessToken)
        }
        func reset() async {
            resetCallCount += 1
        }
    }

    /// 项目权限测试使用独立替身，验证安装页和 callback 都经过发起进程的系统认证会话。
    @MainActor
    private final class MockProjectWebAuthenticationSession:
        WebAuthenticationSessionProviding
    {
        private(set) var authorizationURL: URL?
        private(set) var callbackURLScheme: String?
        private(set) var cancelCallCount = 0
        var startError: WebAuthenticationSessionError?
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
            if let startError {
                throw startError
            }
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

    @MainActor
    private final class ConnectionResultRecorder {
        var value: ProjectAccessConnectionResult?
    }

    private let now = Date(timeIntervalSince1970: 10_000)
    private let callbackURL = URL(
        string: "starcat://github-app/callback?code=code&state=test"
    )!

    private func credential(
        token: String,
        accessOffset: TimeInterval,
        refreshToken: String? = "refresh",
        refreshOffset: TimeInterval? = 10_000
    ) -> ProjectAccessCredential {
        ProjectAccessCredential(
            accessToken: token,
            accessExpiresAt: now.addingTimeInterval(accessOffset),
            refreshToken: refreshToken,
            refreshExpiresAt: refreshOffset.map { now.addingTimeInterval($0) }
        )
    }

    private func storedCredential(
        _ keychain: InMemoryKeychain,
        _ credential: ProjectAccessCredential
    ) throws {
        let data = try JSONEncoder().encode(credential)
        try keychain.storeProjectAccessCredential(String(decoding: data, as: UTF8.self))
    }

    @Test("GitHub App Web Flow 只写项目凭据，不覆盖 OAuth token")
    @MainActor
    func connectionIsIndependentFromMainOAuth() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeGithubToken("oauth-main")
        let issued = credential(token: "ghu-project", accessOffset: 3_600)
        let oauth = MockOAuth(credential: issued)
        let session = ProjectAccessSession(
            oauthService: oauth,
            keychain: keychain,
            isConfigured: true,
            appSlug: "starcat-project-access",
            installationCheck: { _, _ in .allRepositories },
            now: { self.now }
        )

        let info = try await session.beginConnection()
        #expect(info.installationURL.host == "github.com")
        #expect(session.state == .awaitingAuthorization)
        try await session.completeConnection(callbackURL: callbackURL)

        #expect(session.state == .connected(expiresAt: issued.accessExpiresAt))
        #expect(try keychain.loadGithubToken() == "oauth-main")
        #expect(try keychain.loadProjectAccessCredential() != nil)
    }

    @Test("安装授权由发起进程的 ASWebAuthenticationSession 完成")
    @MainActor
    func connectionUsesProcessBoundWebAuthenticationSession() async {
        let keychain = InMemoryKeychain()
        let issued = credential(token: "ghu-project", accessOffset: 3_600)
        let webAuthenticationSession = MockProjectWebAuthenticationSession()
        let recorder = ConnectionResultRecorder()
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: issued),
            keychain: keychain,
            webAuthenticationSession: webAuthenticationSession,
            isConfigured: true,
            appSlug: "starcat-project-access",
            installationCheck: { _, _ in .allRepositories },
            now: { self.now }
        )

        session.startConnection { recorder.value = $0 }
        await Self.waitUntil { webAuthenticationSession.authorizationURL != nil }

        #expect(
            webAuthenticationSession.authorizationURL?.path
                == "/apps/starcat-for-github/installations/new"
        )
        #expect(
            webAuthenticationSession.callbackURLScheme == AppConstants.oauthCallbackScheme
        )
        #expect(session.state == .awaitingAuthorization)

        webAuthenticationSession.complete(with: .success(callbackURL))
        await Self.waitUntil { recorder.value != nil }

        #expect(recorder.value == .connected(.allRepositories))
        #expect(session.state == .connected(expiresAt: issued.accessExpiresAt))
        let storedCredential = try? keychain.loadProjectAccessCredential()
        #expect(storedCredential != nil)
    }

    @Test("关闭项目授权系统窗口按正常取消处理")
    @MainActor
    func systemAuthenticationCancellationResetsConnection() async {
        let issued = credential(token: "ghu-project", accessOffset: 3_600)
        let oauth = MockOAuth(credential: issued)
        let webAuthenticationSession = MockProjectWebAuthenticationSession()
        let recorder = ConnectionResultRecorder()
        let session = ProjectAccessSession(
            oauthService: oauth,
            keychain: InMemoryKeychain(),
            webAuthenticationSession: webAuthenticationSession,
            isConfigured: true,
            now: { self.now }
        )

        session.startConnection { recorder.value = $0 }
        await Self.waitUntil { webAuthenticationSession.authorizationURL != nil }
        webAuthenticationSession.complete(with: .failure(.cancelled))
        await Self.waitUntil { recorder.value != nil }

        #expect(recorder.value == .cancelled)
        #expect(session.state == .disconnected)
        #expect(oauth.resetCallCount == 1)
    }

    @Test("项目权限取消只关闭自己的系统认证会话")
    @MainActor
    func explicitCancellationStopsProjectWebSession() async {
        let issued = credential(token: "ghu-project", accessOffset: 3_600)
        let webAuthenticationSession = MockProjectWebAuthenticationSession()
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: issued),
            keychain: InMemoryKeychain(),
            webAuthenticationSession: webAuthenticationSession,
            isConfigured: true,
            now: { self.now }
        )

        session.startConnection { _ in }
        await Self.waitUntil { webAuthenticationSession.authorizationURL != nil }
        await session.cancelConnection()

        #expect(webAuthenticationSession.cancelCallCount == 1)
        #expect(session.state == .disconnected)
    }

    @Test("系统认证窗口启动失败会清理待授权状态")
    @MainActor
    func systemAuthenticationStartFailureResetsOAuthState() async {
        let issued = credential(token: "ghu-project", accessOffset: 3_600)
        let oauth = MockOAuth(credential: issued)
        let webAuthenticationSession = MockProjectWebAuthenticationSession()
        webAuthenticationSession.startError = .failed(message: "presentation unavailable")
        let recorder = ConnectionResultRecorder()
        let session = ProjectAccessSession(
            oauthService: oauth,
            keychain: InMemoryKeychain(),
            webAuthenticationSession: webAuthenticationSession,
            isConfigured: true,
            now: { self.now }
        )

        session.startConnection { recorder.value = $0 }
        await Self.waitUntil { recorder.value != nil }

        #expect(recorder.value == .failed)
        #expect(session.state == .failed(.unknown))
        #expect(oauth.resetCallCount == 1)
    }

    @Test("Web Flow 成功但未安装 App 时保留凭据并回退 Public 项目")
    @MainActor
    func missingInstallationPreservesCredentialAndFallsBack() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeGithubToken("oauth-main")
        let issued = credential(token: "ghu-project", accessOffset: 3_600)
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: issued),
            keychain: keychain,
            isConfigured: true,
            appSlug: "starcat-project-access",
            installationCheck: { _, _ in .notInstalled },
            now: { self.now }
        )

        _ = try await session.beginConnection()
        try await session.completeConnection(callbackURL: callbackURL)

        #expect(session.state == .installationRequired)
        #expect(try keychain.loadProjectAccessCredential() != nil)

        let route = try await ProjectCredentialRouter(
            projectAccessSession: session,
            keychain: keychain
        ).resolve()
        #expect(route.authorizationSource == .oauth)
        #expect(route.accessToken == "oauth-main")
    }

    @Test("完成安装后可复查并直接进入已连接状态")
    @MainActor
    func installationCanBeRecheckedWithoutDeviceFlow() async throws {
        let keychain = InMemoryKeychain()
        let issued = credential(token: "ghu-project", accessOffset: 3_600)
        try storedCredential(keychain, issued)
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: issued),
            keychain: keychain,
            isConfigured: true,
            appSlug: "starcat-project-access",
            installationCheck: { token, slug in
                token == "ghu-project" && slug == "starcat-project-access"
                    ? .allRepositories
                    : .notInstalled
            },
            now: { self.now }
        )

        let access = try await session.refreshInstallationState()

        #expect(access == .allRepositories)
        #expect(session.state == .connected(expiresAt: issued.accessExpiresAt))
    }

    @Test("指定仓库安装范围映射为部分授权")
    @MainActor
    func selectedRepositoriesMapToPartialAuthorization() async throws {
        let keychain = InMemoryKeychain()
        let issued = credential(token: "ghu-project", accessOffset: 3_600)
        try storedCredential(keychain, issued)
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: issued),
            keychain: keychain,
            isConfigured: true,
            appSlug: "starcat-for-github",
            installationCheck: { _, _ in .selectedRepositories },
            now: { self.now }
        )

        let access = try await session.refreshInstallationState()

        #expect(access == .selectedRepositories)
        #expect(session.state == .partialAuthorization)
    }

    @Test("项目授权状态使用明确的图标与语义色")
    func projectAccessStatePresentationIsConsistent() {
        #expect(ProjectAccessState.disconnected.statusSymbolName == "lock.shield")
        #expect(ProjectAccessState.disconnected.statusTone == .neutral)

        #expect(
            ProjectAccessState.connected(expiresAt: nil).statusSymbolName
                == "checkmark.circle.fill"
        )
        #expect(ProjectAccessState.connected(expiresAt: nil).statusTone == .success)

        #expect(ProjectAccessState.connecting.statusTone == .active)
        #expect(ProjectAccessState.awaitingAuthorization.statusTone == .active)
        #expect(ProjectAccessState.partialAuthorization.statusTone == .warning)
        #expect(ProjectAccessState.organizationApprovalPending.statusTone == .warning)
        #expect(ProjectAccessState.revoked.statusTone == .failure)
        #expect(ProjectAccessState.failed(.network).statusTone == .failure)
    }

    @Test("安装校验断网时保留凭据并进入可重试状态")
    @MainActor
    func installationCheckFailureKeepsCredential() async throws {
        let keychain = InMemoryKeychain()
        let issued = credential(token: "ghu-project", accessOffset: 3_600)
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: issued),
            keychain: keychain,
            isConfigured: true,
            appSlug: "starcat-project-access",
            installationCheck: { _, _ in
                throw NetworkError.transport(underlying: URLError(.notConnectedToInternet))
            },
            now: { self.now }
        )

        _ = try await session.beginConnection()
        await #expect(throws: NetworkError.self) {
            try await session.completeConnection(callbackURL: callbackURL)
        }

        #expect(session.state == .installationCheckFailed(.network))
        #expect(try keychain.loadProjectAccessCredential() != nil)
    }

    @Test("安装复查返回 401 时进入撤销状态并保留主 OAuth")
    @MainActor
    func unauthorizedInstallationCheckMarksCredentialRevoked() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeGithubToken("oauth-main")
        let issued = credential(token: "ghu-project", accessOffset: 3_600)
        try storedCredential(keychain, issued)
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: issued),
            keychain: keychain,
            isConfigured: true,
            appSlug: "starcat-for-github",
            installationCheck: { _, _ in
                throw NetworkError.unauthorized
            },
            now: { self.now }
        )

        do {
            try await session.refreshInstallationState()
            Issue.record("预期安装复查抛出 unauthorized")
        } catch NetworkError.unauthorized {
            // 401 是本用例要验证的明确撤销信号。
        } catch {
            Issue.record("收到非预期错误：\(error)")
        }

        #expect(session.state == .revoked)
        #expect(try keychain.loadProjectAccessCredential() == nil)
        #expect(try keychain.loadGithubToken() == "oauth-main")
    }

    @Test("access token 过期前自动轮换整份凭据")
    @MainActor
    func refreshesExpiringCredential() async throws {
        let keychain = InMemoryKeychain()
        let old = credential(token: "old", accessOffset: 10, refreshToken: "refresh-old")
        let new = credential(token: "new", accessOffset: 3_600, refreshToken: "refresh-new")
        try storedCredential(keychain, old)
        let oauth = MockOAuth(credential: old, refreshed: new)
        let session = ProjectAccessSession(
            oauthService: oauth,
            keychain: keychain,
            isConfigured: true,
            now: { self.now }
        )

        let token = try await session.validAccessToken()

        #expect(token == "new")
        #expect(oauth.refreshInputs == ["refresh-old"])
        #expect(session.state == .connected(expiresAt: new.accessExpiresAt))
        #expect(try keychain.loadProjectAccessCredential()?.contains("refresh-new") == true)
    }

    @Test("refresh token 过期进入 expired，但 OAuth token 保留")
    @MainActor
    func expiredRefreshFallsBackWithoutLoggingOut() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeGithubToken("oauth-main")
        let expired = credential(
            token: "old",
            accessOffset: -10,
            refreshToken: "expired",
            refreshOffset: -10
        )
        try storedCredential(keychain, expired)
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: expired),
            keychain: keychain,
            isConfigured: true,
            now: { self.now }
        )

        await #expect(throws: ProjectAccessSessionError.expired) {
            try await session.validAccessToken()
        }

        #expect(session.state == .expired)
        #expect(try keychain.loadGithubToken() == "oauth-main")
    }

    @Test("401 撤销只清理项目凭据")
    @MainActor
    func revokedDoesNotDeleteOAuthToken() throws {
        let keychain = InMemoryKeychain()
        try keychain.storeGithubToken("oauth-main")
        try storedCredential(keychain, credential(token: "project", accessOffset: 100))
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: credential(token: "project", accessOffset: 100)),
            keychain: keychain,
            isConfigured: true,
            now: { self.now }
        )

        session.markRevoked()

        #expect(session.state == .revoked)
        #expect(try keychain.loadProjectAccessCredential() == nil)
        #expect(try keychain.loadGithubToken() == "oauth-main")
    }

    @Test("凭据路由优先 GitHub App，断开后回退 OAuth")
    @MainActor
    func credentialRouterPrefersAppThenOAuth() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeGithubToken("oauth-main")
        let appCredential = credential(token: "github-app", accessOffset: 3_600)
        try storedCredential(keychain, appCredential)
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: appCredential),
            keychain: keychain,
            isConfigured: true,
            now: { self.now }
        )
        let router = ProjectCredentialRouter(projectAccessSession: session, keychain: keychain)

        let appRoute = try await router.resolve()
        #expect(appRoute.authorizationSource == .githubApp)
        #expect(appRoute.accessToken == "github-app")

        try await session.disconnect()
        let oauthRoute = try await router.resolve()
        #expect(oauthRoute.authorizationSource == .oauth)
        #expect(oauthRoute.accessToken == "oauth-main")
    }

    @Test("断开连接先撤销远端 grant 再删除本机凭据")
    @MainActor
    func disconnectRevokesGrantBeforeLocalCleanup() async throws {
        let keychain = InMemoryKeychain()
        let appCredential = credential(token: "github-app", accessOffset: 3_600)
        try storedCredential(keychain, appCredential)
        let oauth = MockOAuth(credential: appCredential)
        let session = ProjectAccessSession(
            oauthService: oauth,
            keychain: keychain,
            isConfigured: true,
            now: { self.now }
        )

        try await session.disconnect()

        #expect(oauth.revokedTokens == ["github-app"])
        #expect(try keychain.loadProjectAccessCredential() == nil)
        #expect(session.state == .disconnected)
    }

    @Test("远端 grant 撤销失败时保留本机凭据以便重试")
    @MainActor
    func disconnectFailurePreservesCredential() async throws {
        let keychain = InMemoryKeychain()
        let appCredential = credential(token: "github-app", accessOffset: 3_600)
        try storedCredential(keychain, appCredential)
        let oauth = MockOAuth(credential: appCredential)
        oauth.revokeError = .network
        let session = ProjectAccessSession(
            oauthService: oauth,
            keychain: keychain,
            isConfigured: true,
            now: { self.now }
        )

        await #expect(throws: ProjectAccessOAuthError.network) {
            try await session.disconnect()
        }

        #expect(try keychain.loadProjectAccessCredential() != nil)
        #expect(session.state == .failed(.network))
    }

    @Test("部分授权与组织待审批为独立可见状态")
    @MainActor
    func exposesPartialAndApprovalStates() {
        let issued = credential(token: "project", accessOffset: 100)
        let session = ProjectAccessSession(
            oauthService: MockOAuth(credential: issued),
            keychain: InMemoryKeychain(),
            isConfigured: true,
            now: { self.now }
        )

        session.markPartialAuthorization()
        #expect(session.state == .partialAuthorization)
        session.markOrganizationApprovalPending()
        #expect(session.state == .organizationApprovalPending)
    }

    @MainActor
    private static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
    }
}
