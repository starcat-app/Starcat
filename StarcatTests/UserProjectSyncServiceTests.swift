//
//  UserProjectSyncServiceTests.swift
//  StarcatTests
//
//  验证“我的项目”应用级同步服务的状态、去重与后台生命周期。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("UserProjectSyncService")
struct UserProjectSyncServiceTests {
    @Test("并发刷新共享同一个任务并发布完成状态")
    func concurrentRefreshesShareTask() async throws {
        let keychain = InMemoryKeychain()
        let accessSession = ProjectAccessSession(
            oauthService: ProjectAccessOAuthServiceStub(),
            keychain: keychain,
            isConfigured: false
        )
        let counter = SyncInvocationCounter()
        let completedAt = Date(timeIntervalSince1970: 1_000)
        let service = UserProjectSyncService(
            projectAccessSession: accessSession,
            resolveCredential: {
                ResolvedProjectCredential(accessToken: "oauth", authorizationSource: .oauth)
            },
            performSync: { userID, credential, force in
                await counter.record(userID: userID, source: credential.authorizationSource, force: force)
                try await Task.sleep(for: .milliseconds(30))
                return UserProjectSyncSummary(receivedCount: 3, unchangedAffiliations: [])
            },
            now: { completedAt }
        )

        async let first = service.refresh(userID: 7)
        async let second = service.refresh(userID: 7, force: true)
        let summaries = try await [first, second]

        #expect(summaries.allSatisfy { $0.receivedCount == 3 })
        #expect(await counter.count == 1)
        #expect(service.state == UserProjectSyncServiceState.completed(at: completedAt, receivedCount: 3))
    }

    @Test("错误被转换成稳定失败码")
    func mapsFailureCode() async {
        let accessSession = ProjectAccessSession(
            oauthService: ProjectAccessOAuthServiceStub(),
            keychain: InMemoryKeychain(),
            isConfigured: false
        )
        let service = UserProjectSyncService(
            projectAccessSession: accessSession,
            resolveCredential: {
                ResolvedProjectCredential(accessToken: "oauth", authorizationSource: .oauth)
            },
            performSync: { _, _, _ in
                throw NetworkError.rateLimited(retryAfter: 60)
            }
        )

        await #expect(throws: NetworkError.self) {
            try await service.refresh(userID: 8)
        }
        #expect(service.state == UserProjectSyncServiceState.failed(.rateLimited))
    }

    @Test("GitHub App 部分同步映射独立授权状态")
    func mapsGitHubAppPartialState() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeProjectAccessCredential(
            String(
                data: try JSONEncoder().encode(
                    ProjectAccessCredential(
                        accessToken: "project-token",
                        accessExpiresAt: nil,
                        refreshToken: nil,
                        refreshExpiresAt: nil
                    )
                ),
                encoding: .utf8
            )!
        )
        let accessSession = ProjectAccessSession(
            oauthService: ProjectAccessOAuthServiceStub(),
            keychain: keychain,
            isConfigured: true,
            installationCheck: { _, _ in .allRepositories }
        )
        let service = UserProjectSyncService(
            projectAccessSession: accessSession,
            resolveCredential: {
                ResolvedProjectCredential(
                    accessToken: "project-token",
                    authorizationSource: .githubApp
                )
            },
            performSync: { _, _, _ in
                UserProjectSyncSummary(
                    receivedCount: 2,
                    unchangedAffiliations: [],
                    failedAffiliations: [.owner: "transport"]
                )
            }
        )

        _ = try await service.refresh(userID: 10)

        #expect(accessSession.state == .partialAuthorization)
    }

    @Test("GitHub App 组织链 403 映射待审批状态")
    func mapsOrganizationApprovalPendingState() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeProjectAccessCredential(
            String(
                data: try JSONEncoder().encode(
                    ProjectAccessCredential(
                        accessToken: "project-token",
                        accessExpiresAt: nil,
                        refreshToken: nil,
                        refreshExpiresAt: nil
                    )
                ),
                encoding: .utf8
            )!
        )
        let accessSession = ProjectAccessSession(
            oauthService: ProjectAccessOAuthServiceStub(),
            keychain: keychain,
            isConfigured: true,
            installationCheck: { _, _ in .allRepositories }
        )
        let service = UserProjectSyncService(
            projectAccessSession: accessSession,
            resolveCredential: {
                ResolvedProjectCredential(
                    accessToken: "project-token",
                    authorizationSource: .githubApp
                )
            },
            performSync: { _, _, _ in
                UserProjectSyncSummary(
                    receivedCount: 1,
                    unchangedAffiliations: [],
                    failedAffiliations: [.organizationMember: "client_403"]
                )
            }
        )

        _ = try await service.refresh(userID: 11)

        #expect(accessSession.state == .organizationApprovalPending)
    }

    @Test("GitHub App 安装被删除时同次刷新回退 OAuth Public")
    func deletedInstallationFallsBackToOAuth() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeGithubToken("oauth-main")
        try keychain.storeProjectAccessCredential(
            String(
                data: try JSONEncoder().encode(
                    ProjectAccessCredential(
                        accessToken: "project-token",
                        accessExpiresAt: nil,
                        refreshToken: nil,
                        refreshExpiresAt: nil
                    )
                ),
                encoding: .utf8
            )!
        )
        let accessSession = ProjectAccessSession(
            oauthService: ProjectAccessOAuthServiceStub(),
            keychain: keychain,
            isConfigured: true,
            appSlug: "starcat-for-github",
            installationCheck: { _, _ in .notInstalled }
        )
        let router = ProjectCredentialRouter(
            projectAccessSession: accessSession,
            keychain: keychain
        )
        let recorder = SyncCredentialRecorder()
        let service = UserProjectSyncService(
            projectAccessSession: accessSession,
            resolveCredential: {
                try await router.resolve()
            },
            performSync: { _, credential, _ in
                await recorder.record(credential)
                return UserProjectSyncSummary(receivedCount: 4, unchangedAffiliations: [])
            }
        )

        _ = try await service.refresh(userID: 12)

        #expect(accessSession.state == .installationRequired)
        #expect(await recorder.credentials == [
            ResolvedProjectCredential(
                accessToken: "oauth-main",
                authorizationSource: .oauth
            )
        ])
        #expect(try keychain.loadProjectAccessCredential() != nil)
    }

    @Test("指定仓库安装范围在完整同步后仍保持部分授权")
    func selectedInstallationRemainsPartialAfterSuccessfulSync() async throws {
        let keychain = InMemoryKeychain()
        try keychain.storeProjectAccessCredential(
            String(
                data: try JSONEncoder().encode(
                    ProjectAccessCredential(
                        accessToken: "project-token",
                        accessExpiresAt: nil,
                        refreshToken: nil,
                        refreshExpiresAt: nil
                    )
                ),
                encoding: .utf8
            )!
        )
        let accessSession = ProjectAccessSession(
            oauthService: ProjectAccessOAuthServiceStub(),
            keychain: keychain,
            isConfigured: true,
            appSlug: "starcat-for-github",
            installationCheck: { _, _ in .selectedRepositories }
        )
        let router = ProjectCredentialRouter(
            projectAccessSession: accessSession,
            keychain: keychain
        )
        let service = UserProjectSyncService(
            projectAccessSession: accessSession,
            resolveCredential: {
                try await router.resolve()
            },
            performSync: { _, _, _ in
                UserProjectSyncSummary(receivedCount: 2, unchangedAffiliations: [])
            }
        )

        _ = try await service.refresh(userID: 13)

        #expect(accessSession.state == .partialAuthorization)
    }

    @Test("后台刷新启动和停止保持幂等")
    func backgroundLifecycleIsIdempotent() {
        let accessSession = ProjectAccessSession(
            oauthService: ProjectAccessOAuthServiceStub(),
            keychain: InMemoryKeychain(),
            isConfigured: false
        )
        let service = UserProjectSyncService(
            projectAccessSession: accessSession,
            resolveCredential: {
                ResolvedProjectCredential(accessToken: "oauth", authorizationSource: .oauth)
            },
            performSync: { _, _, _ in
                UserProjectSyncSummary(receivedCount: 0, unchangedAffiliations: [])
            }
        )

        service.startBackgroundRefresh(userID: 9)
        service.startBackgroundRefresh(userID: 9)
        #expect(service.isBackgroundRefreshEnabled)

        service.stopBackgroundRefresh()
        service.stopBackgroundRefresh()
        #expect(!service.isBackgroundRefreshEnabled)
        #expect(service.state == UserProjectSyncServiceState.idle)
    }
}

private actor SyncInvocationCounter {
    private(set) var count = 0

    func record(
        userID: Int64,
        source: ProjectAuthorizationSource,
        force: Bool
    ) {
        _ = (userID, source, force)
        count += 1
    }
}

private actor SyncCredentialRecorder {
    private(set) var credentials: [ResolvedProjectCredential] = []

    func record(_ credential: ResolvedProjectCredential) {
        credentials.append(credential)
    }
}

private actor ProjectAccessOAuthServiceStub: ProjectAccessOAuthServiceProtocol {
    func beginDeviceFlow() async throws -> OAuthDeviceCodeInfo {
        throw ProjectAccessOAuthError.configurationMissing
    }

    func awaitCredential() async throws -> ProjectAccessCredential {
        throw ProjectAccessOAuthError.flowNotStarted
    }

    func refreshCredential(using refreshToken: String) async throws -> ProjectAccessCredential {
        _ = refreshToken
        throw ProjectAccessOAuthError.badRefreshToken
    }

    func reset() async {}
}
