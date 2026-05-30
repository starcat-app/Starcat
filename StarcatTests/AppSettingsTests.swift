//
//  AppSettingsTests.swift
//  StarcatTests
//
//  验证 AppSettings 偏好持久化逻辑。
//  用 UserDefaults(suiteName:) 隔离测试，不污染共享 .standard。
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("AppSettings")
struct AppSettingsTests {

    /// 给每个测试一个独立 suite 名，避免相互污染。
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "test.starcat.appsettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("默认密度为 card")
    func defaultDensity() {
        let defaults = makeIsolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.listDensity == .card)
    }

    @Test("设置后从同 suite 重新读取应保留值")
    func densityPersists() {
        let defaults = makeIsolatedDefaults()

        let s1 = AppSettings(defaults: defaults)
        s1.listDensity = .compact

        let s2 = AppSettings(defaults: defaults)
        #expect(s2.listDensity == .compact)
    }

    @Test("非法 raw value 回退到默认")
    func invalidValueFallsBack() {
        let defaults = makeIsolatedDefaults()
        defaults.set("invalid-density", forKey: "settings.repoListDensity")

        let s = AppSettings(defaults: defaults)
        #expect(s.listDensity == .card)
    }
}
