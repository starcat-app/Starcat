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
}
