//
//  HomeViewModelPaginationTests.swift
//  StarcatTests
//
//  R-07（2026-06-15 客户端分页 + 首页边沿上屏）+ R-07.1（2026-06-16 深滚动刷新恢复）
//  端到端验证。
//
//  覆盖路径：
//  - R-07 基础：items 是 filteredSorted 的 currentPage * pageSize 切片
//  - R-07 基础：loadMoreIfNeeded 推进 currentPage 让 items 增长一页
//  - R-07 基础：loadMoreIfNeeded 在 hasMore = false 时 guard 幂等
//  - R-07 基础：loadMoreIfNeeded 走 .append 路径不 bump itemsRevision（保滚动位置）
//  - R-07.1 修复：sync 完成模拟（reloadItems(forceRefresh: true) + DB 注入更多 repo）后,
//    filteredSorted 扩张 → hasMore 必须翻 false → true。
//  - 2026-07-18 性能专项：首次首页不能消费该边沿自动追加；只有刷新前已深滚到底时，
//    recoverPaginationAfterRefreshIfNeeded 才允许补一页。
//
//  视图层 `.onChange(of: viewModel.hasMore)` 本身由 SwiftUI 触发,不在单测可达范围；
//  本 Suite 通过手动调用 loadMoreIfNeeded() 验证 ViewModel 层的 contract 不会回归。
//

import Testing
import Foundation
import GRDB
@testable import Starcat

@MainActor
@Suite("HomeViewModel pagination (R-07 + R-07.1)")
struct HomeViewModelPaginationTests {

    /// 构造一个已 star 的 repo 行,字段尽量精简。
    /// 与 `HomeViewModelFilterSortTests.insertRepo` 同款裸 SQL 写法,避免依赖 GitHubRepoDTO。
    private func insertRepo(
        _ db: any DatabaseManaging,
        id: Int64,
        fullName: String,
        starredAt: String
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
                    ?, 'o', ?, ?, NULL, NULL,
                    0, 0, 0, NULL, NULL,
                    NULL, ?, NULL, NULL,
                    0, 0, 0, 1,
                    NULL, NULL, NULL, ?, '2026-05-30T00:00:00Z'
                )
                """,
                arguments: [
                    id,
                    fullName.split(separator: "/").last.map(String.init) ?? "n",
                    fullName,
                    "https://github.com/\(fullName)",
                    starredAt
                ]
            )
        }
    }

    private func makeSUT(
        beforeDatabasePageFetchForTesting: (@Sendable () async -> Void)? = nil
    ) throws -> (HomeViewModel, any DatabaseManaging) {
        let db = try InMemoryDatabaseManager()
        let repo = GRDBRepoRepository(database: db)
        let tagRepo = GRDBTagRepository(database: db)
        let rtRepo = GRDBRepoTagRepository(database: db)
        let noteRepo = GRDBRepoNoteRepository(database: db)
        let vm = HomeViewModel(
            repository: repo,
            tagRepository: tagRepo,
            repoTagRepository: rtRepo,
            repoNoteRepository: noteRepo,
            beforeDatabasePageFetchForTesting: beforeDatabasePageFetchForTesting
        )
        return (vm, db)
    }

    /// id 越小 → starred_at 越新（保证 `fetchAllStarred()` 按 starred_at desc 排序后
    /// 前缀里 id 升序排列,便于 sliceToCurrentPage 的 itemsIdentical 短路比较断言）。
    ///
    /// 用 `9999 - id` 作为年份编码,字符串字典序与时间倒序一致——ISO 字符串前 4 位
    /// 即年份,后续字段全部相同时字典序完全取决于年份大小。SQLite 文本列按 BINARY
    /// 排序,与 Swift String 字典序一致。
    /// 上限 9998 个 id 足够本 Suite 任何场景。
    private func starredAt(forID id: Int) -> String {
        String(format: "%04d-12-31T23:59:59Z", 9999 - id)
    }

    // MARK: - R-07 基础行为

    @Test("外部导航重复打开同一 repo 时仍发出新的滚动请求")
    func repeatedExternalNavigationStillRequestsScroll() throws {
        let (vm, _) = try makeSUT()
        vm.selectedRepoID = 42

        vm.requestSelectedRepoScroll()
        #expect(vm.repoListScrollRequestRevision == 1)

        vm.requestSelectedRepoScroll()
        #expect(vm.repoListScrollRequestRevision == 2,
                "滚动请求不能依赖 selectedRepoID 变化，否则重复点击同一搜索结果不会定位")
    }

    @Test("DB Paging: 外部导航一次加载到深页目标")
    func externalNavigationLoadsTargetPage() async throws {
        let (vm, db) = try makeSUT()
        // pageSize 已提到 40；要覆盖「第 4 页」至少需要 4 * pageSize 条，
        // 目标取第 4 页中间一行（0-based index = 3*pageSize + pageSize/2）。
        let targetPage = 4
        let total = HomeViewModel.pageSize * targetPage
        let targetId = Int64((targetPage - 1) * HomeViewModel.pageSize + HomeViewModel.pageSize / 2)
        for i in 1...total {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }
        await vm.reloadItems()
        #expect(vm.items.count == HomeViewModel.pageSize)

        await vm.ensureRepoLoadedForExternalNavigation(repoId: targetId)

        #expect(vm.items.count == HomeViewModel.pageSize * targetPage,
                "repo \(targetId) 位于第 \(targetPage) 页，外部导航应一次准备到该页")
        #expect(vm.items.contains(where: { $0.id == targetId }))
        #expect(vm.currentPage == targetPage)
    }

    @Test("相同 query identity 的并发 reload 复用同一 generation 和 DB query")
    func duplicateReloadCoalescesIntoOneGeneration() async throws {
        let gate = FirstDatabaseFetchGate()
        let (vm, db) = try makeSUT {
            await gate.blockFirstCall()
        }
        try await insertRepo(db, id: 1, fullName: "o/r1", starredAt: starredAt(forID: 1))

        let first = Task { @MainActor in
            await vm.reloadItems(reason: .selection)
        }
        await gate.waitUntilFirstCallIsBlocked()
        let firstGeneration = vm.reloadGenerationForTesting

        let duplicate = Task { @MainActor in
            await vm.reloadItems(reason: .selection)
        }
        await Task.yield()

        #expect(vm.reloadGenerationForTesting == firstGeneration,
                "相同 identity 只能 await 现有 query，不能创建新 generation")
        await gate.resumeFirstCall()
        await first.value
        await duplicate.value

        let callCount = await gate.totalCallCount()
        #expect(callCount == 1, "coalesced reload 不能重复进入 DB query")
        #expect(vm.items.map(\.id) == [1])
    }

    @Test("旧分类查询被取消后不能覆盖新分类 generation")
    func cancelledOldSelectionCannotOverwriteNewSelection() async throws {
        let gate = FirstDatabaseFetchGate()
        let (vm, db) = try makeSUT {
            await gate.blockFirstCall()
        }
        try await insertRepo(db, id: 1, fullName: "o/swift", starredAt: starredAt(forID: 1))
        try await insertRepo(db, id: 2, fullName: "o/go", starredAt: starredAt(forID: 2))
        try await db.writer.write { database in
            try database.execute(sql: "UPDATE repos SET language = 'Swift' WHERE id = 1")
            try database.execute(sql: "UPDATE repos SET language = 'Go' WHERE id = 2")
        }

        let oldReload = Task { @MainActor in
            await vm.reloadItems(reason: .selection)
        }
        await gate.waitUntilFirstCallIsBlocked()

        vm.selection = .language("Swift")
        let newReload = Task { @MainActor in
            await vm.reloadItems(reason: .selection)
        }
        await newReload.value
        #expect(vm.items.map(\.id) == [1], "新分类必须先正常发布")

        await gate.resumeFirstCall()
        await oldReload.value
        #expect(vm.items.map(\.id) == [1], "旧 all-stars 结果返回后不得覆盖 Swift 分类")
    }

    @Test("DB Paging: 分类 A-B-A 命中首屏快照时同步上屏且不重复查询")
    func categoryRoundTripUsesPreparedDatabaseSnapshot() async throws {
        let counter = DatabaseFetchCounter()
        let (vm, db) = try makeSUT {
            await counter.recordFetch()
        }
        try await insertRepo(db, id: 1, fullName: "o/swift", starredAt: starredAt(forID: 1))
        try await insertRepo(db, id: 2, fullName: "o/go", starredAt: starredAt(forID: 2))
        try await db.writer.write { database in
            try database.execute(sql: "UPDATE repos SET language = 'Swift' WHERE id = 1")
            try database.execute(sql: "UPDATE repos SET language = 'Go' WHERE id = 2")
        }

        await vm.reloadItems(reason: .selection)
        vm.selection = .language("Swift")
        await vm.reloadItems(reason: .selection)
        #expect(await counter.value() == 2)

        vm.selection = .allStars
        #expect(vm.items.map(\.id) == [1, 2], "selection didSet 必须在下一帧前同步恢复 A 首屏")
        #expect(vm.hasCachedItems, "新鲜 DB snapshot 应阻止 View 层重复派发查询")

        await vm.reloadItems(reason: .selection)
        #expect(await counter.value() == 2, "显式 reload 也应在 fresh snapshot 处短路")
        #expect(vm.visibleRepoTotalCount == 2)

        vm.resetAllStateForUserSwitch()
        #expect(!vm.hasCachedItems, "账号 / 数据库切换必须硬清理 DB snapshot")
    }

    @Test("DB Paging: Health 信号只失效参与筛选或排序的快照")
    func healthSignalInvalidationIsPrecise() async throws {
        let counter = DatabaseFetchCounter()
        let (vm, db) = try makeSUT {
            await counter.recordFetch()
        }
        try await insertRepo(db, id: 1, fullName: "o/r1", starredAt: starredAt(forID: 1))

        await vm.reloadItems(reason: .selection)
        #expect(await counter.value() == 1)

        vm.healthAvailabilityFilter = .missing
        await vm.awaitPendingListReloadForTesting()
        #expect(await counter.value() == 2)

        vm.invalidateDatabaseSnapshotsForHealthSignalChange()
        await vm.reloadItems(reason: .selection)
        #expect(await counter.value() == 3, "Health 筛选快照必须在信号写入后失效")

        vm.healthAvailabilityFilter = .unknown
        await vm.awaitPendingListReloadForTesting()
        #expect(await counter.value() == 3, "不依赖 Health 的默认快照不应被连带淘汰")
    }

    @Test("DB Paging: reloadItems 后 items 是首页 pageSize 切片,全集只通过轻量 projection 获取")
    func reloadItemsSlicesToFirstPage() async throws {
        let (vm, db) = try makeSUT()
        for i in 1...100 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }

        await vm.reloadItems()

        #expect(vm.items.count == HomeViewModel.pageSize, "首屏只切 pageSize 条")
        #expect(vm.items.map(\.id).prefix(3) == [1, 2, 3], "按 starred_at desc 排序后 id 升序在前")
        #expect(vm.filteredSorted.count == HomeViewModel.pageSize, "数据库分页模式下 filteredSorted 只镜像已加载页")
        #expect(vm.visibleRepoTotalCount == 100, "标题总数必须是当前查询全量,不能只显示已加载页")
        #expect(await vm.selectionSnapshotsForCurrentQuery().count == 100, "全集语义改走 id/owner/name 轻量 projection")
        #expect(vm.currentPage == 1)
        #expect(vm.hasMore == true, "100 > pageSize → 还有更多可加载")
        #expect(vm.shouldRecoverPaginationAfterRefresh == false,
                "首次首页不能被误判成深滚动恢复，否则视图会自动加载第二页")
    }

    @Test("R-07: loadMoreIfNeeded 推进 currentPage 让 items 增长一页")
    func loadMoreAdvancesItems() async throws {
        let (vm, db) = try makeSUT()
        for i in 1...100 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }
        await vm.reloadItems()

        vm.loadMoreIfNeeded()
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.items.count == HomeViewModel.pageSize * 2, "增长一页")
        #expect(vm.visibleRepoTotalCount == 100, "append 后标题总数仍应保持当前查询全量")
        #expect(vm.currentPage == 2)
        #expect(vm.hasMore == true, "100 > 已加载条数,后续仍有更多")
    }

    @Test("R-07: loadMoreIfNeeded 在 hasMore = false 时幂等不动 currentPage")
    func loadMoreIdempotentWhenNoMore() async throws {
        let (vm, db) = try makeSUT()
        for i in 1...30 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }
        await vm.reloadItems()
        vm.loadMoreIfNeeded()   // currentPage = 2, items = 30
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.items.count == 30)
        #expect(vm.hasMore == false, "30 not > 30")
        let pageBeforeRetry = vm.currentPage

        vm.loadMoreIfNeeded()
        vm.loadMoreIfNeeded()

        #expect(vm.currentPage == pageBeforeRetry, "guard hasMore: 不应继续推进")
        #expect(vm.items.count == 30)
    }

    @Test("R-07: loadMoreIfNeeded 走 .append 路径不 bump itemsRevision（保滚动位置）")
    func loadMoreDoesNotBumpRevision() async throws {
        let (vm, db) = try makeSUT()
        for i in 1...100 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }
        await vm.reloadItems()
        let revisionBefore = vm.itemsRevision

        vm.loadMoreIfNeeded()
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.itemsRevision == revisionBefore,
                "数据库分页追加必须保持同一 List snapshot，避免滚动过程中整栏重建")
    }

    @Test("DB Paging: 1856 条一路滚到底能全部 offset append，且 append 不 bump itemsRevision")
    func databasePagingLoadsLargeListToEndWithStableRevision() async throws {
        let (vm, db) = try makeSUT()
        let total = 1_856
        for i in 1...total {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }
        await vm.reloadItems()
        let revisionAfterFirstPage = vm.itemsRevision

        var guardCount = 0
        while vm.hasMore {
            guardCount += 1
            #expect(guardCount < 200, "防止分页状态异常导致测试死循环")
            vm.loadMoreIfNeeded()
            await vm.awaitPendingListReloadForTesting()
        }

        #expect(vm.items.count == total, "滚到底后必须加载出全部 starred repos")
        #expect(vm.visibleRepoTotalCount == total, "1856 大数量下标题总数应等于当前查询全量")
        #expect(vm.filteredSorted.count == total,
                "DB 分页模式下 filteredSorted 镜像已加载全集")
        #expect(vm.currentPage == Int(ceil(Double(total) / Double(HomeViewModel.pageSize))))
        #expect(vm.itemsRevision == revisionAfterFirstPage,
                "后续 92 次左右 append 都不应 bump snapshot，否则 List 会持续重建并掉帧")
    }

    @Test("DB Paging: 状态角标只加载当前页和追加页,不回退到全表 statusMap")
    func databasePagingLoadsStatusMapForVisiblePagesOnly() async throws {
        let (vm, db) = try makeSUT()
        let noteRepo = GRDBRepoNoteRepository(database: db)
        for i in 1...100 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }
        try await noteRepo.updateStatus(repoId: 1, status: .using)
        try await noteRepo.updateStatus(repoId: 50, status: .read)
        try await noteRepo.updateStatus(repoId: 90, status: .using)

        await vm.reloadItems()

        #expect(vm.statusMap[1] == .using, "首屏状态应可立即显示")
        #expect(vm.statusMap[50] == nil, "未加载页的状态不应被全表预读")
        #expect(vm.statusMap[90] == nil, "远端页状态不应污染当前分页快照")

        vm.loadMoreIfNeeded()
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.statusMap[50] == .read, "第二页加载后应合并 repo 50 的状态")
        #expect(vm.statusMap[90] == nil, "第二页仍未包含 repo 90,状态 map 不应提前全表扩张")

        vm.loadMoreIfNeeded()
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.statusMap[90] == .using, "第三页加载后再合并 repo 90 的状态")
    }

    // MARK: - R-07.1 修复 follow-up（2026-06-16 dong4j）

    @Test("R-07.1: sync 完成后 filteredSorted 扩张 → hasMore 必须翻 false→true（view 层 .onChange 触发的前提）")
    func hasMoreFlipsAfterFilteredSortedGrows() async throws {
        let (vm, db) = try makeSUT()
        // 模拟 sync 拉到 page 1（100 条）
        for i in 1...100 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }
        await vm.reloadItems()

        // 模拟用户在 sync 期间滚到底,触发 loadMoreIfNeeded 直到 items 涨到 100
        var initialDrainGuard = 0
        while vm.hasMore {
            initialDrainGuard += 1
            #expect(initialDrainGuard < 20, "防止分页状态异常导致测试死循环")
            vm.loadMoreIfNeeded()
            await vm.awaitPendingListReloadForTesting()
        }
        #expect(vm.items.count == 100)
        let pageBeforeExpansion = vm.currentPage
        #expect(vm.hasMore == false, "用户已把 items 滚到 filteredSorted 末尾")

        // 模拟 sync 继续拉,DB 总数从 100 → 200
        for i in 101...200 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }

        // 模拟 sync 完成事件：HomeView .task(id: syncManager.state) 调 reloadItems(forceRefresh: true)
        await vm.reloadItems(forceRefresh: true)

        // R-07 既有 preserveScrollPosition contract：不抢用户滚动位置
        #expect(vm.currentPage == pageBeforeExpansion, "preserveScrollPosition: currentPage 不应被重置")
        #expect(vm.items.count == 100, "sliceToCurrentPage itemsIdentical short-circuit: items 切片不应抖动")
        #expect(vm.filteredSorted.count == 100, "数据库分页模式下 filteredSorted 只镜像当前累计页")
        #expect(await vm.selectionSnapshotsForCurrentQuery().count == 200, "DB 总数扩张后全集 projection 应反映 200 条")

        // R-07.1 修复 contract：filteredSorted 扩张后,hasMore 必须翻回 true。
        // RepoListView 的 `.onChange(of: viewModel.hasMore)` 会在这个边沿主动调一次
        // `loadMoreIfNeeded()`,让 items 增长一页,用户能继续向下滚动加载剩余数据。
        #expect(vm.hasMore == true,
                "R-07.1 contract: filteredSorted 200 > items 100,hasMore 必须翻 false→true")
    }

    @Test("R-07.1: hasMore 翻 false→true 后调 loadMoreIfNeeded,items 必须能增长一页")
    func loadMoreAfterHasMoreFlippedExtendsItems() async throws {
        let (vm, db) = try makeSUT()
        for i in 1...100 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }
        await vm.reloadItems()
        var initialDrainGuard = 0
        while vm.hasMore {
            initialDrainGuard += 1
            #expect(initialDrainGuard < 20, "防止分页状态异常导致测试死循环")
            vm.loadMoreIfNeeded()
            await vm.awaitPendingListReloadForTesting()
        }
        #expect(vm.hasMore == false)

        // sync 期间继续拉数据 → 200 条
        for i in 101...200 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }
        await vm.reloadItems(forceRefresh: true)
        #expect(vm.hasMore == true)

        #expect(vm.shouldRecoverPaginationAfterRefresh == true,
                "只有用户曾深滚到底的刷新扩张才应该请求自动补一页")

        // 模拟 RepoListView 的 `.onChange(of: hasMore)` 消费一次恢复意图。
        vm.recoverPaginationAfterRefreshIfNeeded()
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.items.count == 100 + HomeViewModel.pageSize,
                "loadMoreIfNeeded 让 items 增长一页,用户能继续向下滚动")
        #expect(vm.hasMore == true, "200 > 已加载条数,后续仍有更多可加载")
        #expect(vm.shouldRecoverPaginationAfterRefresh == false, "恢复意图必须一次性消费")
    }
}

/// 只挂起第一次 DB query；第二个不同 identity 的 query 可直接完成，用于稳定复现竞态。
private actor FirstDatabaseFetchGate {
    private var callCount = 0
    private var firstCallContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func blockFirstCall() async {
        callCount += 1
        guard callCount == 1 else { return }
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstCallContinuation = continuation
        }
    }

    func waitUntilFirstCallIsBlocked() async {
        if firstCallContinuation != nil { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func resumeFirstCall() {
        firstCallContinuation?.resume()
        firstCallContinuation = nil
    }

    func totalCallCount() -> Int {
        callCount
    }
}

private actor DatabaseFetchCounter {
    private var count = 0

    func recordFetch() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
