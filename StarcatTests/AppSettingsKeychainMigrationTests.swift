//
//  AppSettingsKeychainMigrationTests.swift
//  StarcatTests
//
//  覆盖 R-01 v1.2 BYOK API Key 持久化从 UserDefaults → Keychain 的迁移路径
//  与读写主流程，对应 `AppSettings.swift` 的 customServiceAPIKey* 接口。
//
//  关键约束：
//  - **必须**用 `InMemoryKeychain` 注入，否则会污染开发者本地真实 credentials.json
//  - 每个测试用 isolated UserDefaults suite，跨测试不共享状态
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("AppSettings/KeychainMigration")
struct AppSettingsKeychainMigrationTests {

    // MARK: - Fixtures

    /// 制造隔离的 UserDefaults + InMemoryKeychain 对，互不污染共享状态。
    private func makePair() -> (UserDefaults, InMemoryKeychain) {
        let suiteName = "test.starcat.appsettings.keychain.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, InMemoryKeychain())
    }

    // MARK: - 迁移路径

    @Test("启动期发现 UserDefaults 旧 dict → 全量迁移进 Keychain + 删 UserDefaults")
    func migrationFromUserDefaultsRunsOnce() throws {
        let (defaults, keychain) = makePair()

        // 模拟「老用户」：UserDefaults 里有 R-01 v1.2 引入时落盘的旧 dict
        let legacyDict = [
            "trending": "sk-old-trending",
            "weekly":   "sk-old-weekly"
        ]
        let json = try JSONEncoder().encode(legacyDict)
        defaults.set(String(decoding: json, as: UTF8.self), forKey: AppSettings.Keys.customServiceAPIKeys)

        // 触发迁移：构造 AppSettings 时 init 应自动搬迁
        let settings = AppSettings(defaults: defaults, keychain: keychain)

        // 1. Keychain 里有 2 条新键
        #expect(try keychain.loadServiceAPIKey(forService: "trending") == "sk-old-trending")
        #expect(try keychain.loadServiceAPIKey(forService: "weekly") == "sk-old-weekly")

        // 2. UserDefaults 旧 key 已被删（迁移完成标志）
        #expect(defaults.object(forKey: AppSettings.Keys.customServiceAPIKeys) == nil)

        // 3. 内存缓存预热：customServiceAPIKey 同步可读
        #expect(settings.customServiceAPIKey(for: .trending) == "sk-old-trending")
        #expect(settings.customServiceAPIKey(for: .weekly) == "sk-old-weekly")
        #expect(settings.customServiceAPIKey(for: .sharing) == nil)
    }

    @Test("迁移幂等：UserDefaults 已被清后第二次 init 不再迁移，仍能读 Keychain")
    func migrationIdempotentAfterDelete() throws {
        let (defaults, keychain) = makePair()

        // 一开始就直接把数据写在 Keychain（模拟「迁移已完成」状态）
        try keychain.storeServiceAPIKey("sk-already-migrated", forService: "sharing")

        // UserDefaults 没旧 dict（迁移已完成）
        #expect(defaults.object(forKey: AppSettings.Keys.customServiceAPIKeys) == nil)

        let settings = AppSettings(defaults: defaults, keychain: keychain)

        // 走 else 分支预热：从 keychain.loadServiceAPIKey 拉 sharing 值进缓存
        #expect(settings.customServiceAPIKey(for: .sharing) == "sk-already-migrated")
        #expect(settings.customServiceAPIKey(for: .trending) == nil)
    }

    @Test("空 UserDefaults dict 不算迁移触发，但旧 key 不会被无理由清掉")
    func migrationSkipsEmptyLegacyDict() throws {
        let (defaults, keychain) = makePair()

        // 写一个空 dict（边界）
        let json = try JSONEncoder().encode([String: String]())
        defaults.set(String(decoding: json, as: UTF8.self), forKey: AppSettings.Keys.customServiceAPIKeys)

        _ = AppSettings(defaults: defaults, keychain: keychain)

        // 空 dict 走 else 分支，不删 UserDefaults 旧 key（保留兼容性）
        // 既不写 Keychain，也不主动清 UserDefaults，让数据状态完全等价
        #expect(try keychain.loadServiceAPIKey(forService: "trending") == nil)
    }

    // MARK: - 主流程读写删

    @Test("setCustomAPIKey 写 Keychain + 内存缓存双更新")
    func setCustomAPIKeyDualWrite() throws {
        let (defaults, keychain) = makePair()
        let settings = AppSettings(defaults: defaults, keychain: keychain)

        settings.setCustomAPIKey("sk-test-trending", for: .trending)

        // Keychain 里有新值
        #expect(try keychain.loadServiceAPIKey(forService: "trending") == "sk-test-trending")
        // 缓存也更新（同步读）
        #expect(settings.customServiceAPIKey(for: .trending) == "sk-test-trending")
    }

    @Test("setCustomAPIKey 同时 trim 前后空白")
    func setCustomAPIKeyTrimsWhitespace() throws {
        let (defaults, keychain) = makePair()
        let settings = AppSettings(defaults: defaults, keychain: keychain)

        settings.setCustomAPIKey("  sk-padded\t\n", for: .weekly)

        // 写入 keychain 的值已 trim
        #expect(try keychain.loadServiceAPIKey(forService: "weekly") == "sk-padded")
        #expect(settings.customServiceAPIKey(for: .weekly) == "sk-padded")
    }

    @Test("setCustomAPIKey 传 nil → 等价 reset（删 keychain + 清缓存）")
    func setCustomAPIKeyNilEquivalentToReset() throws {
        let (defaults, keychain) = makePair()
        let settings = AppSettings(defaults: defaults, keychain: keychain)

        settings.setCustomAPIKey("sk-temp", for: .sharing)
        #expect(try keychain.loadServiceAPIKey(forService: "sharing") == "sk-temp")

        settings.setCustomAPIKey(nil, for: .sharing)
        #expect(try keychain.loadServiceAPIKey(forService: "sharing") == nil)
        #expect(settings.customServiceAPIKey(for: .sharing) == nil)
    }

    @Test("setCustomAPIKey 传空字符串 / 全空白 → 等价 reset")
    func setCustomAPIKeyEmptyOrWhitespaceEquivalentToReset() throws {
        let (defaults, keychain) = makePair()
        let settings = AppSettings(defaults: defaults, keychain: keychain)

        settings.setCustomAPIKey("sk-temp", for: .trending)
        settings.setCustomAPIKey("", for: .trending)
        #expect(try keychain.loadServiceAPIKey(forService: "trending") == nil)

        settings.setCustomAPIKey("sk-temp2", for: .weekly)
        settings.setCustomAPIKey("   \t  ", for: .weekly)
        #expect(try keychain.loadServiceAPIKey(forService: "weekly") == nil)
    }

    @Test("resetCustomAPIKey 删 Keychain + 清缓存")
    func resetCustomAPIKeyClearsBoth() throws {
        let (defaults, keychain) = makePair()
        let settings = AppSettings(defaults: defaults, keychain: keychain)

        settings.setCustomAPIKey("sk-real", for: .trending)
        settings.resetCustomAPIKey(for: .trending)

        #expect(try keychain.loadServiceAPIKey(forService: "trending") == nil)
        #expect(settings.customServiceAPIKey(for: .trending) == nil)
    }

    @Test("customServiceAPIKey 缓存 miss 时回退 keychain（容错路径）")
    func customServiceAPIKeyFallsBackToKeychainOnCacheMiss() throws {
        let (defaults, keychain) = makePair()

        // 先建 settings（迁移完成 / 缓存为空）
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        #expect(settings.customServiceAPIKey(for: .sharing) == nil)

        // 外部直接写 keychain（绕开 settings.setCustomAPIKey），模拟测试期或多进程场景
        try keychain.storeServiceAPIKey("sk-external", forService: "sharing")

        // settings 缓存 miss → 回退 keychain → 命中并填回缓存
        #expect(settings.customServiceAPIKey(for: .sharing) == "sk-external")
        // 第二次直接命中缓存（还是同样值）
        #expect(settings.customServiceAPIKey(for: .sharing) == "sk-external")
    }

    @Test("configuredCustomAPIKeyServiceIDs 反映已配置 service ID 列表")
    func configuredCustomAPIKeyServiceIDsReflectsState() throws {
        let (defaults, keychain) = makePair()
        let settings = AppSettings(defaults: defaults, keychain: keychain)

        // 初始为空
        #expect(settings.configuredCustomAPIKeyServiceIDs.isEmpty)

        settings.setCustomAPIKey("sk-1", for: .trending)
        settings.setCustomAPIKey("sk-2", for: .weekly)
        #expect(Set(settings.configuredCustomAPIKeyServiceIDs) == ["trending", "weekly"])

        settings.resetCustomAPIKey(for: .trending)
        #expect(Set(settings.configuredCustomAPIKeyServiceIDs) == ["weekly"])
    }
}
