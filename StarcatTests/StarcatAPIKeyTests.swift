//
//  StarcatAPIKeyTests.swift
//  StarcatTests
//
//  验证 R-01 v1.2 自建后端 API Key 解析机制（hybrid 模型）。
//
//  对应实现：`Starcat/Core/Network/StarcatAPIKey.swift`
//  对应文档：`docs/详细设计/18-三场景共用架构.md` v1.2 §6.4
//
//  覆盖路径：
//   - StarcatAPIKeyDefaults.productionKeyOrNil：CI 期 Secrets.xcconfig 缺失 → nil
//   - StarcatAPIKeyResolver.resolve：BYOK > production 默认的优先级逻辑
//   - 边界：customAPIKey 空字符串 / 空白字符串 / 仅含 trim 字符
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("StarcatAPIKey")
struct StarcatAPIKeyTests {

    // MARK: - 测试 fixtures

    /// 给每个测试一个独立 UserDefaults suite + 独立 InMemoryKeychain，
    /// 避免污染开发者本地的真实 credentials.json（位于 ~/Library/Application Support/com.starcat.app/）。
    ///
    /// **关键**：默认参数 `keychain: KeychainManager.shared` 会写本地加密文件，所以测试**必须**
    /// 传 InMemoryKeychain。否则跑 setCustomAPIKey 会真的把测试 key 持久化到真实 credentials.json。
    private func makeIsolatedSettings() -> AppSettings {
        let suiteName = "test.starcat.apikey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults, keychain: InMemoryKeychain())
    }

    // MARK: - StarcatAPIKeyDefaults

    @Test("CI 期 Secrets.xcconfig 缺失 → productionKeyOrNil = nil")
    func productionKeyMissingInCI() {
        // CI 环境下 Secrets.xcconfig 不存在 / 字段空字符串 → productionKeyOrNil 应为 nil。
        // 这是「BYOK-only 模式」工作的前提。如果 dong4j 本地 Secrets.xcconfig 填了真实
        // key 后跑测试，本断言会失败——这是预期行为，提示开发者「跑测试前先 stash 掉
        // Secrets.xcconfig，或单独跑」。
        //
        // 决策（2026-06-10）：测试期不强制隔离 Bundle.main.infoDictionary（隔离需要 swizzle
        // 或自建 Bundle.test，复杂度过高）；接受「本地填了 Key 跑测会标红」的成本。
        // CI（GitHub Actions / 公开 fork）保证 Secrets.xcconfig 缺失，测试稳定为 nil。
        #expect(StarcatAPIKeyDefaults.productionKeyOrNil == nil)
    }

    // MARK: - StarcatAPIKeyResolver

    @Test("无 BYOK + 无 production 默认 → resolve 返回 nil（BYOK-only 模式）")
    func resolveAllMissing() {
        let settings = makeIsolatedSettings()
        // 隔离 settings 必然没有 customServiceAPIKey；CI 期 productionKeyOrNil 为 nil
        #expect(StarcatAPIKeyResolver.resolve(for: .trending, settings: settings) == nil)
        #expect(StarcatAPIKeyResolver.resolve(for: .weekly, settings: settings) == nil)
        #expect(StarcatAPIKeyResolver.resolve(for: .sharing, settings: settings) == nil)
    }

    @Test("BYOK 覆盖 production 默认（hybrid 高优先）")
    func resolveBYOKPriority() {
        let settings = makeIsolatedSettings()
        let userKey = "sk-starcat-USER-MANUAL-OVERRIDE-12345"
        settings.setCustomAPIKey(userKey, for: .trending)

        // BYOK 已配置 → resolve 应返回 BYOK 值（无视 production 默认是否存在）
        #expect(StarcatAPIKeyResolver.resolve(for: .trending, settings: settings) == userKey)
    }

    @Test("BYOK 仅对配置的服务生效，其他服务仍走默认（即 nil 在 CI 期）")
    func resolvePerServiceIsolation() {
        let settings = makeIsolatedSettings()
        settings.setCustomAPIKey("sk-starcat-only-trending", for: .trending)

        // .trending 走 BYOK
        #expect(StarcatAPIKeyResolver.resolve(for: .trending, settings: settings) == "sk-starcat-only-trending")
        // .weekly / .sharing 未配置 → nil
        #expect(StarcatAPIKeyResolver.resolve(for: .weekly, settings: settings) == nil)
        #expect(StarcatAPIKeyResolver.resolve(for: .sharing, settings: settings) == nil)
    }

    @Test("BYOK 写空字符串 → 等价 reset，resolve 回退默认")
    func resolveEmptyStringTreatedAsReset() {
        let settings = makeIsolatedSettings()
        settings.setCustomAPIKey("sk-starcat-real", for: .weekly)
        #expect(StarcatAPIKeyResolver.resolve(for: .weekly, settings: settings) == "sk-starcat-real")

        // 空字符串等价 reset（AppSettings.setCustomAPIKey 内部判 isEmpty 删除）
        settings.setCustomAPIKey("", for: .weekly)
        #expect(StarcatAPIKeyResolver.resolve(for: .weekly, settings: settings) == nil)
    }

    @Test("BYOK 仅含空白字符 → trim 后等价 reset")
    func resolveWhitespaceOnlyTreatedAsReset() {
        let settings = makeIsolatedSettings()
        settings.setCustomAPIKey("sk-starcat-real", for: .sharing)
        #expect(StarcatAPIKeyResolver.resolve(for: .sharing, settings: settings) == "sk-starcat-real")

        // 仅空格 / Tab / 换行 → trim 后空字符串 → reset
        settings.setCustomAPIKey("   \t\n  ", for: .sharing)
        #expect(StarcatAPIKeyResolver.resolve(for: .sharing, settings: settings) == nil)
    }

    @Test("BYOK 字符串前后含空白 → trim 后保留 + resolve 返回 trim 后值")
    func resolveTrimsLeadingTrailingWhitespace() {
        let settings = makeIsolatedSettings()
        settings.setCustomAPIKey("  sk-starcat-padded  \n", for: .trending)

        // setCustomAPIKey 内部已 trim；resolve 返回 trim 后的真实值
        #expect(StarcatAPIKeyResolver.resolve(for: .trending, settings: settings) == "sk-starcat-padded")
    }

    @Test("resetCustomAPIKey 后 resolve 回退默认")
    func resolveAfterReset() {
        let settings = makeIsolatedSettings()
        settings.setCustomAPIKey("sk-starcat-temp", for: .trending)
        #expect(StarcatAPIKeyResolver.resolve(for: .trending, settings: settings) == "sk-starcat-temp")

        settings.resetCustomAPIKey(for: .trending)
        #expect(StarcatAPIKeyResolver.resolve(for: .trending, settings: settings) == nil)
    }
}
