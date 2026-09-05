//
//  RepositorySpotlightServiceTests.swift
//  StarcatTests
//
//  验证 Spotlight 明确授权、private repo / 笔记收录与删除边界。
//

import CoreSpotlight
import Foundation
import GRDB
import Testing
@testable import Starcat

@MainActor
@Suite("Repository Spotlight")
struct RepositorySpotlightServiceTests {
    @Test("Spotlight 默认关闭，明确开启后持久化")
    func preferenceRequiresExplicitOptInAndPersists() {
        let suiteName = "test.starcat.spotlight.preference.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let initial = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        #expect(initial.spotlightSearchEnabled == false)

        initial.spotlightSearchEnabled = true

        let restored = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        #expect(restored.spotlightSearchEnabled == true)
    }

    @Test("默认关闭时不索引，并清理已有 Spotlight 条目")
    func disabledPreferenceRemovesExistingIndex() async throws {
        let database = try InMemoryDatabaseManager()
        let settings = makeSettings(enabled: false)
        let index = RecordingRepositorySpotlightIndex()
        let indexState = makeIndexState()
        defer { indexState.cleanup() }
        let service = RepositorySpotlightService(
            database: database,
            settings: settings,
            index: index,
            indexState: indexState.state
        )

        await service.rebuild()

        #expect(await index.removeAllCallCount == 1)
        #expect(await index.replacement.isEmpty)
    }

    @Test("明确开启后索引 private repo 和用户笔记，但排除 unstarred 与 unavailable")
    func enabledPreferenceIndexesPrivateRepositoryAndNote() async throws {
        let database = try InMemoryDatabaseManager()
        try await insertRepository(
            database: database,
            id: 88,
            name: "secret",
            isPrivate: true,
            isStarred: true,
            accessState: .accessible
        )
        try await insertRepository(
            database: database,
            id: 89,
            name: "unstarred",
            isPrivate: false,
            isStarred: false,
            accessState: .accessible
        )
        try await insertRepository(
            database: database,
            id: 90,
            name: "unavailable",
            isPrivate: false,
            isStarred: true,
            accessState: .unavailable
        )
        try await GRDBRepoNoteRepository(database: database).updateContent(
            repoId: 88,
            content: "只保存在本机的用户笔记",
            isAIGenerated: false
        )

        let settings = makeSettings(enabled: true)
        let index = RecordingRepositorySpotlightIndex()
        let indexState = makeIndexState()
        defer { indexState.cleanup() }
        let service = RepositorySpotlightService(
            database: database,
            settings: settings,
            index: index,
            indexState: indexState.state
        )

        await service.rebuild()

        let indexed = await index.replacement
        let entity = try #require(indexed.first)
        #expect(indexed.count == 1)
        #expect(entity.repositoryID == "88")
        #expect(entity.note == "只保存在本机的用户笔记")
        #expect(entity.attributeSet.textContent?.contains("只保存在本机的用户笔记") == true)
        #expect(entity.attributeSet.keywords?.contains("private-org/secret") == true)
    }

    @Test("内容未变化时即使经过单项刷新，后续全量重建仍跳过 Core Spotlight 写入")
    func unchangedContentSkipsSecondReplacement() async throws {
        let database = try InMemoryDatabaseManager()
        try await insertRepository(
            database: database,
            id: 88,
            name: "stable",
            isPrivate: false,
            isStarred: true,
            accessState: .accessible
        )
        let settings = makeSettings(enabled: true)
        let index = RecordingRepositorySpotlightIndex()
        let indexState = makeIndexState()
        defer { indexState.cleanup() }
        let service = RepositorySpotlightService(
            database: database,
            settings: settings,
            index: index,
            indexState: indexState.state
        )

        await service.rebuild()
        await service.refresh(repositoryID: 88)
        await service.rebuild()

        #expect(await index.replacementCallCount == 1)
        #expect(await index.upserted.count == 1)
    }

    @Test("仓库内容变化后全量重建不会误用旧指纹")
    func changedContentReplacesIndexAgain() async throws {
        let database = try InMemoryDatabaseManager()
        try await insertRepository(
            database: database,
            id: 88,
            name: "before",
            isPrivate: false,
            isStarred: true,
            accessState: .accessible
        )
        let settings = makeSettings(enabled: true)
        let index = RecordingRepositorySpotlightIndex()
        let indexState = makeIndexState()
        defer { indexState.cleanup() }
        let service = RepositorySpotlightService(
            database: database,
            settings: settings,
            index: index,
            indexState: indexState.state
        )

        await service.rebuild()
        try await database.writer.write { db in
            try db.execute(sql: "UPDATE repos SET description = ? WHERE id = ?", arguments: ["changed", 88])
        }
        await service.rebuild()

        #expect(await index.replacementCallCount == 2)
    }

    @Test("冷启动与随后重复校验同一账号时都保留已有 Spotlight 索引")
    func coldLaunchSameAccountPreservesExistingIndex() async throws {
        let database = try InMemoryDatabaseManager()
        let settings = makeSettings(enabled: true)
        let index = RecordingRepositorySpotlightIndex()
        let indexState = makeIndexState()
        defer { indexState.cleanup() }
        indexState.state.record(accountID: 42, fingerprint: "existing")
        let service = RepositorySpotlightService(
            database: database,
            settings: settings,
            index: index,
            indexState: indexState.state
        )

        await service.prepareForAccountChange(to: 42)
        try await database.reopen(userId: 42)
        await service.prepareForAccountChange(to: 42)

        #expect(await index.removeAllCallCount == 0)
        #expect(indexState.state.matches(accountID: 42, fingerprint: "existing"))
    }

    @Test("冷启动恢复不同账号时先清空 Spotlight 索引与旧指纹")
    func coldLaunchDifferentAccountRemovesExistingIndex() async throws {
        let database = try InMemoryDatabaseManager(userId: 42)
        let settings = makeSettings(enabled: true)
        let index = RecordingRepositorySpotlightIndex()
        let indexState = makeIndexState()
        defer { indexState.cleanup() }
        indexState.state.record(accountID: 42, fingerprint: "existing")
        let service = RepositorySpotlightService(
            database: database,
            settings: settings,
            index: index,
            indexState: indexState.state
        )

        await service.prepareForAccountChange(to: 7)

        #expect(await index.removeAllCallCount == 1)
        #expect(!indexState.state.matches(accountID: 42, fingerprint: "existing"))
    }

    @Test("仓库退出索引条件后，单项刷新删除稳定 ID")
    func refreshRemovesRepositoryThatIsNoLongerEligible() async throws {
        let database = try InMemoryDatabaseManager()
        try await insertRepository(
            database: database,
            id: 88,
            name: "secret",
            isPrivate: true,
            isStarred: false,
            accessState: .accessible
        )
        let settings = makeSettings(enabled: true)
        let index = RecordingRepositorySpotlightIndex()
        let indexState = makeIndexState()
        defer { indexState.cleanup() }
        let service = RepositorySpotlightService(
            database: database,
            settings: settings,
            index: index,
            indexState: indexState.state
        )

        await service.refresh(repositoryID: 88)

        #expect(await index.removedIdentifiers == ["88"])
    }

    @Test("Spotlight 打开动作发布本机仓库导航请求")
    func openIntentPublishesLocalRepositoryNavigation() throws {
        let dispatcher = MainWindowNavigationDispatcher()
        let intent = OpenRepositorySpotlightIntent()
        intent.target = RepositorySpotlightEntity(
            repositoryID: 88,
            owner: "private-org",
            name: "secret",
            repositoryDescription: nil,
            language: nil,
            topics: [],
            note: "本机笔记"
        )

        try intent.navigate(using: dispatcher)

        let request = try #require(dispatcher.pendingRequest)
        guard case .spotlightRepository(let repositoryID) = request.destination else {
            Issue.record("Spotlight OpenIntent 应发布 local-only repository destination")
            return
        }
        #expect(repositoryID == 88)
    }

    @Test("Core Spotlight user activity 发布本机仓库导航请求")
    func userActivityPublishesLocalRepositoryNavigation() throws {
        let dispatcher = MainWindowNavigationDispatcher()
        let activity = NSUserActivity(activityType: CSSearchableItemActionType)
        activity.addUserInfoEntries(from: [
            CSSearchableItemActivityIdentifier: "RepositorySpotlightEntity/88",
        ])

        let handled = AppDelegate.handleSpotlightUserActivity(activity, using: dispatcher)

        #expect(handled)
        let request = try #require(dispatcher.pendingRequest)
        guard case .spotlightRepository(let repositoryID) = request.destination else {
            Issue.record("Core Spotlight activity 应发布 local-only repository destination")
            return
        }
        #expect(repositoryID == 88)
    }

    private func makeSettings(enabled: Bool) -> AppSettings {
        let suiteName = "test.starcat.spotlight.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults, keychain: InMemoryKeychain())
        settings.spotlightSearchEnabled = enabled
        return settings
    }

    private func makeIndexState() -> (state: RepositorySpotlightIndexState, cleanup: () -> Void) {
        let suiteName = "test.starcat.spotlight.index-state.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (
            RepositorySpotlightIndexState(defaults: defaults),
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }

    private func insertRepository(
        database: any DatabaseManaging,
        id: Int64,
        name: String,
        isPrivate: Bool,
        isStarred: Bool,
        accessState: RepoAccessState
    ) async throws {
        var repository = Repo(
            id: id,
            owner: "private-org",
            name: name,
            fullName: "private-org/\(name)",
            description: "Spotlight integration fixture",
            language: "Swift",
            starsCount: 10,
            forksCount: 1,
            watchersCount: 2,
            topics: "[\"macos\",\"spotlight\"]",
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/private-org/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: isPrivate,
            isFork: false,
            isArchived: false,
            isStarred: isStarred,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
        repository.accessState = accessState
        let snapshot = repository
        try await database.writer.write { db in
            var copy = snapshot
            try copy.save(db)
        }
    }
}
