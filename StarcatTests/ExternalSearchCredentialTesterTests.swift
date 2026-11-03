//
//  ExternalSearchCredentialTesterTests.swift
//  StarcatTests
//
//  覆盖 External Search API Key 连通性测试的成本与安全边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("ExternalSearchCredentialTester")
@MainActor
struct ExternalSearchCredentialTesterTests {
    // 五家服务商共用启用引导，认证模式必须全部遵守“先验证、后保存并启用”。
    @Test("成功时使用固定 credentialTest 请求并保存启用 Provider",
          arguments: ExternalSearchProviderID.allCases)
    func successSavesVerifiedKeyAndEnablesProvider(providerID: ExternalSearchProviderID) async throws {
        let settings = makeSettings()
        let recorder = CredentialTestRecorder()
        let tester = ExternalSearchCredentialTester(
            settings: settings,
            providerFactory: { providerID, _, _ in
                StubCredentialProvider(providerID: providerID, recorder: recorder)
            }
        )

        let outcome = await tester.test(provider: providerID, candidateKey: " test-key ")

        #expect(outcome == .succeeded)
        #expect(recorder.requests == [ExternalSearchRequest(
            query: ExternalSearchCredentialTester.testQuery,
            purpose: .credentialTest,
            maxResults: ExternalSearchCredentialTester.testMaxResults
        )])
        #expect(settings.externalSearchAPIKey(for: providerID) == "test-key")
        #expect(settings.externalSearchSettings(for: providerID).hasVerifiedCredential)
        #expect(settings.externalSearchSettings(for: providerID).isEnabled)
    }

    @Test("失败时不保存候选 Key 且错误详情脱敏",
          arguments: ExternalSearchProviderID.allCases)
    func failureDoesNotSaveCandidateKeyAndRedactsDetails(providerID: ExternalSearchProviderID) async throws {
        let settings = makeSettings()
        settings.setExternalSearchAPIKey("old-key", for: providerID)
        settings.markExternalSearchCredentialVerified(for: providerID)
        var providerSettings = settings.externalSearchSettings(for: providerID)
        providerSettings.isEnabled = false
        settings.setExternalSearchSettings(providerSettings, for: providerID)
        let tester = ExternalSearchCredentialTester(
            settings: settings,
            providerFactory: { providerID, _, _ in
                StubCredentialProvider(
                    providerID: providerID,
                    error: ExternalSearchError.invalidCredential(
                        provider: providerID,
                        statusCode: 401,
                        message: "bad key for who is dong4j"
                    )
                )
            }
        )

        let outcome = await tester.test(provider: providerID, candidateKey: "new-secret-key")

        guard case .failed(let failure) = outcome else {
            Issue.record("Expected failed outcome")
            return
        }
        #expect(settings.externalSearchAPIKey(for: providerID) == "old-key")
        #expect(settings.externalSearchSettings(for: providerID).hasVerifiedCredential)
        #expect(!settings.externalSearchSettings(for: providerID).isEnabled)
        #expect(failure.friendlyMessage == ExternalSearchError.invalidCredential(provider: providerID, statusCode: 401, message: nil).friendlyMessage)
        #expect(failure.technicalDetails?.contains("httpStatus=401") == true)
        #expect(failure.technicalDetails?.contains("who is dong4j") == false)
        #expect(failure.technicalDetails?.contains("new-secret-key") == false)
    }

    @Test("编辑后旧请求成功或失败均不改变已存连接", arguments: [false, true])
    func supersededProbeDoesNotCommit(fails: Bool) async throws {
        let settings = makeSettings()
        settings.setExternalSearchAPIKey("saved-key", for: .tavily)
        settings.markExternalSearchCredentialVerified(for: .tavily)
        let original = settings.externalSearchSettings(for: .tavily)
        let gate = CredentialProbeGate()
        var isCurrent = true
        let tester = ExternalSearchCredentialTester(settings: settings, providerFactory: { provider, _, _ in
            DeferredCredentialProvider(providerID: provider, gate: gate)
        })
        let task = Task {
            await tester.test(provider: .tavily, candidateKey: "draft", isCurrent: { isCurrent })
        }
        for _ in 0..<100 where gate.continuation == nil { await Task.yield() }
        let pending = try #require(gate.continuation)
        isCurrent = false
        if fails { pending.resume(throwing: URLError(.notConnectedToInternet)) }
        else { pending.resume() }
        let result = await task.value
        #expect(result == .superseded)
        #expect(settings.externalSearchAPIKey(for: .tavily) == "saved-key")
        #expect(settings.externalSearchSettings(for: .tavily) == original)
    }

    @Test("已存 Key 重测失败才撤销该 Key 的验证")
    func failedSavedKeyLosesVerification() async {
        let settings = makeSettings()
        settings.setExternalSearchAPIKey("saved-key", for: .tavily)
        settings.markExternalSearchCredentialVerified(for: .tavily)
        let tester = ExternalSearchCredentialTester(settings: settings, providerFactory: { provider, _, _ in
            StubCredentialProvider(providerID: provider, error: URLError(.notConnectedToInternet))
        })
        _ = await tester.test(provider: .tavily, candidateKey: "saved-key")
        #expect(!settings.externalSearchSettings(for: .tavily).hasVerifiedCredential)
        #expect(settings.externalSearchAPIKey(for: .tavily) == "saved-key")
    }

    @Test("Key 保存失败不标记已验证或启用")
    func keychainFailureDoesNotEnableProvider() async {
        let settings = makeSettings(keychain: InMemoryKeychain(rejectsServiceKeyWrites: true))
        let tester = ExternalSearchCredentialTester(settings: settings, providerFactory: { provider, _, _ in
            StubCredentialProvider(providerID: provider)
        })
        let outcome = await tester.test(provider: .tavily, candidateKey: "draft")
        #expect(outcome == .saveFailed)
        #expect(!settings.externalSearchSettings(for: .tavily).hasVerifiedCredential)
        #expect(!settings.externalSearchSettings(for: .tavily).isEnabled)
    }

    private func makeSettings(keychain: InMemoryKeychain = InMemoryKeychain()) -> AppSettings {
        let suite = "ExternalSearchCredentialTesterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults, keychain: keychain)
    }
}

/// 在 MainActor 上精确控制完成顺序，避免依赖延时或访问真实服务。
@MainActor
private final class CredentialProbeGate {
    var continuation: CheckedContinuation<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

private struct DeferredCredentialProvider: ExternalSearchProvider {
    let providerID: ExternalSearchProviderID
    let gate: CredentialProbeGate
    var id: ExternalSearchProviderID { providerID }
    var capabilities: ExternalSearchCapabilities { .capabilities(for: providerID) }

    func search(_ request: ExternalSearchRequest) async throws -> ExternalSearchResponse {
        try await gate.wait()
        return ExternalSearchResponse(hits: [], metadata: ExternalSearchMetadata(provider: providerID))
    }
}

private final class CredentialTestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ExternalSearchRequest] = []

    var requests: [ExternalSearchRequest] { lock.withLock { values } }

    func record(_ request: ExternalSearchRequest) {
        lock.withLock { values.append(request) }
    }
}

private struct StubCredentialProvider: ExternalSearchProvider {
    let providerID: ExternalSearchProviderID
    let recorder: CredentialTestRecorder?
    var error: Error?

    init(
        providerID: ExternalSearchProviderID,
        recorder: CredentialTestRecorder? = nil,
        error: Error? = nil
    ) {
        self.providerID = providerID
        self.recorder = recorder
        self.error = error
    }

    var id: ExternalSearchProviderID { providerID }
    var capabilities: ExternalSearchCapabilities { .capabilities(for: providerID) }

    func search(_ request: ExternalSearchRequest) async throws -> ExternalSearchResponse {
        recorder?.record(request)
        if let error { throw error }
        return ExternalSearchResponse(
            hits: [],
            metadata: ExternalSearchMetadata(provider: providerID)
        )
    }
}
