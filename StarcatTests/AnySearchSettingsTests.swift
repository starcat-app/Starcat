//
//  AnySearchSettingsTests.swift
//  StarcatTests
//
//  验证 AnySearch 非敏感开关走 UserDefaults，API Key 走 KeychainManaging。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AnySearch Settings")
@MainActor
struct AnySearchSettingsTests {
    @Test("开关持久化且 API Key 不写入 UserDefaults")
    func persistenceAndKeychain() throws {
        let suite = "AnySearchSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)

        settings.anySearchEnabled = true
        settings.searchIncludeWebInAll = true
        settings.aiExternalContextEnabled = true
        settings.setAnySearchAPIKey(" secret ")

        #expect(defaults.bool(forKey: AppSettings.Keys.anySearchEnabled))
        #expect(defaults.bool(forKey: AppSettings.Keys.searchIncludeWebInAll))
        #expect(settings.anySearchAPIKey() == "secret")
        #expect(defaults.dictionaryRepresentation().values.allSatisfy { "\($0)" != "secret" })
    }
}
