//
//  HomeViewModelPaginationTests.swift
//  StarcatTests
//
//  R-07（2026-06-15 客户端分页 + 首页边沿上屏）+ R-07.1（2026-06-16 hasMore false→true
//  视图层主动 push）端到端验证。
//
//  覆盖路径：
//  - R-07 基础：items 是 filteredSorted 的 currentPage * pageSize 切片
//  - R-07 基础：loadMoreIfNeeded 推进 currentPage 让 items 增长一页
//  - R-07 基础：loadMoreIfNeeded 在 hasMore = false 时 guard 幂等
//  - R-07 基础：loadMoreIfNeeded 走 .append 路径不 bump itemsRevision（保滚动位置）
//  - R-07.1 修复：sync 完成模拟（reloadItems(forceRefresh: true) + DB 注入更多 repo）后,
//    filteredSorted 扩张 → hasMore 必须翻 false → true（这是 view 层 .onChange 触发
//    自动 loadMoreIfNeeded 的前提 contract）
//  - R-07.1 修复：hasMore 翻转后调一次 loadMoreIfNeeded,items 必须增长一页（让用户
//    能继续向下滚动加载剩余数据）
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

    private func makeSUT() throws -> (HomeViewModel, any DatabaseManaging) {
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

    @Test("DB Paging: reloadItems 后 items 是首页 pageSize 切片,全集只通过轻量 projection 获取")
    func reloadItemsSlicesToFirstPage() async throws {
        let (vm, db) = try makeSUT()
        for i in 1...100 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }

        await vm.reloadItems()

        #expect(vm.items.count == HomeViewModel.pageSize, "首屏只切 pageSize=20 条")
        #expect(vm.items.map(\.id).prefix(3) == [1, 2, 3], "按 starred_at desc 排序后 id 升序在前")
        #expect(vm.filteredSorted.count == HomeViewModel.pageSize, "数据库分页模式下 filteredSorted 只镜像已加载页")
        #expect(await vm.selectionSnapshotsForCurrentQuery().count == 100, "全集语义改走 id/owner/name 轻量 projection")
        #expect(vm.currentPage == 1)
        #expect(vm.hasMore == true, "100 > 20 → 还有更多可加载")
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

        #expect(vm.items.count == 40, "20 → 40,增长一页")
        #expect(vm.currentPage == 2)
        #expect(vm.hasMore == true, "100 > 40,后续仍有更多")
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
        #expect(vm.filteredSorted.count == total,
                "DB 分页模式下 filteredSorted 镜像已加载全集")
        #expect(vm.currentPage == Int(ceil(Double(total) / Double(HomeViewModel.pageSize))))
        #expect(vm.itemsRevision == revisionAfterFirstPage,
                "后续 92 次左右 append 都不应 bump snapshot，否则 List 会持续重建并掉帧")
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

        // 模拟用户在 sync 期间滚到底,触发 loadMoreIfNeeded × 4 让 items 涨到 100
        for _ in 0..<4 {
            vm.loadMoreIfNeeded()
            await vm.awaitPendingListReloadForTesting()
        }
        #expect(vm.items.count == 100)
        #expect(vm.currentPage == 5)
        #expect(vm.hasMore == false, "用户已把 items 滚到 filteredSorted 末尾")

        // 模拟 sync 继续拉,DB 总数从 100 → 200
        for i in 101...200 {
            try await insertRepo(db, id: Int64(i), fullName: "o/r\(i)", starredAt: starredAt(forID: i))
        }

        // 模拟 sync 完成事件：HomeView .task(id: syncManager.state) 调 reloadItems(forceRefresh: true)
        await vm.reloadItems(forceRefresh: true)

        // R-07 既有 preserveScrollPosition contract：不抢用户滚动位置
        #expect(vm.currentPage == 5, "preserveScrollPosition: currentPage 不应被重置")
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
        for _ in 0..<4 {
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

        // 模拟 RepoListView 的 `.onChange(of: hasMore)` 在 false→true 边沿调一次 loadMoreIfNeeded。
        // 视图层的 `Task { @MainActor in viewModel.loadMoreIfNeeded() }` 在单测里
        // 直接同步调即可——loadMoreIfNeeded 本身就是 @MainActor 同步方法。
        vm.loadMoreIfNeeded()
        await vm.awaitPendingListReloadForTesting()

        #expect(vm.items.count == 120, "loadMoreIfNeeded 让 items 增长一页(20 条),用户能继续向下滚动")
        #expect(vm.currentPage == 6)
        #expect(vm.hasMore == true, "200 > 120,后续仍有更多可加载")
    }
}
