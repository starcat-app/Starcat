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

        // 图谱缓存同样注入临时根目录；恢复出厂测试绝不能清理开发机真实账户缓存。
        let graphCache = FollowGraphDiskCache(root: root.appendingPathComponent("graphs"))
        for id in [currentUserID, otherUserID] {
            try await graphCache.save(.init(root: .init(id: String(id), login: "fixture", name: nil, avatarURL: nil)))
        }
        let service = AppDataResetService(
            database: database,
            settings: settings,
            databaseBasePathOverride: root,
            standardDefaults: defaults,
            followGraphCache: graphCache
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
        #expect(await graphCache.load(account: String(currentUserID)) == nil)
        #expect(await graphCache.load(account: String(otherUserID)) != nil)
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

    @Test("恢复出厂排空每日推荐写入、取消迟到理由，仅清目标账号文件")
    func resetClearsDailyRecommendationsWithoutLateWrites() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseRoot = root.appendingPathComponent("databases")
        let database = try DatabaseManager(userId: 1, basePathOverride: databaseRoot)
        let batchRoot = root.appendingPathComponent("batches")
        let reasonRoot = root.appendingPathComponent("reasons")
        let disk = DailyRecommendationDiskStore(root: batchRoot)
        var old = DailyRecommendationState()
        old.showsOnLaunch = false
        for id in [Int64(1), 2] { try await disk.save(old, accountID: id, revision: 1) }
        try Data("invalid".utf8).write(to: batchRoot.appendingPathComponent("1.corrupt.json"))
        let store = DailyRecommendationStore(disk: disk, history: RecommendationHistoryRepository(database: database))
        #expect(await store.loadPreferences(accountID: 1, scopeRevision: 1))
        let reasons = DailyRecommendationExplanationStore(root: reasonRoot)
        let saved = recommendation(100)
        for id in [Int64(1), 2] {
            await reasons.prepareBatch(items: [saved], accountID: id, revision: 1, locale: "en", isPro: true) { _ in "Saved" }
        }

        let preparation = DailyRecommendationPreparation()
        var late: CheckedContinuation<String, Never>?
        var generatorFinished = false
        let work = Task {
            await preparation.run(key: "reset", origin: .user) {
                await reasons.prepareBatch(items: [recommendation(200)], accountID: 1, revision: 1,
                                           locale: "en", isPro: true) { _ in
                    defer { generatorFinished = true }
                    return await withCheckedContinuation { late = $0 }
                }
                return !Task.isCancelled
            }
        }
        while late == nil { await Task.yield() }
        let write = Task { await store.setShowsOnLaunch(true) }
        await Task.yield()
        let (defaults, suiteName) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resetter = AppDataResetService(
            database: database, settings: AppSettings(defaults: defaults, keychain: InMemoryKeychain()),
            databaseBasePathOverride: databaseRoot, standardDefaults: defaults,
            followGraphCache: FollowGraphDiskCache(root: root.appendingPathComponent("graphs"))
        )
        try await resetter.resetLocalData(
            for: .init(userID: 1, login: "fixture"),
            prepareAccountReset: {
                await preparation.suspendAndWait()
                #expect(!(await preparation.run(key: "blocked", origin: .background) { true }))
                try await store.clearForFactoryReset(accountID: 1)
                try await reasons.clearForFactoryReset(accountID: 1)
            },
            releaseCurrentSession: {
                // 证明清理屏障先于切库，旧反馈写入不能误投匿名库。
                #expect(database.currentUserId == 1)
                #expect(!FileManager.default.fileExists(atPath: batchRoot.appendingPathComponent("1.json").path))
            }
        )
        await write.value
        #expect(!(await work.value))
        late?.resume(returning: "Too late")
        while !generatorFinished { await Task.yield() }
        let restored = DailyRecommendationExplanationStore(root: reasonRoot)
        await restored.loadSaved(items: [saved, recommendation(200)], accountID: 1, revision: 2, locale: "en", isPro: true)
        #expect(restored.explanations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: reasonRoot.appendingPathComponent("1").path))
        #expect(!FileManager.default.fileExists(atPath: batchRoot.appendingPathComponent("1.corrupt.json").path))
        #expect(try await disk.load(accountID: 1).showsOnLaunch)
        #expect(!(try await disk.load(accountID: 2).showsOnLaunch))
        await restored.loadSaved(items: [saved], accountID: 2, revision: 2, locale: "en", isPro: true)
        #expect(restored.text(for: saved, locale: "en", isPro: true) == "Saved")
        preparation.resume()
        #expect(await preparation.run(key: "after-reset", origin: .background) { true })
    }

    /// 公开资料与实际来源供本地生成桩使用，不调用真实模型。
    private func recommendation(_ id: Int64) -> RepoRecommendationItem {
        RepoRecommendationItem(repoID: id, fullName: "owner/result\(id)", description: "Fixture",
                               language: "Swift", stars: 1, forks: 0, archived: false, score: 1,
                               source: "starcat_trained", reasons: ["costar"],
                               matchedSeeds: [.init(repoID: 9, fullName: "owner/source", description: nil,
                                                    language: "Swift", reasons: ["costar"])])
    }
}
