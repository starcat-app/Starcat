//
//  HomeViewModelTagFilterTests.swift
//  StarcatTests
//
//  HomeViewModel A6 部分：Sidebar Tags 段 + 按 tag 过滤。
//

import Testing
import Foundation
@testable import Starcat

@MainActor
@Suite("HomeViewModel tag filter (A6)")
struct HomeViewModelTagFilterTests {

    private func makeAll() throws -> (
        HomeViewModel,
        GRDBTagRepository,
        GRDBRepoTagRepository,
        any DatabaseManaging
    ) {
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
        return (vm, tagRepo, rtRepo, db)
    }

    @Test("refreshSidebar: 拉取 tags + tagCounts")
    func refreshSidebarLoadsTags() async throws {
        let (vm, tagRepo, rtRepo, db) = try makeAll()
        try await db.insertRepoFixture(id: 1)
        try await db.insertRepoFixture(id: 2)
        try await tagRepo.create(.fixture(id: "t-a", name: "swift"))
        try await tagRepo.create(.fixture(id: "t-b", name: "rust"))
        try await rtRepo.addTag(repoId: 1, tagId: "t-a")
        try await rtRepo.addTag(repoId: 2, tagId: "t-a")

        await vm.refreshSidebar()

        #expect(vm.tags.count == 2)
        #expect(vm.tagCounts["t-a"] == 2)
        #expect(vm.tagCounts["t-b"] == nil) // 没关联的 tag 不出现
    }

    @Test("selection = .tag(id) → items 只含该 tag 关联的 repo")
    func reloadFiltersByTag() async throws {
        let (vm, tagRepo, rtRepo, db) = try makeAll()
        try await db.insertRepoFixture(id: 10)
        try await db.insertRepoFixture(id: 11)
        try await db.insertRepoFixture(id: 12)
        try await tagRepo.create(.fixture(id: "tg"))
        try await rtRepo.addTag(repoId: 10, tagId: "tg")
        try await rtRepo.addTag(repoId: 12, tagId: "tg")

        vm.selection = .tag("tg")
        await vm.reloadItems()

        let ids = Set(vm.items.map(\.id))
        #expect(ids == [10, 12])
    }

    @Test("selection = .tag(空 id) → items 空、无错")
    func reloadEmptyTag() async throws {
        let (vm, _, _, _) = try makeAll()
        vm.selection = .tag("nonexistent")
        await vm.reloadItems()
        #expect(vm.items.isEmpty)
        #expect(vm.loadError == nil)
    }

    @Test("SidebarItem.tag id 不与 language id 撞")
    func sidebarItemIdsDistinct() {
        let t = SidebarItem.tag("swift")
        let l = SidebarItem.language("swift")
        let all = SidebarItem.allLanguages
        let library = SidebarItem.library
        #expect(t.id != l.id)
        #expect(all.id != l.id)
        #expect(library.id != all.id)
        #expect(t.id == "tag.swift")
        #expect(l.id == "language.swift")
        #expect(all.id == "language.all")
        #expect(library.id == "section.library")
        #expect(library.systemImage == "heart.fill")
        #expect(SidebarItem(persistedRawValue: all.persistedRawValue) == all)
        #expect(SidebarItem(persistedRawValue: library.persistedRawValue) == library)
    }

    @Test("星标三级导航按 Sidebar 分组映射")
    func manageNavigationMapsSidebarGroups() {
        let allStars = ManageNavigationPresentation.make(
            selection: .allStars,
            selectionTitle: String.l10n("sidebar.allRepos"),
            selectedTagTitles: [],
            searchTitle: nil
        )
        #expect(allStars.secondLevelTitle == String.l10n("sidebar.allRepos"))
        #expect(allStars.thirdLevelTitle == String.l10n("general.all"))
        #expect(!allStars.isFilteredScope)

        let untagged = ManageNavigationPresentation.make(
            selection: .untagged,
            selectionTitle: String.l10n("sidebar.untagged"),
            selectedTagTitles: [],
            searchTitle: nil
        )
        #expect(untagged.secondLevelTitle == String.l10n("sidebar.untagged"))
        #expect(untagged.thirdLevelTitle == String.l10n("general.all"))
        #expect(untagged.isFilteredScope)

        let library = ManageNavigationPresentation.make(
            selection: .library,
            selectionTitle: String.l10n("sidebar.library"),
            selectedTagTitles: [],
            searchTitle: nil
        )
        #expect(library.secondLevelTitle == String.l10n("sidebar.library"))
        #expect(library.thirdLevelTitle == String.l10n("general.all"))
        #expect(library.isFilteredScope)

        let collections = ManageNavigationPresentation.make(
            selection: .smartCollectionsHome,
            selectionTitle: String.l10n("smartCollections.title"),
            selectedTagTitles: [],
            searchTitle: nil
        )
        #expect(collections.secondLevelTitle == String.l10n("smartCollections.title"))
        #expect(collections.thirdLevelTitle == String.l10n("smartCollections.all"))
        #expect(!collections.isFilteredScope)
    }

    @Test("语言与多标签属于全部仓库的第三级细分条件")
    func manageNavigationKeepsLanguageAndTags() {
        let presentation = ManageNavigationPresentation.make(
            selection: .language("Swift"),
            selectionTitle: "Swift",
            selectedTagTitles: ["AI", "Tools"],
            searchTitle: nil
        )

        #expect(presentation.secondLevelTitle == String.l10n("sidebar.allRepos"))
        #expect(presentation.thirdLevelTitle == "Swift · AI · Tools")
        #expect(presentation.isFilteredScope)
    }

    @Test("单语言导航显示为星标下全部仓库的第三级")
    func manageNavigationKeepsAllStarsAsLanguageBase() {
        let presentation = ManageNavigationPresentation.make(
            selection: .language("Java"),
            selectionTitle: "Java",
            selectedTagTitles: [],
            searchTitle: nil
        )

        #expect(presentation.secondLevelTitle == String.l10n("sidebar.allRepos"))
        #expect(presentation.thirdLevelTitle == "Java")
        #expect(presentation.isFilteredScope)
    }
}
