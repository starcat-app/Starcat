//
//  JevConnectionSettingsTests.swift
//  StarcatTests
//
//  实验功能设置的连接状态回归：失败保留原生配置、修正后可重试，
//  备用连接不覆盖模型，过期探测不得写回凭据或失败标记。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("JevConnectionSettings")
struct JevConnectionSettingsTests {
    private enum ProbeError: LocalizedError {
        case invalidModel
        var errorDescription: String? { "invalid native model" }
    }

    /// 隔离开发者的实际 Keychain 与偏好，每个用例拥有独立设置域。
    private func makeSettings(_ keychain: InMemoryKeychain) -> AppSettings {
        AppSettings(
            defaults: UserDefaults(suiteName: "test.starcat.jevSettings.\(UUID().uuidString)")!,
            keychain: keychain
        )
    }

    private func configureFallback(_ settings: AppSettings, keychain: InMemoryKeychain) throws {
        settings.aiProviderProfiles = [
            AIProviderProfile(
                id: "openrouter-test", provider: .openRouter,
                displayName: "OpenRouter Test", isEnabled: true,
                lastTestStatus: .success(modelCount: 1)
            )
        ]
        try keychain.storeAIKey("or-test-key", forProvider: "openrouter-test")
    }

    @Test("接口候选与固定版本合并去重，不写入 Key 或验证状态")
    func modelListMergesWithoutVerifyingConnection() async throws {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        var requestedKey: String?
        let model = JevConnectionSettingsModel(
            settings: settings, keychain: keychain,
            modelLoader: { key in
                requestedKey = key
                return ["jev-latest", "jev-preview", "jev-1.14.0", "jev-latest", " ", " jev-1.13.0 "]
            }
        )
        model.draftAPIKey = " draft-key "
        model.nativeModelID = "jev-1.14.0"
        settings.typesafeNativeKeyTestFailed = true
        await model.refreshModels()
        #expect(requestedKey == "draft-key")
        #expect(model.availableModelIDs == ["jev-1.13.0", "jev-1.14.0", "jev-latest", "jev-preview"])
        #expect(model.nativeModelID == "jev-1.14.0")
        #expect(!model.isLoadingModels)
        #expect(!model.modelListFailed)
        #expect(model.testState == .idle)
        #expect(settings.typesafeNativeKeyTestFailed)
        #expect(try keychain.loadServiceAPIKey(forService: JevDecisionEngine.keychainServiceID) == nil)
    }

    @Test("获取失败保留固定候选、选择和凭据，可刷新重试")
    func failedModelListCanBeRetried() async {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        var shouldFail = true
        let model = JevConnectionSettingsModel(
            settings: settings, keychain: keychain,
            modelLoader: { _ in
                if shouldFail { throw ProbeError.invalidModel }
                return ["jev-latest"]
            }
        )
        model.draftAPIKey = "draft"
        model.nativeModelID = "jev-1.14.0"
        await model.refreshModels()
        #expect(model.availableModelIDs == JevConnectionSettingsModel.fixedModelIDs)
        #expect(model.modelListFailed)
        #expect(!model.isLoadingModels)
        #expect(model.canTest)
        #expect(model.draftAPIKey == "draft")
        #expect(!settings.typesafeNativeKeyTestFailed)
        shouldFail = false
        await model.refreshModels()
        #expect(!model.modelListFailed)
        #expect(model.availableModelIDs.contains("jev-latest"))
        #expect(model.nativeModelID == "jev-1.14.0")
    }

    @Test("列表外旧模型不被静默覆盖，重选后恢复测试")
    func unknownSavedModelRequiresSelection() async {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        settings.typesafeModelID = "jev-1.15"
        let model = JevConnectionSettingsModel(
            settings: settings, keychain: keychain, modelLoader: { _ in [] }
        )
        model.draftAPIKey = "draft"
        await model.refreshModels()
        #expect(model.nativeModelID == "jev-1.15")
        #expect(!model.hasAvailableModelSelection)
        #expect(!model.canTest)
        model.nativeModelID = "jev-1.14.0"
        #expect(model.hasAvailableModelSelection)
        #expect(model.canTest)
    }

    @Test("改 Key 后过期列表的成功和失败都不能覆盖新状态", arguments: [false, true])
    func staleModelListCannotOverwriteNewKey(fails: Bool) async throws {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        var continuation: CheckedContinuation<[String], Error>?
        let model = JevConnectionSettingsModel(
            settings: settings, keychain: keychain,
            modelLoader: { key in
                if key == "old" {
                    return try await withCheckedThrowingContinuation { continuation = $0 }
                }
                return ["jev-preview"]
            }
        )
        model.draftAPIKey = "old"
        let task = Task { await model.refreshModels() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        model.draftAPIKey = "new"
        await model.refreshModels()
        if fails {
            pending.resume(throwing: ProbeError.invalidModel)
        } else {
            pending.resume(returning: ["old-private-model"])
        }
        await task.value
        #expect(model.availableModelIDs == JevConnectionSettingsModel.fixedModelIDs + ["jev-preview"])
        #expect(!model.modelListFailed)
        #expect(!model.isLoadingModels)
    }

    @Test("无 Key 不请求列表，清空 Key 移除此前账号的候选")
    func emptyKeyDoesNotLoadModels() async {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        var callCount = 0
        let model = JevConnectionSettingsModel(
            settings: settings, keychain: keychain,
            modelLoader: { _ in callCount += 1; return ["jev-latest"] }
        )
        await model.refreshModels()
        #expect(callCount == 0)
        model.draftAPIKey = "draft"
        await model.refreshModels()
        #expect(callCount == 1)
        #expect(model.availableModelIDs.contains("jev-latest"))
        model.draftAPIKey = ""
        await model.refreshModels()
        #expect(callCount == 1)
        #expect(model.availableModelIDs == JevConnectionSettingsModel.fixedModelIDs)
    }

    @Test("模型测试失败后保留选择，重选模型可重新测试原生连接")
    func failedModelCanBeCorrectedAndRetested() async throws {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        var calls: [JevDecisionAccess] = []
        let model = JevConnectionSettingsModel(settings: settings, keychain: keychain, probe: { access in
            calls.append(access)
            if access.modelID == "jev-1.14.0" { throw ProbeError.invalidModel }
            return .init(elapsedMilliseconds: 12, noul: 0.98)
        })
        model.draftAPIKey = "native-draft"
        model.nativeModelID = "jev-1.14.0"
        await model.testConnection()
        #expect(model.nativeModelID == "jev-1.14.0")
        #expect(model.draftAPIKey == "native-draft")
        #expect(model.nativeConnectionFailed)
        #expect(model.testState == .failed("invalid native model"))
        #expect(model.canTest)
        #expect(try keychain.loadServiceAPIKey(forService: JevDecisionEngine.keychainServiceID) == nil)

        model.nativeModelID = JevDecisionEngine.defaultModelID
        #expect(model.testState == .idle)
        await model.testConnection()
        #expect(calls.map(\.modelID) == ["jev-1.14.0", JevDecisionEngine.defaultModelID])
        #expect(calls.allSatisfy { $0.api == .typeSafe })
        #expect(model.nativeCredentialIsUsable)
        #expect(!model.nativeConnectionFailed)
        #expect(model.nativeFailureMessage == nil)
        #expect(try keychain.loadServiceAPIKey(forService: JevDecisionEngine.keychainServiceID) == "native-draft")
    }

    @Test("备用测试通过仍保留原生失败原因和可编辑模型")
    func fallbackDoesNotReplaceNativeConfiguration() async throws {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        try configureFallback(settings, keychain: keychain)
        var calls: [JevDecisionAccess] = []
        let model = JevConnectionSettingsModel(settings: settings, keychain: keychain, probe: { access in
            calls.append(access)
            if access.api == .typeSafe { throw ProbeError.invalidModel }
            return .init(elapsedMilliseconds: 24, noul: 0.99)
        })
        model.draftAPIKey = "draft-key"
        model.nativeModelID = "jev-1.14.0"
        await model.testConnection()
        #expect(calls.map(\.modelID) == ["jev-1.14.0", JevDecisionEngine.openRouterModelID])
        #expect(model.nativeModelID == "jev-1.14.0")
        #expect(model.draftAPIKey == "draft-key")
        #expect(model.nativeFailureMessage == "invalid native model")
        #expect(model.isUsingOpenRouter)
        #expect(model.testState == .succeeded(
            source: .openRouter(profileID: "openrouter-test", displayName: "OpenRouter Test"),
            elapsedMilliseconds: 24, noul: 0.99
        ))
        // 备用连接成功不能把未验证的原生 Key 当作已保存或已验证。
        #expect(!model.hasStoredNativeAPIKey)
        #expect(try keychain.loadAIKey(forProvider: "openrouter-test") == "or-test-key")
        model.nativeModelID = JevDecisionEngine.defaultModelID
        #expect(model.canTest)
        #expect(model.nativeModelID == JevDecisionEngine.defaultModelID)
    }

    @Test("两条连接都失败时保留已存 Key 和模型")
    func bothFailuresDoNotDeleteCredentials() async throws {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        try configureFallback(settings, keychain: keychain)
        try keychain.storeServiceAPIKey("stored-key", forService: JevDecisionEngine.keychainServiceID)
        settings.typesafeModelID = "jev-1.14.0"
        let model = JevConnectionSettingsModel(settings: settings, keychain: keychain, probe: { _ in
            throw ProbeError.invalidModel
        })
        await model.testConnection()
        guard case .failed = model.testState else {
            Issue.record("Both failing probes must produce a failed result")
            return
        }
        #expect(model.nativeModelID == "jev-1.14.0")
        #expect(model.draftAPIKey == "stored-key")
        #expect(try keychain.loadServiceAPIKey(forService: JevDecisionEngine.keychainServiceID) == "stored-key")
        #expect(model.nativeConnectionFailed)
    }

    @Test("无原生 Key 时只测试备用连接，使用独立固定模型")
    func missingNativeKeyUsesFallback() async throws {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        try configureFallback(settings, keychain: keychain)
        settings.typesafeModelID = "native-custom"
        var calls: [JevDecisionAccess] = []
        let model = JevConnectionSettingsModel(settings: settings, keychain: keychain, probe: { access in
            calls.append(access)
            return .init(elapsedMilliseconds: 1, noul: 0.9)
        })
        await model.testConnection()
        #expect(calls.count == 1)
        #expect(calls.first?.api == .openRouter)
        #expect(calls.first?.modelID == JevDecisionEngine.openRouterModelID)
        #expect(model.nativeModelID == "native-custom")
        #expect(!model.nativeConnectionFailed)
    }

    @Test("探测进行中修改模型，旧失败不能给新模型写失败标记")
    func staleFailureCannotInvalidateEditedModel() async throws {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        var continuation: CheckedContinuation<JevConnectionSettingsModel.ProbeResult, Error>?
        let model = JevConnectionSettingsModel(settings: settings, keychain: keychain, probe: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        model.draftAPIKey = "draft"
        let task = Task { await model.testConnection() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        model.nativeModelID = "corrected-model"
        pending.resume(throwing: ProbeError.invalidModel)
        await task.value
        #expect(!settings.typesafeNativeKeyTestFailed)
        #expect(model.testState == .idle)
        #expect(model.nativeModelID == "corrected-model")
    }

    @Test("探测进行中修改 Key，旧成功不能保存过期凭据")
    func staleSuccessCannotSaveOldKey() async throws {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        var continuation: CheckedContinuation<JevConnectionSettingsModel.ProbeResult, Error>?
        let model = JevConnectionSettingsModel(settings: settings, keychain: keychain, probe: { _ in
            try await withCheckedThrowingContinuation { continuation = $0 }
        })
        model.draftAPIKey = "old-key"
        let task = Task { await model.testConnection() }
        for _ in 0..<100 where continuation == nil { await Task.yield() }
        let pending = try #require(continuation)
        model.draftAPIKey = "new-key"
        pending.resume(returning: .init(elapsedMilliseconds: 10, noul: 0.9))
        await task.value
        #expect(model.testState == .idle)
        #expect(model.draftAPIKey == "new-key")
        #expect(try keychain.loadServiceAPIKey(forService: JevDecisionEngine.keychainServiceID) == nil)
    }

    @Test("切换引擎与禁用功能不丢失 Jev 草稿及使用范围")
    func switchingEngineKeepsDrafts() {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        settings.decisionGroupingSuggestionsEnabled = true
        settings.decisionTagSuggestionsEnabled = false
        let model = JevConnectionSettingsModel(settings: settings, keychain: keychain)
        model.draftAPIKey = "draft"
        model.nativeModelID = "custom-model"
        settings.decisionEngineID = .laya
        settings.decisionEngineEnabled = false
        settings.decisionEngineEnabled = true
        settings.decisionEngineID = .jev
        #expect(model.draftAPIKey == "draft")
        #expect(model.nativeModelID == "custom-model")
        #expect(settings.decisionGroupingSuggestionsEnabled)
        #expect(!settings.decisionTagSuggestionsEnabled)
    }

    @Test("清空 Key 删除已存凭据并恢复备用路由，模型不变")
    func clearingNativeKeyKeepsModel() throws {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        try configureFallback(settings, keychain: keychain)
        try keychain.storeServiceAPIKey("stored-key", forService: JevDecisionEngine.keychainServiceID)
        settings.typesafeModelID = "custom-model"
        settings.typesafeNativeKeyTestFailed = true
        let model = JevConnectionSettingsModel(settings: settings, keychain: keychain)
        model.draftAPIKey = ""
        #expect(!model.hasStoredNativeAPIKey)
        #expect(!settings.typesafeNativeKeyTestFailed)
        #expect(model.isUsingOpenRouter)
        #expect(model.nativeModelID == "custom-model")
        #expect(try keychain.loadServiceAPIKey(forService: JevDecisionEngine.keychainServiceID) == nil)
    }

    @Test("禁用服务商后不再把旧备用配置显示为可用")
    func providerChangeRefreshesFallback() throws {
        let keychain = InMemoryKeychain()
        let settings = makeSettings(keychain)
        try configureFallback(settings, keychain: keychain)
        let model = JevConnectionSettingsModel(settings: settings, keychain: keychain)
        #expect(model.isUsingOpenRouter)
        settings.aiProviderProfiles[0].isEnabled = false
        model.refreshOpenRouterFallback()
        #expect(model.openRouterFallback == nil)
        #expect(!model.hasUsableCredential)
        #expect(!model.canTest)
    }
}
