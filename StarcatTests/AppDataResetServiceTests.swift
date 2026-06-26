//
//  AppDataResetServiceTests.swift
//  StarcatTests
//
//  验证 Storage 页“清空所有数据”的服务层删除边界。
//  测试全部使用临时数据库根目录和内存 Keychain，避免触碰开发机真实 Starcat 数据。
//

import Foundation
import Testing
@testable import Starcat

@MainActor
@Suite("AppDataResetService")
struct AppDataResetServiceTests {

    /// 每个测试独立 UserDefaults suite，避免恢复出厂测试污染其它设置用例。
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suiteName = "test.starcat.reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    /// 创建独立临时目录作为 DatabaseManager.basePathOverride。
    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StarcatResetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("本机恢复出厂: 只删除目标用户本地 DB 并重置配置")
    func resetLocalDataDeletesOnlyTargetUserDatabaseAndSettings() async throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryRoot()
        defer { try? fileManager.removeItem(at: root) }

        let currentUserID: Int64 = 12345
        let otherUserID: Int64 = 67890
        let database = try DatabaseManager(userId: currentUserID, basePathOverride: root)
        let currentDatabaseURL = try DatabaseManager.databaseFileURL(userId: currentUserID, basePathOverride: root)
        let currentUserDirectory = currentDatabaseURL.deletingLastPathComponent()
        try Data("target sidecar".utf8).write(
            to: currentUserDirectory.appendingPathComponent("sidecar.txt")
        )

        let otherDatabaseURL = try DatabaseManager.databaseFileURL(userId: otherUserID, basePathOverride: root)
        let otherUserDirectory = otherDatabaseURL.deletingLastPathComponent()
        try Data("keep other user".utf8).write(to: otherDatabaseURL)

        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("zh-Hans", forKey: "AppLocaleOverride")
        defaults.set("profile-cache", forKey: "userprofile.snapshot.dong4j")
        defaults.set("frame", forKey: MainWindowFrameDefaults.defaultsKey)

        let keychain = InMemoryKeychain()
        let settings = AppSettings(defaults: defaults, keychain: keychain)
        settings.appearanceMode = .light
        settings.mcpServiceEnabled = true
        settings.setCustomAPIKey("service-key", for: .wiki)
        try keychain.storeGithubToken("github-token")
        try keychain.storeAIKey("ai-key")

        let service = AppDataResetService(
            database: database,
            settings: settings,
            databaseBasePathOverride: root,
            standardDefaults: defaults
        )
        var didReleaseSession = false
        var didClearGeneratedCaches = false

        try await service.resetLocalData(
            for: AppDataResetTarget(userID: currentUserID, login: "dong4j"),
            releaseCurrentSession: {
                didReleaseSession = true
            },
            clearGeneratedCaches: {
                didClearGeneratedCaches = true
            }
        )

        #expect(didReleaseSession)
        #expect(didClearGeneratedCaches)
        #expect(database.currentUserId == nil)
        #expect(fileManager.fileExists(atPath: currentUserDirectory.path) == false)
        #expect(fileManager.fileExists(atPath: otherUserDirectory.path) == true)
        #expect(settings.appearanceMode == .dark)
        #expect(settings.mcpServiceEnabled == false)
        #expect(settings.customServiceAPIKey(for: .wiki) == nil)
        #expect(keychain.snapshot.isEmpty)
        #expect(defaults.object(forKey: "AppLocaleOverride") == nil)
        #expect(defaults.object(forKey: "userprofile.snapshot.dong4j") == nil)
        #expect(defaults.object(forKey: MainWindowFrameDefaults.defaultsKey) == nil)
    }
}
