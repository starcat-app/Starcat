//
//  ExternalSearchSettingsTests.swift
//  StarcatTests
//
//  验证 External Search 设置的本机持久化边界。
//
//  关键约束：
//  - Provider API Key 只进入 KeychainManaging，不写入 UserDefaults。
//  - verified marker 是本机状态；Key 被编辑或删除后必须清空，避免旧 Key 的测试结果
//    错误套用到新 Key。
//

import Foundation
import Testing
@testable import Starcat

@Suite("External Search Settings")
@MainActor
struct ExternalSearchSettingsTests {
    @Test("默认设置安全关闭，AnySearch 保留匿名能力")
    func defaultsAreSafe() throws {
        let (settings, _) = makeSettings()

        #expect(settings.externalSearchIncludeInAll == false)
        #expect(settings.externalContextEnabled == false)
        #expect(settings.externalSearchAllowPrivateRepos == false)
        #expect(settings.externalSearchDefaultProvider == .anySearch)
        #expect(settings.externalContextProviderSelection == .automatic)
        #expect(settings.aggregateExternalContextSearchEnabled == false)
        #expect(settings.externalSearchSettings(for: .anySearch).anonymousMode == true)
        #expect(settings.externalSearchSettings(for: .tavily).anonymousMode == false)
    }

    @Test("Provider 设置持久化且 API Key 不进入 UserDefaults")
    func providerSettingsPersistAndAPIKeyUsesKeychain() throws {
        let (settings, defaults) = makeSettings()

        settings.externalSearchIncludeInAll = true
        settings.externalContextEnabled = true
        settings.externalSearchAllowPrivateRepos = true
        settings.externalSearchDefaultProvider = .exa
        settings.externalContextProviderSelection = .tavily
        settings.aggregateExternalContextSearchEnabled = true
        var tavily = settings.externalSearchSettings(for: .tavily)
        tavily.defaultMaxResults = 12
        settings.setExternalSearchSettings(tavily, for: .tavily)
        settings.setExternalSearchAPIKey(" tavily-secret ", for: .tavily)

        let restored = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        #expect(restored.externalSearchIncludeInAll == true)
        #expect(restored.externalContextEnabled == true)
        #expect(restored.externalSearchAllowPrivateRepos == true)
        #expect(restored.externalSearchDefaultProvider == .exa)
        #expect(restored.externalContextProviderSelection == .tavily)
        #expect(restored.aggregateExternalContextSearchEnabled == true)
        #expect(restored.externalSearchSettings(for: .tavily).defaultMaxResults == 12)
        #expect(defaults.dictionaryRepresentation().values.allSatisfy { "\($0)" != "tavily-secret" })
        #expect(settings.externalSearchAPIKey(for: .tavily) == "tavily-secret")
    }

    @Test("Test 成功标记会启用 Provider，编辑 Key 后清除标记")
    func credentialVerificationLifecycle() throws {
        let (settings, _) = makeSettings()

        settings.markExternalSearchCredentialVerified(for: .exa, at: Date(timeIntervalSince1970: 123))
        #expect(settings.externalSearchSettings(for: .exa).isEnabled == true)
        #expect(settings.externalSearchSettings(for: .exa).hasVerifiedCredential == true)

        settings.setExternalSearchAPIKey("new-key", for: .exa)

        #expect(settings.externalSearchAPIKey(for: .exa) == "new-key")
        #expect(settings.externalSearchSettings(for: .exa).hasVerifiedCredential == false)
        #expect(settings.externalSearchSettings(for: .exa).isEnabled == true)
    }

    @Test("resetToDefaults 清空 External Search 设置与凭据")
    func resetClearsExternalSearchSettingsAndCredentials() throws {
        let (settings, _) = makeSettings()
        settings.externalSearchIncludeInAll = true
        settings.externalContextEnabled = true
        settings.externalSearchAllowPrivateRepos = true
        settings.externalSearchDefaultProvider = .braveLLMContext
        settings.externalContextProviderSelection = .exa
        settings.aggregateExternalContextSearchEnabled = true
        settings.setExternalSearchAPIKey("exa-key", for: .exa)
        settings.markExternalSearchCredentialVerified(for: .exa)

        try settings.resetToDefaults()

        #expect(settings.externalSearchIncludeInAll == false)
        #expect(settings.externalContextEnabled == false)
        #expect(settings.externalSearchAllowPrivateRepos == false)
        #expect(settings.externalSearchDefaultProvider == .anySearch)
        #expect(settings.externalContextProviderSelection == .automatic)
        #expect(settings.aggregateExternalContextSearchEnabled == false)
        #expect(settings.externalSearchAPIKey(for: .exa) == nil)
        #expect(settings.externalSearchSettings(for: .exa).isEnabled == false)
        #expect(settings.externalSearchSettings(for: .exa).hasVerifiedCredential == false)
    }

    private func makeSettings() -> (AppSettings, UserDefaults) {
        let suite = "ExternalSearchSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (AppSettings(defaults: defaults, keychain: InMemoryKeychain()), defaults)
    }
}
