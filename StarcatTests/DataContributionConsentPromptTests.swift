//
//  DataContributionConsentPromptTests.swift
//  StarcatTests
//
//  验证 1.4.0 数据贡献提示的版本、账户隔离与 UI 冲突门控。
//

import Foundation
import Testing
@testable import Starcat

@Suite("Data Contribution Consent Prompt")
struct DataContributionConsentPromptTests {
    @Test("1.4.0 之前不提示，1.4.0 及以后允许提示")
    func gatesByAppVersion() throws {
        let testDefaults = try makeDefaults()
        defer { clear(testDefaults) }
        let defaults = testDefaults.defaults

        let beforeLaunch = makePreferences(defaults: defaults, version: "1.3.9")
        #expect(!shouldPresent(beforeLaunch))

        let launchVersion = makePreferences(defaults: defaults, version: "1.4.0")
        #expect(shouldPresent(launchVersion))

        let laterVersion = makePreferences(defaults: defaults, version: "1.6.0")
        #expect(shouldPresent(laterVersion))

        let invalidVersion = makePreferences(defaults: defaults, version: "development")
        #expect(!shouldPresent(invalidVersion))
    }

    @Test("登录账户必须与当前数据库一致且不能与其他启动界面冲突")
    func requiresReadyPresentationContext() throws {
        let testDefaults = try makeDefaults()
        defer { clear(testDefaults) }
        let defaults = testDefaults.defaults
        let preferences = makePreferences(defaults: defaults, version: "1.4.0")

        #expect(!shouldPresent(preferences, authenticatedAccountID: nil))
        #expect(!shouldPresent(preferences, databaseAccountID: 99))
        #expect(!shouldPresent(preferences, isOnboardingActive: true))
        #expect(!shouldPresent(preferences, isAuthSheetPresented: true))
        #expect(!shouldPresent(preferences, isContributionEnabled: true))
    }

    @Test("提示完成标记按 GitHub 账户隔离且每个账户只提示一次")
    func recordsHandledStatePerAccount() throws {
        let testDefaults = try makeDefaults()
        defer { clear(testDefaults) }
        let defaults = testDefaults.defaults
        let preferences = makePreferences(defaults: defaults, version: "1.4.0")

        #expect(shouldPresent(preferences, authenticatedAccountID: 42, databaseAccountID: 42))
        preferences.markHandled(accountID: 42)

        #expect(preferences.hasHandled(accountID: 42))
        #expect(!shouldPresent(preferences, authenticatedAccountID: 42, databaseAccountID: 42))
        #expect(shouldPresent(preferences, authenticatedAccountID: 99, databaseAccountID: 99))
    }

    @Test("开源审核入口指向 Starcat 官方仓库")
    func linksToOfficialSourceRepository() {
        #expect(
            DataContributionConsentSheet.sourceURL.absoluteString
                == "https://github.com/starcat-app/Starcat"
        )
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "DataContributionConsentPromptTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private func clear(_ testDefaults: (defaults: UserDefaults, suiteName: String)) {
        testDefaults.defaults.removePersistentDomain(forName: testDefaults.suiteName)
    }

    private func makePreferences(
        defaults: UserDefaults,
        version: String
    ) -> DataContributionConsentPromptPreferences {
        DataContributionConsentPromptPreferences(
            defaults: defaults,
            appVersionProvider: { version }
        )
    }

    private func shouldPresent(
        _ preferences: DataContributionConsentPromptPreferences,
        authenticatedAccountID: Int64? = 42,
        databaseAccountID: Int64? = 42,
        isOnboardingActive: Bool = false,
        isAuthSheetPresented: Bool = false,
        isContributionEnabled: Bool = false
    ) -> Bool {
        preferences.shouldPresent(
            authenticatedAccountID: authenticatedAccountID,
            databaseAccountID: databaseAccountID,
            isOnboardingActive: isOnboardingActive,
            isAuthSheetPresented: isAuthSheetPresented,
            isContributionEnabled: isContributionEnabled
        )
    }
}
