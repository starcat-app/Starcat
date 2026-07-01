//
//  CompanionConfigurationTests.swift
//  StarcatTests
//
//  验证 Chrome Companion 配置的 token/port/enabled 持久化边界。
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

    @Test("首次初始化生成并持久化 Companion token")
    func generatesAndStoresToken() throws {
        let keychain = InMemoryKeychain()
        let config = CompanionConfiguration(secureStore: keychain, defaults: try makeDefaults())

        #expect(!config.token.isEmpty)
        #expect(try keychain.loadCompanionToken() == config.token)
    }

    @Test("已有 token 时复用, 不重新生成")
    func reusesStoredToken() throws {
        let keychain = InMemoryKeychain()
        try keychain.storeCompanionToken("stored-token")

        let config = CompanionConfiguration(secureStore: keychain, defaults: try makeDefaults())

        #expect(config.token == "stored-token")
    }

    @Test("resetToken 生成新 token 并写回 secure store")
    func resetTokenPersists() throws {
        let keychain = InMemoryKeychain()
        let config = CompanionConfiguration(secureStore: keychain, defaults: try makeDefaults())
        let old = config.token

        config.resetToken()

        #expect(config.token != old)
        #expect(try keychain.loadCompanionToken() == config.token)
    }

    @Test("端口只接受 5051...5060, enabled 使用 UserDefaults 持久化")
    func persistsPortAndEnabled() throws {
        let keychain = InMemoryKeychain()
        let defaults = try makeDefaults()
        let config = CompanionConfiguration(secureStore: keychain, defaults: defaults)

        #expect(config.port == 5051)
        #expect(config.isEnabled == false)

        config.updateBoundPort(5058)
        config.isEnabled = true

        let restored = CompanionConfiguration(secureStore: keychain, defaults: defaults)
        #expect(restored.port == 5058)
        #expect(restored.isEnabled == true)

        restored.updateBoundPort(6000)
        #expect(restored.port == 5058)
    }
}
