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
        isArchived: Bool = false,
        isFork: Bool = false
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
                    ?, 0, 0, NULL, NULL,
                    NULL, ?, NULL, NULL,
                    0, ?, ?, 1,
                    NULL, NULL, NULL, ?, '2026-05-30T00:00:00Z'
                )
                """,
                arguments: [
                    id,
                    fullName.split(separator: "/").last.map(String.init) ?? "n",
                    fullName,
                    stars,
                    "https://github.com/\(fullName)",
                    isFork,
                    isArchived,
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
        let vm = HomeViewModel(
            repository: repo,
            tagRepository: tagRepo,
            repoTagRepository: rtRepo
        )
        return (vm, db)
    }

    // MARK: - D1 排序

    @Test("D1: reloadItems 后按默认 starredAtDesc 排序")
    func defaultSortAfterReload() async throws {
        let (vm, db) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/aaa", stars: 100, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/zzz", stars: 1, starredAt: "2026-05-30T00:00:00Z")

        await vm.reloadItems()

        #expect(vm.items.map(\.id) == [2, 1], "默认 starredAtDesc → 最近 star 在前")
    }

    @Test("D1: sortOption 改成 starsDesc → items 立即重排,不重 fetch")
    func switchSortReorders() async throws {
        let (vm, db) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/aaa", stars: 100, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/zzz", stars: 1, starredAt: "2026-05-30T00:00:00Z")
        await vm.reloadItems()

        vm.sortOption = .starsDesc

        #expect(vm.items.map(\.id) == [1, 2], "starsDesc: 100 stars 在前")
    }

    // MARK: - D2 过滤

    @Test("D2: hideArchived = true → 隐藏 archived 仓库")
    func hideArchivedFilters() async throws {
        let (vm, db) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/a", stars: 0, starredAt: "2026-05-01T00:00:00Z", isArchived: true)
        try await insertRepo(db, id: 2, fullName: "o/b", stars: 0, starredAt: "2026-05-02T00:00:00Z", isArchived: false)
        await vm.reloadItems()
        #expect(vm.items.count == 2)

        vm.hideArchived = true

        #expect(vm.items.map(\.id) == [2])
    }

    @Test("D2: hideForks = true → 隐藏 fork 仓库")
    func hideForksFilters() async throws {
        let (vm, db) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/x", stars: 0, starredAt: "2026-05-01T00:00:00Z", isFork: true)
        try await insertRepo(db, id: 2, fullName: "o/y", stars: 0, starredAt: "2026-05-02T00:00:00Z", isFork: false)
        await vm.reloadItems()

        vm.hideForks = true

        #expect(vm.items.map(\.id) == [2])
    }

    @Test("D2: 同时 hideArchived + hideForks → 两类都隐藏")
    func bothFiltersStack() async throws {
        let (vm, db) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/normal", stars: 0, starredAt: "2026-05-01T00:00:00Z")
        try await insertRepo(db, id: 2, fullName: "o/archived", stars: 0, starredAt: "2026-05-02T00:00:00Z", isArchived: true)
        try await insertRepo(db, id: 3, fullName: "o/forked", stars: 0, starredAt: "2026-05-03T00:00:00Z", isFork: true)
        await vm.reloadItems()

        vm.hideArchived = true
        vm.hideForks = true

        #expect(vm.items.map(\.id) == [1])
        #expect(vm.hasActiveFilter)
    }

    @Test("D2: 过滤掉当前选中行 → selectedRepoID 自动清空")
    func filterClearsSelectionWhenItemHidden() async throws {
        let (vm, db) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/x", stars: 0, starredAt: "2026-05-01T00:00:00Z", isArchived: true)
        try await insertRepo(db, id: 2, fullName: "o/y", stars: 0, starredAt: "2026-05-02T00:00:00Z")
        await vm.reloadItems()
        vm.selectedRepoID = 1

        vm.hideArchived = true

        #expect(vm.selectedRepoID == nil, "选中的 archived repo 被过滤后应清空 selection")
    }

    @Test("D2: 切回 hideArchived = false → 之前被隐藏的恢复显示")
    func toggleFilterOff() async throws {
        let (vm, db) = try makeSUT()
        try await insertRepo(db, id: 1, fullName: "o/x", stars: 0, starredAt: "2026-05-01T00:00:00Z", isArchived: true)
        try await insertRepo(db, id: 2, fullName: "o/y", stars: 0, starredAt: "2026-05-02T00:00:00Z")
        await vm.reloadItems()
        vm.hideArchived = true
        #expect(vm.items.count == 1)

        vm.hideArchived = false

        #expect(vm.items.count == 2)
        #expect(vm.hasActiveFilter == false)
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
}
