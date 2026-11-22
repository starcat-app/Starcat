//
//  KeychainManagerTests.swift
//  StarcatTests
//
//  Keychain 写读删基本流程。
//
//  注意：单测会读写真实 Keychain（macOS 钥匙串）；
//  这里采用唯一 account 名，结束后清理，避免污染共享 service。
//

import Testing
import Foundation
import KeychainAccess
@testable import Starcat

// .serialized：所有测试共享 KeychainManager.shared 单例与同一份凭据文件，
// 且 P2-3 起 github token 有进程内缓存状态，并行交错会产生假失败。
@Suite("KeychainManager", .serialized)
struct KeychainManagerTests {

    /// 直接持有底层 Keychain 句柄做清理。
    private let testKeychain = Keychain(service: AppConstants.bundleIdentifier)

    @Test("ping 自检：写读一致")
    func selfCheckSucceeds() throws {
        // ping 内部会自行写入并清理 canary，不留垃圾
        #expect(throws: Never.self) {
            try KeychainManager.shared.ping()
        }
    }

    @Test("GitHub token 写读删")
    func githubTokenRoundTrip() throws {
        let token = "ghp_test_\(UUID().uuidString)"
        let mgr = KeychainManager.shared

        try mgr.storeGithubToken(token)
        let readBack = try mgr.loadGithubToken()
        #expect(readBack == token)

        try mgr.deleteGithubToken()
        let afterDelete = try mgr.loadGithubToken()
        #expect(afterDelete == nil)
    }

    @Test("AI key 写读删")
    func aiKeyRoundTrip() throws {
        let key = "sk-test-\(UUID().uuidString)"
        let mgr = KeychainManager.shared

        try mgr.storeAIKey(key)
        let readBack = try mgr.loadAIKey()
        #expect(readBack == key)

        try mgr.deleteAIKey()
        let afterDelete = try mgr.loadAIKey()
        #expect(afterDelete == nil)
    }

    @Test("AI provider key 按 profile 隔离")
    func aiProviderKeyRoundTrip() throws {
        let mgr = KeychainManager.shared
        let profileA = "test-provider-a-\(UUID().uuidString)"
        let profileB = "test-provider-b-\(UUID().uuidString)"
        defer {
            try? mgr.deleteAIKey(forProvider: profileA)
            try? mgr.deleteAIKey(forProvider: profileB)
        }

        try mgr.storeAIKey("key-a", forProvider: profileA)
        try mgr.storeAIKey("key-b", forProvider: profileB)

        #expect(try mgr.loadAIKey(forProvider: profileA) == "key-a")
        #expect(try mgr.loadAIKey(forProvider: profileB) == "key-b")

        try mgr.deleteAIKey(forProvider: profileA)
        #expect(try mgr.loadAIKey(forProvider: profileA) == nil)
        #expect(try mgr.loadAIKey(forProvider: profileB) == "key-b")
    }

    // MARK: - R-01 Service API Key（trending / weekly / sharing）

    @Test("Service API key 按 serviceID 隔离 + 写读删")
    func serviceAPIKeyRoundTrip() throws {
        let mgr = KeychainManager.shared
        // UUID 后缀防与 production 真实 service ID（trending/weekly/sharing）冲突
        let svcA = "test-svc-a-\(UUID().uuidString)"
        let svcB = "test-svc-b-\(UUID().uuidString)"
        defer {
            try? mgr.deleteServiceAPIKey(forService: svcA)
            try? mgr.deleteServiceAPIKey(forService: svcB)
        }

        // 写不同 key
        try mgr.storeServiceAPIKey("sk-svcA-key", forService: svcA)
        try mgr.storeServiceAPIKey("sk-svcB-key", forService: svcB)

        // 各自隔离读
        #expect(try mgr.loadServiceAPIKey(forService: svcA) == "sk-svcA-key")
        #expect(try mgr.loadServiceAPIKey(forService: svcB) == "sk-svcB-key")

        // 删 A 不影响 B
        try mgr.deleteServiceAPIKey(forService: svcA)
        #expect(try mgr.loadServiceAPIKey(forService: svcA) == nil)
        #expect(try mgr.loadServiceAPIKey(forService: svcB) == "sk-svcB-key")
    }

    @Test("Service API key 命名空间与 AI key 解耦（同 ID 互不影响）")
    func serviceAPIKeyNamespaceIsolatedFromAIKey() throws {
        let mgr = KeychainManager.shared
        let sharedID = "ambiguous-id-\(UUID().uuidString)"
        defer {
            try? mgr.deleteServiceAPIKey(forService: sharedID)
            try? mgr.deleteAIKey(forProvider: sharedID)
        }

        // 同一字符串 ID 同时往 service / AI 命名空间存
        try mgr.storeServiceAPIKey("svc-value", forService: sharedID)
        try mgr.storeAIKey("ai-value", forProvider: sharedID)

        // 各自命名空间读到各自值，互不串
        #expect(try mgr.loadServiceAPIKey(forService: sharedID) == "svc-value")
        #expect(try mgr.loadAIKey(forProvider: sharedID) == "ai-value")
    }

    // MARK: - P2-3 github token 进程内缓存

    @Test("换号覆盖：store 新 token 后立即读到新值（写穿失效）")
    func githubTokenSwitchOverwritesCache() throws {
        let mgr = KeychainManager.shared
        let tokenA = "ghp_switch_a_\(UUID().uuidString)"
        let tokenB = "ghp_switch_b_\(UUID().uuidString)"
        defer { try? mgr.deleteGithubToken() }

        try mgr.storeGithubToken(tokenA)
        #expect(try mgr.loadGithubToken() == tokenA)

        // 换号语义：写 B 后缓存必须立刻指向 B，绝不能返回 A
        try mgr.storeGithubToken(tokenB)
        #expect(try mgr.loadGithubToken() == tokenB)
    }

    @Test("登出失效：delete 后 load 返回 nil")
    func deleteGithubTokenInvalidatesCache() throws {
        let mgr = KeychainManager.shared
        try mgr.storeGithubToken("ghp_del_\(UUID().uuidString)")
        #expect(try mgr.loadGithubToken() != nil)  // 预热缓存

        try mgr.deleteGithubToken()
        #expect(try mgr.loadGithubToken() == nil)
    }

    #if DEBUG
    @Test("缓存命中：预热后重复读不再落文件，删除后同样不落文件")
    func githubTokenReadsHitProcessCache() throws {
        let mgr = KeychainManager.shared
        let token = "ghp_cache_\(UUID().uuidString)"
        defer { try? mgr.deleteGithubToken() }

        try mgr.storeGithubToken(token)
        _ = try mgr.loadGithubToken()  // 预热：这一步是唯一允许的文件读

        // 用 delta 断言：App 启动预热 / 其它组件可能已产生历史计数，绝对值不稳定
        let missesBefore = mgr.debugGithubTokenFileReadCount
        #expect(try mgr.loadGithubToken() == token)
        #expect(try mgr.loadGithubToken() == token)
        #expect(mgr.debugGithubTokenFileReadCount == missesBefore,
                "预热后两次 load 都应命中进程内缓存，文件读 0 次")

        // 删除后缓存失效且缓存为"确认缺失"态：load 返回 nil，同样不需要读文件
        try mgr.deleteGithubToken()
        #expect(try mgr.loadGithubToken() == nil)
        #expect(mgr.debugGithubTokenFileReadCount == missesBefore)
    }
    #endif

    @Test("恢复出厂：deleteAllCredentials 后 github token 缓存失效")
    func deleteAllCredentialsInvalidatesGithubTokenCache() throws {
        let mgr = KeychainManager.shared
        // deleteAllCredentials 是 destructive 操作（删整个凭据文件）。测试宿主可能
        // 存有此前运行留下的其它凭据，先备份字节、结束后原样恢复，不永久抹掉现场。
        let fileURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("credentials.json")  // KeychainManager 私有常量的文件名
        let backup = try? Data(contentsOf: fileURL)
        defer {
            if let backup {
                try? backup.write(to: fileURL, options: [.atomic])
            } else {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        try mgr.storeGithubToken("ghp_all_del_\(UUID().uuidString)")
        #expect(try mgr.loadGithubToken() != nil)  // 预热缓存

        try mgr.deleteAllCredentials()
        #expect(try mgr.loadGithubToken() == nil)
    }
}
