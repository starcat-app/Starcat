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
        var beginResult = OAuthDeviceCodeInfo(
            userCode: "ABCD-EFGH",
            verificationURI: URL(string: "https://github.com/login/device")!,
            expiresIn: 900,
            pollInterval: 5
        )
        var credential: ProjectAccessCredential
        var refreshed: ProjectAccessCredential
        private(set) var refreshInputs: [String] = []

        init(credential: ProjectAccessCredential, refreshed: ProjectAccessCredential? = nil) {
            self.credential = credential
            self.refreshed = refreshed ?? credential
        }

        func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo { beginResult }
        func awaitCredential() async throws -> ProjectAccessCredential { credential }
        func refreshCredential(using refreshToken: String) async throws -> ProjectAccessCredential {
            refreshInputs.append(refreshToken)
            return refreshed
        }
        func reset() async {}
    }

    private let now = Date(timeIntervalSince1970: 10_000)

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

    @Test("Device Flow 连接只写项目凭据，不覆盖 OAuth token")
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
            installationCheck: { _, _ in true },
            now: { self.now }
        )

        let info = try await session.beginConnection()
        #expect(session.state == .awaitingAuthorization(info))
        try await session.completeConnection()

        #expect(session.state == .connected(expiresAt: issued.accessExpiresAt))
        #expect(try keychain.loadGithubToken() == "oauth-main")
        #expect(try keychain.loadProjectAccessCredential() != nil)
    }

    @Test("Device Flow 成功但未安装 App 时保留凭据并回退 Public 项目")
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
            installationCheck: { _, _ in false },
            now: { self.now }
        )

        _ = try await session.beginConnection()
        try await session.completeConnection()

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
            },
            now: { self.now }
        )

        let installed = try await session.refreshInstallationState()

        #expect(installed)
        #expect(session.state == .connected(expiresAt: issued.accessExpiresAt))
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

        try session.disconnect()
        let oauthRoute = try await router.resolve()
        #expect(oauthRoute.authorizationSource == .oauth)
        #expect(oauthRoute.accessToken == "oauth-main")
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
}
