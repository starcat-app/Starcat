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
