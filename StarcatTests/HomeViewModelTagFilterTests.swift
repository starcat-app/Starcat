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

    @Test("我的项目按当前用户加载 Sidebar 计数与未 Star 仓库")
    func myProjectsLoadsForActiveUser() async throws {
        let (vm, _, _, db) = try makeAll()
        try await db.insertRepoFixture(id: 101, owner: "me", name: "private-project")
        try await db.insertRepoFixture(id: 102, owner: "other", name: "other-project")
        try await db.insertRepoFixture(id: 103, owner: "acme", name: "org-tool")
        try await db.writer.write { database in
            try database.execute(
                sql: "UPDATE repos SET is_starred = 0, starred_at = NULL WHERE id = 101"
            )
            try database.execute(
                sql: """
                    INSERT INTO user_projects (
                        user_id, repo_id, affiliation, owner_login, owner_type, visibility,
                        permission, authorization_source, installation_id, generation,
                        last_seen_at, created_at, updated_at
                    ) VALUES
                        (7, 101, 'owner', 'me', 'user', 'private',
                         'admin', 'github_app', NULL, 'g1',
                         '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z'),
                        (8, 102, 'owner', 'other', 'user', 'public',
                         'admin', 'oauth', NULL, 'g1',
                         '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z'),
                        (7, 103, 'organization_member', 'acme', 'organization', 'public',
                         'maintain', 'oauth', NULL, 'g1',
                         '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z')
                    """
            )
        }

        vm.setActiveUserID(7)
        await vm.refreshSidebar()
        vm.selection = .myProjects
        await vm.reloadItems()

        #expect(vm.myProjectsCount == 2)
        #expect(Set(vm.items.map(\.id)) == [101, 103])
        #expect(vm.items.first { $0.id == 101 }?.isStarred == false)
        #expect(vm.projectFilterOptions.organizationLogins == ["acme"])

        vm.projectAffiliationFilter = .organizationMember
        await vm.awaitPendingListReloadForTesting()
        #expect(vm.items.map(\.id) == [103])

        vm.resetAllFilters()
        vm.submitSearch("private")
        await vm.reloadItems()
        #expect(vm.items.map(\.id) == [101])

        vm.resetAllStateForUserSwitch()
        #expect(vm.activeUserID == nil)
        #expect(vm.myProjectsCount == 0)
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
        let projects = SidebarItem.myProjects
        #expect(t.id != l.id)
        #expect(all.id != l.id)
        #expect(library.id != all.id)
        #expect(t.id == "tag.swift")
        #expect(l.id == "language.swift")
        #expect(all.id == "language.all")
        #expect(library.id == "section.library")
        #expect(library.systemImage == "heart.fill")
        #expect(projects.id == "section.myProjects")
        #expect(projects.systemImage == "folder.fill")
        #expect(SidebarItem(persistedRawValue: all.persistedRawValue) == all)
        #expect(SidebarItem(persistedRawValue: library.persistedRawValue) == library)
        #expect(SidebarItem(persistedRawValue: projects.persistedRawValue) == projects)
    }

    @Test("星标三级导航按 Sidebar 分组映射")
    func manageNavigationMapsSidebarGroups() {
        let allStars = ManageNavigationPresentation.make(
            selection: .allStars,
            selectionTitle: String.l10n("sidebar.allRepos"),
            selectedLanguageTitles: [],
            selectedTagTitles: [],
            searchTitle: nil
        )
        #expect(allStars.secondLevelTitle == String.l10n("sidebar.allRepos"))
        #expect(allStars.thirdLevelTitle == String.l10n("general.all"))
        #expect(!allStars.isFilteredScope)

        let untagged = ManageNavigationPresentation.make(
            selection: .untagged,
            selectionTitle: String.l10n("sidebar.untagged"),
            selectedLanguageTitles: [],
            selectedTagTitles: [],
            searchTitle: nil
        )
        #expect(untagged.secondLevelTitle == String.l10n("sidebar.untagged"))
        #expect(untagged.thirdLevelTitle == String.l10n("general.all"))
        #expect(untagged.isFilteredScope)

        let library = ManageNavigationPresentation.make(
            selection: .library,
            selectionTitle: String.l10n("sidebar.library"),
            selectedLanguageTitles: [],
            selectedTagTitles: [],
            searchTitle: nil
        )
        #expect(library.secondLevelTitle == String.l10n("sidebar.library"))
        #expect(library.thirdLevelTitle == String.l10n("general.all"))
        #expect(library.isFilteredScope)

        let projects = ManageNavigationPresentation.make(
            selection: .myProjects,
            selectionTitle: String.l10n("sidebar.myProjects"),
            selectedLanguageTitles: [],
            selectedTagTitles: [],
            searchTitle: nil
        )
        #expect(projects.secondLevelTitle == String.l10n("sidebar.myProjects"))
        #expect(projects.thirdLevelTitle == String.l10n("general.all"))
        #expect(projects.isFilteredScope)

        let collections = ManageNavigationPresentation.make(
            selection: .smartCollectionsHome,
            selectionTitle: String.l10n("smartCollections.title"),
            selectedLanguageTitles: [],
            selectedTagTitles: [],
            searchTitle: nil
        )
        #expect(collections.secondLevelTitle == String.l10n("smartCollections.title"))
        #expect(collections.thirdLevelTitle == String.l10n("smartCollections.all"))
        #expect(!collections.isFilteredScope)
    }

    @Test("语言与多标签属于当前基础仓库范围的第三级细分条件")
    func manageNavigationKeepsLanguageAndTags() {
        let presentation = ManageNavigationPresentation.make(
            selection: .allStars,
            selectionTitle: String.l10n("sidebar.allRepos"),
            selectedLanguageTitles: ["Swift"],
            selectedTagTitles: ["AI", "Tools"],
            searchTitle: nil
        )

        #expect(presentation.secondLevelTitle == String.l10n("sidebar.allRepos"))
        #expect(presentation.thirdLevelTitle == "Swift · AI · Tools")
        #expect(presentation.isFilteredScope)
    }

    @Test("语言筛选不会覆盖全部仓库、未分类和知识库基础范围")
    func manageNavigationKeepsBaseScopeWhenLanguageSelected() {
        let cases: [(SidebarItem, String)] = [
            (.allStars, String.l10n("sidebar.allRepos")),
            (.myProjects, String.l10n("sidebar.myProjects")),
            (.untagged, String.l10n("sidebar.untagged")),
            (.library, String.l10n("sidebar.library"))
        ]

        for (selection, title) in cases {
            let presentation = ManageNavigationPresentation.make(
                selection: selection,
                selectionTitle: title,
                selectedLanguageTitles: ["Java"],
                selectedTagTitles: [],
                searchTitle: nil
            )

            #expect(presentation.secondLevelTitle == title)
            #expect(presentation.thirdLevelTitle == "Java")
            #expect(presentation.isFilteredScope)
        }
    }

    @Test("智能集合固定三级导航，不追加全局语言或标签")
    func smartCollectionNavigationIgnoresGlobalFilterTitles() {
        let cases: [(selection: SidebarItem, title: String, expectedThirdLevel: String, isFiltered: Bool)] = [
            (
                .smartCollectionsHome,
                String.l10n("smartCollections.title"),
                String.l10n("smartCollections.all"),
                false
            ),
            (
                .smartCollection(.library),
                "Knowledge Base",
                "Knowledge Base",
                true
            ),
            (
                .userSmartCollection("custom"),
                "My Collection",
                "My Collection",
                true
            )
        ]

        for item in cases {
            let presentation = ManageNavigationPresentation.make(
                selection: item.selection,
                selectionTitle: item.title,
                selectedLanguageTitles: ["Uncategorized"],
                selectedTagTitles: ["AI"],
                searchTitle: nil
            )

            #expect(presentation.secondLevelTitle == String.l10n("smartCollections.title"))
            #expect(presentation.thirdLevelTitle == item.expectedThirdLevel)
            #expect(presentation.isFilteredScope == item.isFiltered)
        }
    }
}
