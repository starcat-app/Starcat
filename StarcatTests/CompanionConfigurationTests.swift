//
//  CompanionConfigurationTests.swift
//  StarcatTests
//
//  验证 Browser Plugin 配置复用全局 Local API Key, 并只自行持久化端口/enabled。
//

import Foundation
import Testing
@testable import Starcat

@Suite("CompanionConfiguration")
@MainActor
struct CompanionConfigurationTests {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "CompanionConfigurationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeLocalAPIKeyStore(keychain: InMemoryKeychain) -> StarcatLocalAPIKeyStore {
        StarcatLocalAPIKeyStore(keychain: keychain)
    }

    @Test("首次初始化生成并持久化 Local API Key")
    func generatesAndStoresLocalAPIKey() throws {
        let keychain = InMemoryKeychain()
        let store = makeLocalAPIKeyStore(keychain: keychain)
        let config = CompanionConfiguration(localAPIKeyStore: store, defaults: try makeDefaults())

        #expect(!config.token.isEmpty)
        #expect(try keychain.loadServiceAPIKey(forService: "local_api") == config.token)
    }

    @Test("已有 Local API Key 时复用, 不重新生成")
    func reusesStoredLocalAPIKey() throws {
        let keychain = InMemoryKeychain()
        try keychain.storeServiceAPIKey("stored-token", forService: "local_api")
        let store = makeLocalAPIKeyStore(keychain: keychain)

        let config = CompanionConfiguration(localAPIKeyStore: store, defaults: try makeDefaults())

        #expect(config.token == "stored-token")
    }

    @Test("Local API Key 刷新后 Companion 立即读到新值")
    func companionReadsRotatedLocalAPIKey() throws {
        let keychain = InMemoryKeychain()
        let store = makeLocalAPIKeyStore(keychain: keychain)
        let config = CompanionConfiguration(localAPIKeyStore: store, defaults: try makeDefaults())
        let old = config.token

        store.rotateAPIKey()

        #expect(config.token != old)
        #expect(try keychain.loadServiceAPIKey(forService: "local_api") == config.token)
    }

    @Test("端口只接受 5051...5060, enabled 使用 UserDefaults 持久化")
    func persistsPortAndEnabled() throws {
        let keychain = InMemoryKeychain()
        let store = makeLocalAPIKeyStore(keychain: keychain)
        let defaults = try makeDefaults()
        let config = CompanionConfiguration(localAPIKeyStore: store, defaults: defaults)

        #expect(config.port == 5051)
        #expect(config.isEnabled == false)

        config.updateBoundPort(5058)
        config.isEnabled = true

        let restored = CompanionConfiguration(localAPIKeyStore: store, defaults: defaults)
        #expect(restored.port == 5058)
        #expect(restored.isEnabled == true)

        restored.updateBoundPort(6000)
        #expect(restored.port == 5058)
    }
}
