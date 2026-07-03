//
//  HomeViewModelFilterSortTests.swift
//  StarcatTests
//
//  W4-4 D1/D2：HomeViewModel 排序 + 过滤(Archived/Fork)的端到端验证。
//
//  覆盖路径:
//  - reloadItems 后 items 已按 sortOption 排序
//  - sortOption 改变 → applyView 立即更新 items（不重 fetch）
//  - hideArchived / hideForks 改变 → 立即过滤
//  - 过滤掉选中行 → selectedRepoID 自动清空
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@MainActor
@Suite("HomeViewModel filter+sort (D1+D2)")
struct HomeViewModelFilterSortTests {

    /// 构造一组带 isArchived / isFork / stars / starredAt 控制的 fixture,
    /// 供本 Suite 多个 case 复用。直接走 SQL,避免依赖 GitHubRepoDTO 整套结构。
    private func insertRepo(
        _ db: any DatabaseManaging,
        id: Int64,
        fullName: String,
        stars: Int,
        starredAt: String,
        language: String? = nil,
        isArchived: Bool = false,
        isFork: Bool = false,
        isStarred: Bool = true
    ) async throws {
        try await db.writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO repos (
                    id, owner, name, full_name, description, language,
                    stars_count, forks_count, watchers_count, topics, license,
                    homepage, html_url, clone_url, ssh_url,
                    is_private, is_fork, is_archived, is_starred,
                    pushed_at, created_at, updated_at, starred_at, cached_at
                ) VALUES (
                    ?, 'o', ?, ?, NULL, ?,
                    ?, 0, 0, NULL, NULL,
                    NULL, ?, NULL, NULL,
                    0, ?, ?, ?,
                    NULL, NULL, NULL, ?, '2026-05-30T00:00:00Z'
                )
                """,
                arguments: [
                    id,
                    fullName.split(separator: "/").last.map(String.init) ?? "n",
                    fullName,
                    language,
                    stars,
                    "https://github.com/\(fullName)",
                    isFork,
                    isArchived,
                    isStarred,
                    starredAt
                ]
            )
        }
    }

    private func makeSUT() throws -> (HomeViewModel, any DatabaseManaging, GRDBRepoNoteRepository) {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        let tagRepo = GRDBTagRepository(database: db)
        let rtRepo = GRDBRepoTagRepository(database: db)
        let noteRepo = GRDBRepoNoteRepository(database: db)
        let vm = HomeViewModel(
            repository: repo,
            tagRepository: tagRepo,
            repoTagRepository: rtRepo,
            repoNoteRepository: noteRepo
        )
        return (vm, db, noteRepo)
    }

    private func makeStarList(id: String, name: String, position: Int) -> GitHubStarListRemoteRecord {
        GitHubStarListRemoteRecord(
            id: id,
            name: name,
            description: nil,
            isPrivate: false,
            position: position,
            createdAt: nil,
            updatedAt: nil
        )
    }

    // MARK: - D1 排序

    @Test("D1: reloadItems 后按默认 starredAtDesc 排序")
    func defaultSortAfterReload() async throws {
        let (vm, db, _) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/aaa", stars: 100, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/zzz", stars: 1, starredAt: "2026-05-30T00:00:00Z")

        await vm.reloadItems()

        #expect(vm.items.map(\.id) == [2, 1], "默认 starredAtDesc → 最近 star 在前")
    }

    @Test("D1: sortOption 改成 starsDesc → 通过数据库分页重查当前页")
    func switchSortReorders() async throws {
        let (vm, db, _) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/aaa", stars: 100, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/zzz", stars: 1, starredAt: "2026-05-30T00:00:00Z")
        await vm.reloadItems()
        let revisionAfterReload = vm.itemsRevision

        vm.sortOption = .starsDesc
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.items.map(\.id) == [1, 2], "starsDesc: 100 stars 在前")
        #expect(vm.itemsRevision == revisionAfterReload + 1, "排序切换应发布新的列表快照版本，避免 SwiftUI 对旧 List 做大规模 move diff")
    }

    @Test("DB Paging: 普通 reload 直接读取当前页,不再依赖全量列表缓存")
    func cacheHitSkipsDatabaseUntilForced() async throws {
        let (vm, db, _) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/old", stars: 1, starredAt: "2026-05-01T00:00:00Z")
        await vm.reloadItems()
        #expect(vm.items.map(\.id) == [1])

        try await insertRepo(db, id: 2, fullName: "o/new", stars: 1, starredAt: "2026-05-02T00:00:00Z")

        // 数据库分页模式下普通 reload 只读取当前页，不再依赖旧的全量列表缓存。
        await vm.reloadItems()
        #expect(vm.items.map(\.id) == [2, 1])

        // forceRefresh 仍应保持同样结果，且不退回旧缓存。
        await vm.reloadItems(forceRefresh: true)
        #expect(vm.items.map(\.id) == [2, 1])
    }

    // MARK: - D2 过滤

    @Test("D2: hideArchived = true → 隐藏 archived 仓库")
    func hideArchivedFilters() async throws {
        let (vm, db, _) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/a", stars: 0, starredAt: "2026-05-01T00:00:00Z", isArchived: true)
        try await insertRepo(db, id: 2, fullName: "o/b", stars: 0, starredAt: "2026-05-02T00:00:00Z", isArchived: false)
        await vm.reloadItems()
        #expect(vm.items.count == 2)

        vm.hideArchived = true
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.items.map(\.id) == [2])
    }

    @Test("D2: hideForks = true → 隐藏 fork 仓库")
    func hideForksFilters() async throws {
        let (vm, db, _) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/x", stars: 0, starredAt: "2026-05-01T00:00:00Z", isFork: true)
        try await insertRepo(db, id: 2, fullName: "o/y", stars: 0, starredAt: "2026-05-02T00:00:00Z", isFork: false)
        await vm.reloadItems()

        vm.hideForks = true
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.items.map(\.id) == [2])
    }

    @Test("D2: 同时 hideArchived + hideForks → 两类都隐藏")
    func bothFiltersStack() async throws {
        let (vm, db, _) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/normal", stars: 0, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/archived", stars: 0, starredAt: "2026-05-02T00:00:00Z", isArchived: true)
        try await insertRepo(db, id: 3, fullName: "o/forked", stars: 0, starredAt: "2026-05-03T00:00:00Z", isFork: true)
        await vm.reloadItems()

        vm.hideArchived = true
        vm.hideForks = true
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.items.map(\.id) == [1])
        #expect(vm.hasActiveFilter)
    }

    @Test("PR-2: Manage 知识库筛选支持全部 / 已入库 / 未入库并可组合")
    func libraryFilterStacksWithManageFilters() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/outside-normal", stars: 0, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/in-library", stars: 0, starredAt: "2026-05-02T00:00:00Z")
        try await insertRepo(
            db,
            id: 3,
            fullName: "o/outside-fork",
            stars: 0,
            starredAt: "2026-05-03T00:00:00Z",
            isFork: true
        )
        try await noteRepo.updateLibraryState(repoId: 2, state: .inLibrary)

        await vm.reloadItems(forceRefresh: true)
        #expect(vm.items.map(\.id) == [3, 2, 1])

        vm.libraryFilter = .inLibrary
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.items.map(\.id) == [2])

        vm.libraryFilter = .outsideLibrary
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.items.map(\.id) == [3, 1])

        vm.hideForks = true
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.items.map(\.id) == [1])

        vm.libraryFilter = .all
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.items.map(\.id) == [2, 1])
    }

    @Test("Sidebar 知识库基础分类直接展示已入库 repo")
    func sidebarLibrarySelectionUsesLibraryScope() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/starred-library", stars: 5, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(
            db,
            id: 2,
            fullName: "o/library-only",
            stars: 8,
            starredAt: "2026-05-02T00:00:00Z",
            isStarred: false
        )
        try await insertRepo(db, id: 3, fullName: "o/starred-outside", stars: 13, starredAt: "2026-05-03T00:00:00Z")
        try await noteRepo.updateLibraryState(repoId: 1, state: .inLibrary)
        try await noteRepo.updateLibraryState(repoId: 2, state: .inLibrary)

        vm.selection = .library
        await vm.reloadItems(forceRefresh: true)

        #expect(Set(vm.items.map(\.id)) == [1, 2])
        #expect(vm.visibleRepoTotalCount == 2)
    }

    @Test("D2: 过滤掉当前选中行 → selectedRepoID 自动清空")
    func filterClearsSelectionWhenItemHidden() async throws {
        let (vm, db, _) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/x", stars: 0, starredAt: "2026-05-01T00:00:00Z", isArchived: true)
        try await insertRepo(db, id: 2, fullName: "o/y", stars: 0, starredAt: "2026-05-02T00:00:00Z")
        await vm.reloadItems()
        vm.selectedRepoID = 1

        vm.hideArchived = true
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.selectedRepoID == nil, "选中的 archived repo 被过滤后应清空 selection")
    }

    @Test("D2: 切回 hideArchived = false → 之前被隐藏的恢复显示")
    func toggleFilterOff() async throws {
        let (vm, db, _) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/x", stars: 0, starredAt: "2026-05-01T00:00:00Z", isArchived: true)
        try await insertRepo(db, id: 2, fullName: "o/y", stars: 0, starredAt: "2026-05-02T00:00:00Z")
        await vm.reloadItems()
        vm.hideArchived = true
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.items.count == 1)

        vm.hideArchived = false
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.items.count == 2)
        #expect(vm.hasActiveFilter == false)
    }

    // MARK: - D3 状态过滤

    @Test("D3: 按 .using 过滤,仅显式标记 using 的 repo 通过")
    func statusFilterUsing() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/a", stars: 0, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/b", stars: 0, starredAt: "2026-05-02T00:00:00Z")
        try await insertRepo(db, id: 3, fullName: "o/c", stars: 0, starredAt: "2026-05-03T00:00:00Z")
        try await noteRepo.updateStatus(repoId: 1, status: .using)
        try await noteRepo.updateStatus(repoId: 2, status: .read)
        // repo 3 无 note → implicit unread
        await vm.reloadItems()

        vm.statusFilter = .using
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.items.map(\.id) == [1])
        #expect(vm.hasActiveFilter)
    }

    @Test("Smart Collections: .using 仅展示显式标记正在使用的 repo")
    func smartCollectionUsing() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/a", stars: 0, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/b", stars: 0, starredAt: "2026-05-02T00:00:00Z")
        try await insertRepo(db, id: 3, fullName: "o/c", stars: 0, starredAt: "2026-05-03T00:00:00Z")
        try await noteRepo.updateStatus(repoId: 1, status: .using)
        try await noteRepo.updateStatus(repoId: 2, status: .read)
        try await noteRepo.updateStatus(repoId: 3, status: .using)

        vm.selectSidebar(.smartCollection(.using))
        await vm.reloadItems(forceRefresh: true)

        // Smart Collection 复用 repo_notes 的显式 using 状态；无 note / read 不应混入。
        #expect(vm.items.map(\.id) == [3, 1])
    }

    @Test("Smart Collections: .library 包含未 star 已入库 repo,Manage 默认不混入")
    func smartCollectionLibraryIncludesUnstarredLibraryRepos() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(
            db,
            id: 1,
            fullName: "o/starred-library",
            stars: 0,
            starredAt: "2026-05-03T00:00:00Z",
            language: "Swift"
        )
        try await insertRepo(
            db,
            id: 2,
            fullName: "o/starred-outside",
            stars: 0,
            starredAt: "2026-05-02T00:00:00Z",
            language: "Rust"
        )
        try await insertRepo(
            db,
            id: 3,
            fullName: "o/library-only",
            stars: 0,
            starredAt: "2026-05-01T00:00:00Z",
            language: "TypeScript",
            isStarred: false
        )
        try await noteRepo.updateLibraryState(repoId: 1, state: .inLibrary)
        try await noteRepo.updateLibraryState(repoId: 3, state: .inLibrary)

        await vm.reloadItems(forceRefresh: true)
        #expect(vm.items.map(\.id) == [1, 2], "Manage 默认仍是 starred 管理视图")

        vm.selectSidebar(.smartCollection(.library))
        await vm.reloadItems(forceRefresh: true)

        #expect(Set(vm.items.map(\.id)) == [1, 3])
        #expect(vm.items.map(\.id).contains(2) == false)

        vm.repoLanguageFilter = .language("TypeScript")
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.items.map(\.id) == [3])

        vm.repoLanguageFilter = .language("Swift")
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.items.map(\.id) == [1])
    }

    @Test("Smart Collections: 未入库 Stars 仅展示已 star 且未加入知识库的 repo")
    func smartCollectionOutsideLibraryStars() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(
            db,
            id: 1,
            fullName: "o/starred-library",
            stars: 0,
            starredAt: "2026-05-03T00:00:00Z"
        )
        try await insertRepo(
            db,
            id: 2,
            fullName: "o/starred-outside",
            stars: 0,
            starredAt: "2026-05-02T00:00:00Z"
        )
        try await insertRepo(
            db,
            id: 3,
            fullName: "o/library-only",
            stars: 0,
            starredAt: "2026-05-01T00:00:00Z",
            isStarred: false
        )
        try await noteRepo.updateLibraryState(repoId: 1, state: .inLibrary)
        try await noteRepo.updateLibraryState(repoId: 3, state: .inLibrary)

        vm.selectSidebar(.smartCollection(.outsideLibraryStars))
        await vm.reloadItems(forceRefresh: true)

        #expect(vm.items.map(\.id) == [2])
    }

    @Test("PR-5: 知识库集合内搜索使用 knowledge FTS 范围")
    func librarySearchUsesKnowledgeFTSScope() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(
            db,
            id: 1,
            fullName: "o/starred-only",
            stars: 0,
            starredAt: "2026-05-03T00:00:00Z"
        )
        try await insertRepo(
            db,
            id: 2,
            fullName: "o/knowledge-target",
            stars: 0,
            starredAt: "2026-05-02T00:00:00Z",
            isStarred: false
        )
        try await noteRepo.updateLibraryState(repoId: 2, state: .inLibrary)

        vm.selectSidebar(.smartCollection(.library))
        vm.submitSearch("knowledge")
        await vm.reloadItems(forceRefresh: true)

        #expect(vm.items.map(\.id) == [2])
    }

    @Test("D3: 按 .unread 过滤包含 implicit unread(无 note)与 explicit unread")
    func statusFilterUnreadIncludesImplicit() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/a", stars: 0, starredAt: "2026-05-03T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/b", stars: 0, starredAt: "2026-05-02T00:00:00Z")
        try await insertRepo(db, id: 3, fullName: "o/c", stars: 0, starredAt: "2026-05-01T00:00:00Z")
        try await noteRepo.updateStatus(repoId: 2, status: .unread)
        try await noteRepo.updateStatus(repoId: 3, status: .using)
        // repo 1 无 note(implicit unread)
        await vm.reloadItems()

        vm.statusFilter = .unread
        await vm.awaitPendingListReloadForTesting()

        #expect(Set(vm.items.map(\.id)) == [1, 2], "implicit unread(1) + explicit unread(2) 都应通过")
    }

    @Test("D3: statusFilter = nil → 不做状态过滤")
    func statusFilterNilPassesAll() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/a", stars: 0, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/b", stars: 0, starredAt: "2026-05-02T00:00:00Z")
        try await noteRepo.updateStatus(repoId: 1, status: .using)
        await vm.reloadItems()

        vm.statusFilter = nil

        #expect(vm.items.count == 2)
    }

    // MARK: - v2 readStatus 角标支持（2026-06-12）

    @Test("readStatus(for:): reloadItems 后 status 正确反映到 dict 中")
    func readStatusReflectsDatabase() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/a", stars: 0, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/b", stars: 0, starredAt: "2026-05-02T00:00:00Z")
        try await insertRepo(db, id: 3, fullName: "o/c", stars: 0, starredAt: "2026-05-03T00:00:00Z")
        try await noteRepo.updateStatus(repoId: 1, status: .using)
        try await noteRepo.updateStatus(repoId: 2, status: .read)
        // repo 3 无 note → implicit unread

        await vm.reloadItems()

        #expect(vm.readStatus(for: 1) == .using)
        #expect(vm.readStatus(for: 2) == .read)
        #expect(vm.readStatus(for: 3) == .unread, "implicit unread: 未在 repo_notes 写过的 repo 默认 unread")
    }

    @Test("observeRepoStatusChanges: NotificationCenter post 后 readStatus 即时刷新")
    func notificationDrivesStatusMapUpdate() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/a", stars: 0, starredAt: "2026-05-01T00:00:00Z")
        try await noteRepo.updateStatus(repoId: 1, status: .unread)
        await vm.reloadItems()
        #expect(vm.readStatus(for: 1) == .unread)

        // 启动 observer task；后续 post 后异步消费 + 更新 dict。
        let task = Task { await vm.observeRepoStatusChanges() }
        // 让 observer 进入 await stream 状态（避免在 post 之前 stream 还没建好导致丢消息）
        try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

        NotificationCenter.default.post(
            name: .repoStatusDidChange,
            object: nil,
            userInfo: ["repoId": Int64(1), "status": RepoStatus.using.rawValue]
        )

        // 等待 observer 消费通知（异步 + main actor hop）
        try await pollUntil(timeout: 1.0) { vm.readStatus(for: 1) == .using }
        #expect(vm.readStatus(for: 1) == .using)

        // 兜底：取消 observer task，避免 leak
        task.cancel()
    }

    @Test("observeRepoLibraryStateChanges: 入库事件驱动知识库列表自动刷新")
    func notificationDrivesLibraryListRefresh() async throws {
        let (vm, db, noteRepo) = try makeSUT()
        try await insertRepo(
            db,
            id: 1,
            fullName: "o/library-candidate",
            stars: 0,
            starredAt: "2026-05-01T00:00:00Z",
            isStarred: false
        )

        vm.selection = .library
        await vm.reloadItems(forceRefresh: true)
        #expect(vm.items.isEmpty)
        #expect(vm.libraryCount == 0)

        let task = Task { await vm.observeRepoLibraryStateChanges() }
        try await Task.sleep(nanoseconds: 50_000_000)

        try await noteRepo.updateLibraryState(repoId: 1, state: .inLibrary)

        try await pollUntil(timeout: 1.0) { vm.items.map(\.id) == [1] && vm.libraryCount == 1 }
        #expect(vm.items.map(\.id) == [1])
        #expect(vm.libraryCount == 1)

        task.cancel()
    }

    // MARK: - 用户智能集合：countRepos 与列表 filter 一致

    @Test("用户智能集合含 healthScoreMin 时，列表条数与 countRepos 一致")
    func userSmartCollectionListMatchesCountRepos() async throws {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        let tagRepo = GRDBTagRepository(database: db)
        let rtRepo = GRDBRepoTagRepository(database: db)
        let noteRepo = GRDBRepoNoteRepository(database: db)
        let healthRepo = GRDBRepoHealthRepository(database: db)
        let smartRepo = GRDBSmartCollectionRepository(database: db)

        try await insertRepo(db, id: 1, fullName: "o/low", stars: 10, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/mid", stars: 20, starredAt: "2026-05-02T00:00:00Z")
        try await insertRepo(db, id: 3, fullName: "o/high", stars: 30, starredAt: "2026-05-03T00:00:00Z")

        let now = "2026-06-21T12:00:00.000Z"
        let stale = "2026-07-21T12:00:00.000Z"
        for (repoId, score) in [(Int64(1), 40.0), (Int64(2), 75.0), (Int64(3), 95.0)] {
            try await healthRepo.upsert(
                RepoHealthSnapshot(
                    repoId: repoId,
                    overallScore: score,
                    grade: "B",
                    maintenanceScore: score,
                    popularityScore: score,
                    qualityScore: score,
                    securityScore: score,
                    payloadJSON: "{}",
                    computedAt: now,
                    staleAfter: stale,
                    fetchStatus: .success,
                    lastError: nil
                )
            )
        }

        let rule = SmartCollectionRule(
            scope: .allStars,
            query: nil,
            searchModeRaw: SmartSearchMode.keyword.rawValue,
            statusRaw: nil,
            selectedTagIDs: [],
            hideArchived: false,
            hideForks: false,
            sortRaw: RepoSortOption.starredAtDesc.rawValue,
            healthScoreMin: 60
        )
        try await smartRepo.create(
            UserSmartCollection(
                id: "health-test",
                name: "Health 60+",
                icon: "line.3.horizontal.decrease.circle",
                color: nil,
                ruleJSON: try SmartCollectionRule.encode(rule),
                sortOrder: 0,
                createdAt: now,
                updatedAt: now
            )
        )

        let vm = HomeViewModel(
            repository: repo,
            tagRepository: tagRepo,
            repoTagRepository: rtRepo,
            repoNoteRepository: noteRepo,
            repoHealthRepository: healthRepo,
            smartCollectionRepository: smartRepo
        )

        let expectedCount = try await vm.countRepos(matching: rule)
        #expect(expectedCount == 2)

        await vm.refreshSidebar()
        vm.selectSidebar(.userSmartCollection("health-test"))
        await vm.reloadItems()

        #expect(vm.items.map(\.id) == [3, 2], "healthScoreMin=60 应保留 mid/high，且按 starredAtDesc 排序")
        #expect(vm.items.count == expectedCount)
    }

    @Test("refreshSidebar: 加载 GitHub Stars List 与未分组计数")
    func refreshSidebarLoadsGitHubStarLists() async throws {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        let tagRepo = GRDBTagRepository(database: db)
        let rtRepo = GRDBRepoTagRepository(database: db)
        let noteRepo = GRDBRepoNoteRepository(database: db)
        let listRepo = GRDBGitHubStarListRepository(database: db)

        try await insertRepo(db, id: 1, fullName: "o/one", stars: 1, starredAt: "2026-06-26T02:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/two", stars: 1, starredAt: "2026-06-26T01:00:00Z")
        try await listRepo.replaceRemoteSnapshot(
            lists: [
                GitHubStarListRemoteRecord(
                    id: "list-1",
                    name: "Tools",
                    description: nil,
                    isPrivate: false,
                    position: 0,
                    createdAt: nil,
                    updatedAt: nil
                )
            ],
            memberships: [
                GitHubStarListRemoteMembership(listId: "list-1", repoFullName: "o/one")
            ],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let vm = HomeViewModel(
            repository: repo,
            tagRepository: tagRepo,
            repoTagRepository: rtRepo,
            githubStarListRepository: listRepo,
            repoNoteRepository: noteRepo
        )

        await vm.refreshSidebar()

        #expect(vm.githubStarLists.map(\.id) == ["list-1"])
        #expect(vm.githubStarListCounts["list-1"] == 1)
        #expect(vm.githubStarListUngroupedCount == 1)
    }

    @Test("GitHub Stars List: 切换分组临时跳过 row reveal")
    func githubStarListSwitchSkipsRowReveal() async throws {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        let tagRepo = GRDBTagRepository(database: db)
        let rtRepo = GRDBRepoTagRepository(database: db)
        let noteRepo = GRDBRepoNoteRepository(database: db)
        let listRepo = GRDBGitHubStarListRepository(database: db)

        try await insertRepo(db, id: 1, fullName: "o/one", stars: 1, starredAt: "2026-06-26T02:00:00Z")
        try await listRepo.replaceRemoteSnapshot(
            lists: [makeStarList(id: "list-1", name: "Tools", position: 0)],
            memberships: [GitHubStarListRemoteMembership(listId: "list-1", repoFullName: "o/one")],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let vm = HomeViewModel(
            repository: repo,
            tagRepository: tagRepo,
            repoTagRepository: rtRepo,
            githubStarListRepository: listRepo,
            repoNoteRepository: noteRepo
        )
        await vm.refreshSidebar()

        vm.selectSidebar(.githubStarList("list-1"))

        #expect(vm.skipListRowReveal == true)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(vm.skipListRowReveal == false)
    }

    @Test("GitHub Stars List: 切到已知空分组立即清空旧列表")
    func githubStarListKnownEmptyClearsVisibleItems() async throws {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        let tagRepo = GRDBTagRepository(database: db)
        let rtRepo = GRDBRepoTagRepository(database: db)
        let noteRepo = GRDBRepoNoteRepository(database: db)
        let listRepo = GRDBGitHubStarListRepository(database: db)

        try await insertRepo(db, id: 1, fullName: "o/one", stars: 1, starredAt: "2026-06-26T02:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/two", stars: 1, starredAt: "2026-06-26T01:00:00Z")
        try await listRepo.replaceRemoteSnapshot(
            lists: [
                makeStarList(id: "list-filled", name: "Filled", position: 0),
                makeStarList(id: "list-empty", name: "Empty", position: 1),
            ],
            memberships: [GitHubStarListRemoteMembership(listId: "list-filled", repoFullName: "o/one")],
            syncedAt: Date(timeIntervalSince1970: 0)
        )

        let vm = HomeViewModel(
            repository: repo,
            tagRepository: tagRepo,
            repoTagRepository: rtRepo,
            githubStarListRepository: listRepo,
            repoNoteRepository: noteRepo
        )
        await vm.refreshSidebar()
        vm.selectSidebar(.githubStarList("list-filled"))
        await vm.reloadItems()
        #expect(vm.items.map(\.id) == [1])
        let revisionAfterFilledList = vm.itemsRevision

        vm.selectSidebar(.githubStarList("list-empty"))

        #expect(vm.isKnownEmptyGitHubStarListSelection == true)
        #expect(vm.items.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.hasMore == false)
        #expect(vm.isGitHubStarListSwitchLoading == false)
        #expect(vm.itemsRevision == revisionAfterFilledList + 1)

        vm.selectSidebar(.githubStarList("list-filled"))
        #expect(vm.isGitHubStarListSwitchLoading == true)
        #expect(vm.items.isEmpty)

        await vm.reloadItems()

        #expect(vm.isGitHubStarListSwitchLoading == false)
        #expect(vm.items.map(\.id) == [1])
    }

    /// 周期性检查条件，最多等待 `timeout` 秒；条件成立立即返回。
    /// 用于异步状态更新的等待，避免硬编码 sleep。
    ///
    /// 本 Suite 是 `@MainActor`，condition closure 与本方法都在 main actor 上下文执行。
    private func pollUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.02,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }
}

// MARK: - W4-4 D2：AppSettings 过滤偏好持久化

@MainActor
@Suite("AppSettings filter prefs (D2)")
struct AppSettingsFilterTests {

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "test.starcat.appsettings.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suiteName)!
        d.removePersistentDomain(forName: suiteName)
        return d
    }

    @Test("D2: 默认 hideArchived = false, hideForks = false")
    func defaults() {
        let s = AppSettings(defaults: makeIsolatedDefaults())
        #expect(s.hideArchived == false)
        #expect(s.hideForks == false)
    }

    @Test("D2: 设置后重新读取保持值")
    func persists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        s1.hideArchived = true
        s1.hideForks = true
        let s2 = AppSettings(defaults: defaults)
        #expect(s2.hideArchived == true)
        #expect(s2.hideForks == true)
    }

    // MARK: - D3：statusFilter 持久化

    @Test("D3: 默认 statusFilter = nil(全部)")
    func statusDefault() {
        let s = AppSettings(defaults: makeIsolatedDefaults())
        #expect(s.statusFilter == nil)
    }

    @Test("D3: 设置 statusFilter 后重新读取保持")
    func statusPersists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        s1.statusFilter = .using
        let s2 = AppSettings(defaults: defaults)
        #expect(s2.statusFilter == .using)
    }

    @Test("D3: 设置 nil 后重新读取也是 nil(清空)")
    func statusNilPersists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        s1.statusFilter = .read
        s1.statusFilter = nil
        let s2 = AppSettings(defaults: defaults)
        #expect(s2.statusFilter == nil)
    }

    @Test("PR-2: 默认 libraryFilter = .all")
    func libraryFilterDefault() {
        let s = AppSettings(defaults: makeIsolatedDefaults())
        #expect(s.libraryFilter == .all)
    }

    @Test("PR-2: 设置 libraryFilter 后重新读取保持")
    func libraryFilterPersists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        s1.libraryFilter = .inLibrary
        let s2 = AppSettings(defaults: defaults)
        #expect(s2.libraryFilter == .inLibrary)
    }

    @Test("PR-2: 设置 repoLanguageFilter 后重新读取保持")
    func repoLanguageFilterPersists() {
        let defaults = makeIsolatedDefaults()
        let s1 = AppSettings(defaults: defaults)
        s1.repoLanguageFilter = .language("Swift")
        let s2 = AppSettings(defaults: defaults)
        #expect(s2.repoLanguageFilter == .language("Swift"))

        s1.repoLanguageFilter = .uncategorized
        let s3 = AppSettings(defaults: defaults)
        #expect(s3.repoLanguageFilter == .uncategorized)
    }
}
