//
//  SwitchUserDatabaseTests.swift
//  StarcatTests
//
//  2026-06-12 多账号 DB 隔离单元测试。
//
//  覆盖范围（与 plan §7 对齐）：
//  - `InMemoryDatabaseManager.reopen`：切换到不同 userId 后旧库数据不可见
//  - 真磁盘 `DatabaseManager(userId:basePathOverride:)`：跨切换持久化（A→B→A 数据还在）
//  - `userId == nil` 走 `users/_anonymous` 路径，Migration 跑通
//  - `_meta.json` 元信息文件写到 user 目录
//  - `AuthSession` 4 个钩子点（signIn 路径 / restore 路径 / signOut / invalidateSession）
//    都触发 `onUserSessionChanged` 且参数符合预期
//
//  设计取舍：
//  - 不打网络（用 MockGitHubAPIClient）
//  - 真磁盘测试用 tmpDir，测试结束清理；不污染开发者本地 Application Support
//  - 测试方法标 @MainActor —— DatabaseManager.reopen 是 @MainActor func
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@Suite("Multi-account DB switch")
struct SwitchUserDatabaseTests {

    // MARK: - In-memory: 切换后旧数据不可见

    @Test("InMemoryDatabaseManager: reopen 后旧库数据不可见")
    @MainActor
    func inMemorySwitchEmptyAfterReopen() async throws {
        let db = try InMemoryDatabaseManager(userId: 12345)
        #expect(db.currentUserId == 12345)

        let repo = Self.makeRepoRecord(id: 100, name: "starcat")
        try await db.writer.write { conn in
            var repoCopy = repo
            try repoCopy.save(conn)
        }
        let countBefore = try await db.writer.read { conn in
            try Repo.fetchCount(conn)
        }
        #expect(countBefore == 1)

        try await db.reopen(userId: 67890)
        #expect(db.currentUserId == 67890)

        let countAfter = try await db.writer.read { conn in
            try Repo.fetchCount(conn)
        }
        #expect(countAfter == 0)
    }

    @Test("InMemoryDatabaseManager: reopen 到相同 userId 是 no-op")
    @MainActor
    func inMemoryReopenSameUserIsNoop() async throws {
        let db = try InMemoryDatabaseManager(userId: 12345)
        let repo = Self.makeRepoRecord(id: 100, name: "starcat")
        try await db.writer.write { conn in
            var repoCopy = repo
            try repoCopy.save(conn)
        }
        try await db.reopen(userId: 12345)
        let count = try await db.writer.read { conn in
            try Repo.fetchCount(conn)
        }
        #expect(count == 1, "same userId reopen 不应清掉数据")
    }

    // MARK: - 真磁盘：跨切换持久化

    @Test("DatabaseManager: A→B→A 切回数据仍在（持久化语义）")
    @MainActor
    func diskPersistsAcrossSwitch() async throws {
        let tmpRoot = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let db = try DatabaseManager(userId: 12345, basePathOverride: tmpRoot)
        #expect(db.currentUserId == 12345)
        #expect(db.databasePath?.contains("/users/12345/") == true)

        let repoA = Self.makeRepoRecord(id: 100, name: "a_repo")
        try await db.writer.write { conn in
            var repoCopy = repoA
            try repoCopy.save(conn)
        }

        try await db.reopen(userId: 67890)
        #expect(db.currentUserId == 67890)
        #expect(db.databasePath?.contains("/users/67890/") == true)

        let countOnB = try await db.writer.read { conn in
            try Repo.fetchCount(conn)
        }
        #expect(countOnB == 0, "切到 B 后不应看到 A 的数据")

        let repoB = Self.makeRepoRecord(id: 200, name: "b_repo")
        try await db.writer.write { conn in
            var repoCopy = repoB
            try repoCopy.save(conn)
        }

        try await db.reopen(userId: 12345)
        let aRepos = try await db.writer.read { conn in
            try Repo.fetchAll(conn)
        }
        #expect(aRepos.count == 1)
        #expect(aRepos.first?.id == 100)
    }

    @Test("DatabaseManager: libraryState/notes/status 按账号隔离且切回可恢复")
    @MainActor
    func libraryStateAndPrivateDataAreIsolatedPerUser() async throws {
        let tmpRoot = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let db = try DatabaseManager(userId: 12345, basePathOverride: tmpRoot)
        let repoA = Self.makeRepoRecord(id: 100, name: "shared_repo")
        try await db.writer.write { conn in
            var copy = repoA
            try copy.save(conn)
        }
        var noteRepo = GRDBRepoNoteRepository(database: db)
        try await noteRepo.updateLibraryState(repoId: 100, state: .inLibrary)
        try await noteRepo.updateContent(repoId: 100, content: "A 的笔记")
        try await noteRepo.updateStatus(repoId: 100, status: .using)
        let noteA = try #require(try await noteRepo.find(repoId: 100))
        let aLibraryUpdatedAt = try #require(noteA.libraryUpdatedAt)

        try await db.reopen(userId: 67890)
        noteRepo = GRDBRepoNoteRepository(database: db)
        let repoB = Self.makeRepoRecord(id: 100, name: "shared_repo")
        try await db.writer.write { conn in
            var copy = repoB
            try copy.save(conn)
        }
        #expect(try await noteRepo.fetchLibraryState(repoId: 100) == .outsideLibrary)
        try await noteRepo.updateContent(repoId: 100, content: "B 的笔记")
        try await noteRepo.updateStatus(repoId: 100, status: .read)
        let noteB = try #require(try await noteRepo.find(repoId: 100))
        #expect(noteB.libraryState == LibraryState.outsideLibrary.rawValue)
        #expect(noteB.libraryUpdatedAt == nil)

        try await db.reopen(userId: nil)
        noteRepo = GRDBRepoNoteRepository(database: db)
        #expect(try await noteRepo.find(repoId: 100) == nil)
        #expect(try await noteRepo.fetchLibraryState(repoId: 100) == .outsideLibrary)

        try await db.reopen(userId: 12345)
        noteRepo = GRDBRepoNoteRepository(database: db)
        let restoredA = try #require(try await noteRepo.find(repoId: 100))
        #expect(restoredA.content == "A 的笔记")
        #expect(restoredA.status == RepoStatus.using.rawValue)
        #expect(restoredA.libraryState == LibraryState.inLibrary.rawValue)
        #expect(restoredA.libraryUpdatedAt == aLibraryUpdatedAt)

        try await db.reopen(userId: 67890)
        noteRepo = GRDBRepoNoteRepository(database: db)
        let restoredB = try #require(try await noteRepo.find(repoId: 100))
        #expect(restoredB.content == "B 的笔记")
        #expect(restoredB.status == RepoStatus.read.rawValue)
        #expect(restoredB.libraryState == LibraryState.outsideLibrary.rawValue)
        #expect(restoredB.libraryUpdatedAt == nil)
    }

    // MARK: - Anonymous fallback

    @Test("DatabaseManager: userId=nil 走 _anonymous 目录，Migration 跑通可读写")
    @MainActor
    func anonymousFallback() async throws {
        let tmpRoot = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let db = try DatabaseManager(userId: nil, basePathOverride: tmpRoot)
        #expect(db.currentUserId == nil)
        #expect(db.databasePath?.contains("/users/_anonymous/") == true)

        let repo = Self.makeRepoRecord(id: 999, name: "anon")
        try await db.writer.write { conn in
            var repoCopy = repo
            try repoCopy.save(conn)
        }
        let count = try await db.writer.read { conn in
            try Repo.fetchCount(conn)
        }
        #expect(count == 1)
    }

    @Test("DatabaseManager: 登录用户目录下应有 _meta.json")
    @MainActor
    func writesUserMetaFile() async throws {
        let tmpRoot = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        _ = try DatabaseManager(userId: 12345, basePathOverride: tmpRoot)
        let metaURL = tmpRoot
            .appendingPathComponent(AppConstants.usersDirectoryName)
            .appendingPathComponent("12345")
            .appendingPathComponent(AppConstants.userMetaFileName)
        #expect(FileManager.default.fileExists(atPath: metaURL.path))
    }

    @Test("DatabaseManager: anonymous 目录不写 _meta.json（避免噪音）")
    @MainActor
    func anonymousDoesNotWriteMeta() async throws {
        let tmpRoot = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        _ = try DatabaseManager(userId: nil, basePathOverride: tmpRoot)
        let metaURL = tmpRoot
            .appendingPathComponent(AppConstants.usersDirectoryName)
            .appendingPathComponent(AppConstants.anonymousUserDirectoryName)
            .appendingPathComponent(AppConstants.userMetaFileName)
        #expect(!FileManager.default.fileExists(atPath: metaURL.path))
    }

    // MARK: - AuthSession 钩子点

    @Test("AuthSession 缓存恢复先切账户数据库再发布登录态")
    @MainActor
    func cachedSessionSwitchesDatabaseBeforeAuthentication() async {
        let session = Self.makeAuthSession()
        let user = Self.makeMockUser(id: 12345)
        var stateSeenWhileSwitching: AuthState?

        session.onUserSessionChanged = { userID in
            #expect(userID == user.id)
            stateSeenWhileSwitching = session.state
        }

        await session.activateCachedSession(user)

        #expect(stateSeenWhileSwitching == .unauthenticated)
        #expect(session.state == .authenticated(user: user))
    }

    @Test("AuthSession.signOut → onUserSessionChanged(nil) 被触发")
    @MainActor
    func signOutFiresUserSessionChangedWithNil() async throws {
        let session = Self.makeAuthSession()
        // 直接构造 authenticated 状态，跳过完整 OAuth 流程
        session.state = .authenticated(user: Self.makeMockUser(id: 12345))

        var captured: [Int64?] = []
        session.onUserSessionChanged = { userId in
            captured.append(userId)
        }

        await session.signOut()
        #expect(captured == [nil])
        #expect(session.state == .unauthenticated)
    }

    @Test("AuthSession.invalidateSession → onUserSessionChanged(nil) 被触发")
    @MainActor
    func invalidateSessionFiresUserSessionChangedWithNil() async throws {
        let session = Self.makeAuthSession()
        session.state = .authenticated(user: Self.makeMockUser(id: 12345))

        var captured: [Int64?] = []
        session.onUserSessionChanged = { userId in
            captured.append(userId)
        }

        await session.invalidateSession()
        #expect(captured == [nil])
        #expect(session.state == .unauthenticated)
    }

    // 注：原 plan §7 列出的 `restoreSessionFiresWithUserId` / `restoreSession401FiresWithNil`
    // 两个测试已删除——`AuthSession.restoreSessionIfAvailable()` 在测试 host 内
    // （`TestEnvironment.isRunning == true`）直接 early return，走不到 keychain 读取
    // 也就触发不到 onUserSessionChanged closure。这是项目级 Keychain 弹窗防护，
    // 详见 docs/4-工程进度/踩坑与故障记录/2026-05-30-Keychain-临时绕过方案.md。
    // restore 路径的 hook 通过 code review 验证：见 AuthSession.swift 内 4 处
    // `await onUserSessionChanged?(...)` 调用点。

    // MARK: - Helpers

    @MainActor
    private static func makeAuthSession() -> AuthSession {
        AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: MockGitHubAPIClient(),
            keychain: InMemoryKeychain()
        )
    }

    private static func makeMockUser(id: Int64) -> GitHubUserDTO {
        GitHubUserDTO(
            id: id,
            login: "user\(id)",
            name: nil,
            avatarUrl: nil,
            publicRepos: nil,
            followers: nil,
            following: nil,
            bio: nil,
            company: nil,
            location: nil,
            email: nil,
            blog: nil,
            twitterUsername: nil,
            htmlUrl: nil
        )
    }

    private static func makeRepoRecord(id: Int64, name: String) -> Repo {
        Repo(
            id: id,
            owner: "owner",
            name: name,
            fullName: "owner/\(name)",
            description: nil,
            language: "Swift",
            starsCount: 0,
            forksCount: 0,
            watchersCount: 0,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/owner/\(name)",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    private static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StarcatDBTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
