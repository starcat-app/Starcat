//
//  ReadmeTranslationEngineAvailabilityTests.swift
//  StarcatTests
//
//  翻译引擎可用性与默认回落。
//

import Foundation
import Testing
@testable import Starcat

private struct FixedSystemChecker: SystemTranslationAvailabilityChecking {
    let supported: Bool
    func isSupported(target: ReadmeTranslationLanguage) async -> Bool { supported }
}

@Suite("ReadmeTranslationEngineAvailability")
struct ReadmeTranslationEngineAvailabilityTests {

    @MainActor
    @Test("hides system when unsupported and AI when unconfigured")
    func hidesUnavailableEngines() async throws {
        let suiteName = "test.starcat.translation.engine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        let keychain = InMemoryKeychain()

        let none = await ReadmeTranslationEngineAvailability.availableEngines(
            targetLanguage: .simplifiedChinese,
            settings: settings,
            keychain: keychain,
            systemChecker: FixedSystemChecker(supported: false)
        )
        #expect(none.isEmpty)

        let systemOnly = await ReadmeTranslationEngineAvailability.availableEngines(
            targetLanguage: .simplifiedChinese,
            settings: settings,
            keychain: keychain,
            systemChecker: FixedSystemChecker(supported: true)
        )
        #expect(systemOnly == [.system])

        let providerID = settings.aiTranslationTask.providerID
        try keychain.storeAIKey("sk-test", forProvider: providerID)
        let both = await ReadmeTranslationEngineAvailability.availableEngines(
            targetLanguage: .simplifiedChinese,
            settings: settings,
            keychain: keychain,
            systemChecker: FixedSystemChecker(supported: true)
        )
        #expect(both == [.system, .ai])
    }

    @Test("resolvedDefault falls back to first available")
    func resolvedDefaultFallsBack() {
        #expect(
            ReadmeTranslationEngineAvailability.resolvedDefault(
                current: .ai,
                available: [.system, .ai]
            ) == .ai
        )
        #expect(
            ReadmeTranslationEngineAvailability.resolvedDefault(
                current: .ai,
                available: [.system]
            ) == .system
        )
        #expect(
            ReadmeTranslationEngineAvailability.resolvedDefault(
                current: .system,
                available: []
            ) == .system
        )
    }
}
