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

@Suite("KeychainManager")
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
}
