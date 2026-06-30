//
//  TelemetryTests.swift
//  StarcatTests
//
//  Anonymous telemetry policy tests.
//
//  These tests cover the privacy gates and schema helpers without importing
//  Aptabase. The production SDK adapter remains a thin integration layer.
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("Telemetry")
struct TelemetryTests {

    private func makeSettings() -> AppSettings {
        let suiteName = "test.starcat.telemetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults, keychain: InMemoryKeychain())
    }

    @Test("默认关闭匿名遥测")
    func telemetryDefaultsToDisabled() {
        let settings = makeSettings()
        #expect(settings.telemetryEnabled == false)
    }

    @Test("用户未开启时不会转发事件")
    func disabledTelemetryDoesNotForwardEvents() {
        let settings = makeSettings()
        let spy = SpyTelemetryClient()
        let manager = TelemetryManager(
            settings: settings,
            client: spy,
            isBackendConfigured: true,
            ignoresTestEnvironmentForUnitTests: true
        )

        manager.track(.appLaunched)

        #expect(spy.events.isEmpty)
    }

    @Test("测试 host 默认强制 no-op")
    func testEnvironmentForcesNoop() {
        let settings = makeSettings()
        settings.telemetryEnabled = true
        let spy = SpyTelemetryClient()
        let manager = TelemetryManager(
            settings: settings,
            client: spy,
            isBackendConfigured: true
        )

        manager.track(.appLaunched)

        #expect(spy.events.isEmpty)
    }

    @Test("开启且后端已配置时转发白名单事件")
    func enabledTelemetryForwardsAllowlistedEvents() {
        let settings = makeSettings()
        settings.telemetryEnabled = true
        let spy = SpyTelemetryClient()
        let manager = TelemetryManager(
            settings: settings,
            client: spy,
            isBackendConfigured: true,
            ignoresTestEnvironmentForUnitTests: true
        )

        manager.track(
            .searchPerformed,
            properties: [.durationBucket: .string("100_299ms")]
        )

        #expect(spy.events == [
            TelemetryEvent(.searchPerformed, properties: [.durationBucket: .string("100_299ms")])
        ])
    }

    @Test("遥测后端失败不会向业务抛错")
    func telemetryBackendFailureDoesNotBubbleToProductFlow() {
        let settings = makeSettings()
        settings.telemetryEnabled = true
        let manager = TelemetryManager(
            settings: settings,
            client: ThrowingTelemetryClient(),
            isBackendConfigured: true,
            ignoresTestEnvironmentForUnitTests: true
        )

        manager.track(.appLaunched)
    }

    @Test("Aptabase App Key 先由 Starcat 校验,避免 SDK 打印原始错误 key")
    func aptabaseAppKeyValidation() {
        #expect(TelemetryConfiguration.isValidAptabaseAppKey("A-INVALID") == false)
        #expect(TelemetryConfiguration.isValidAptabaseAppKey("A-ASIA-project") == false)
        #expect(TelemetryConfiguration.isValidAptabaseAppKey("A-US-project") == true)
        #expect(TelemetryConfiguration.isValidAptabaseAppKey("A-EU-project") == true)
    }

    @Test("数量和耗时只输出粗粒度分桶")
    func telemetryBucketsAreCoarse() {
        #expect(TelemetryBuckets.repoCountBucket(42) == "lt_100")
        #expect(TelemetryBuckets.repoCountBucket(1_500) == "1000_4999")
        #expect(TelemetryBuckets.durationBucket(milliseconds: 80) == "lt_100ms")
        #expect(TelemetryBuckets.durationBucket(milliseconds: 1_200) == "1000_2999ms")
    }
}
