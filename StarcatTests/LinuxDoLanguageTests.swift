//
//  LinuxDoLanguageTests.swift
//  StarcatTests
//
//  验证 Linux.do 语言聚合、来源内单选、面包屑和分页，不访问网络或真实用户数据库。
//

import Foundation
import Testing
@testable import Starcat

/// 语言统计与本地匹配必须共享空值、大小写和“其他”的语义，避免计数与列表不一致。
@MainActor
struct LinuxDoLanguageTests {
    /// 同名语言大小写差异不拆行，nil / 空串 / 空白统一归入未分类。
    @Test func aggregatesNormalizedLanguagesWithoutLosingRepositories() async throws {
        let fixture = try await makeLinuxDoFixture(languages: ["Swift", " swift ", "Python", nil, "", "  "])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let key = try #require(fixture.store.catalogKey)
        let languages = fixture.store.languages
        #expect(languages.count == 3)
        #expect(languages.first { $0.key == "Swift" }?.count == 2)
        #expect(languages.first { $0.key == "Python" }?.count == 1)
        #expect(languages.first { $0.key == TrendingLanguage.uncategorizedKey }?.count == 3)
        #expect(languages.reduce(0) { $0 + $1.count } == 6)
        for language in languages {
            let matching = try await fixture.repository.page(key: key, query: LinuxDoCatalogQuery(language: language.key))
            #expect(matching?.total == language.count)
        }
    }

    /// 空缓存与全部有语言的快照都保留未分类零计数入口，不把空缓存解释为另一来源。
    @Test(arguments: [[], ["Rust", "Go"]] as [[String?]])
    func emptyAndFullyClassifiedCatalogsKeepZeroUncategorizedRow(repos: [String?]) async throws {
        let fixture = try await makeLinuxDoFixture(languages: repos)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let languages = fixture.store.languages
        #expect(languages.first { $0.key == TrendingLanguage.uncategorizedKey }?.count == 0)
        #expect(languages.reduce(0) { $0 + $1.count } == repos.count)
    }

    /// “其他”排除未分类和感兴趣语言，来源内单选与全局多选取交集。
    @Test func appliesOtherAndIntersectsGlobalLanguageFilters() async throws {
        let fixture = try await makeLinuxDoFixture(languages: [nil, "", " ", "Swift", "sWiFt", " Python ", "Rust"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let key = try #require(fixture.store.catalogKey)
        let other = LinuxDoCatalogQuery(language: TrendingLanguage.otherRawValue, interestedLanguages: ["Swift", " python "])
        #expect(try await fixture.repository.page(key: key, query: other)?.rows.map(\.repoID) == [7])
        var named = LinuxDoCatalogQuery(language: " swift ")
        #expect(try await fixture.repository.page(key: key, query: named)?.rows.map(\.repoID) == [5, 4])
        named.globalLanguages = ["Python"]
        #expect(try await fixture.repository.page(key: key, query: named)?.total == 0)
        #expect(try await fixture.repository.page(key: key, query: .init())?.total == 7)
    }

    /// 不让普通发现保留的 topic / platform / language 污染 Linux.do 面包屑。
    @Test(arguments: [nil, "", "Swift", TrendingLanguage.uncategorizedKey, TrendingLanguage.otherRawValue] as [String?])
    func navigationKeepsSourceAndReportsLanguageFilter(selection: String?) {
        let result = ExploreNavigationPresentation.make(
            mode: .discover,
            discoverySource: .linuxDo,
            linuxDoLanguage: selection,
            trendingLanguage: .all,
            discoveryLanguage: "Go",
            discoveryTopic: "privacy",
            discoveryPlatform: "macos",
            weeklyLanguage: "Python",
            topics: [],
            platforms: []
        )
        let language = TrendingLanguage(selection ?? "")
        #expect(result.isFiltered == !language.rawValue.isEmpty)
        #expect(result.thirdLevelTitle == (language.rawValue.isEmpty ? "Linux.do" : "Linux.do › \(language.localizedDisplayName)"))
    }

    @Test func otherExploreModesIgnoreLinuxDoLanguageSelection() {
        let result = ExploreNavigationPresentation.make(
            mode: .popular,
            discoverySource: .catalog,
            linuxDoLanguage: "Swift",
            trendingLanguage: .all,
            discoveryLanguage: "Go",
            discoveryTopic: nil,
            discoveryPlatform: nil,
            weeklyLanguage: nil,
            topics: [],
            platforms: []
        )
        #expect(result.thirdLevelTitle == "Go")
        #expect(result.isFiltered)
    }

    /// 语言变化重新从首批 20 项开始；即使两次结果都为空，也保留不同的分页身份。
    @Test func changingLanguageResetsLoadedPagesAndEmptyCategoryIdentity() async throws {
        let fixture = try await makeLinuxDoFixture(languages: Array(repeating: "Swift", count: 70) + Array(repeating: "Rust", count: 25))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let key = try #require(fixture.store.catalogKey)
        let model = LinuxDoListModel()
        for (language, count) in [("Swift", 70), ("Rust", 25), ("Python", 0), ("Go", 0)] {
            let request = LinuxDoListRequest(key: key, query: LinuxDoListQuery(base: .init(language: language)))
            await model.update(request, store: fixture.store)
            #expect(model.total == count)
            #expect(model.rows.count == min(20, count))
            #expect(model.request == request)
            if language == "Swift" {
                await model.loadMore(requested: request, store: fixture.store)
                #expect(model.rows.count == 40)
            }
        }
        #expect(model.rows.isEmpty)
        #expect(!model.hasMore)
    }

    /// 回切复用已加载页。服务发布新版本时更新原已读范围，并保留动画与滚动身份。
    @Test func sameQueryReusesPreparedRowsAndLoadedPages() async throws {
        let fixture = try await makeLinuxDoFixture(languages: Array(repeating: "Swift", count: 95))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let key = try #require(fixture.store.catalogKey)
        let query = LinuxDoListQuery(base: .init(language: "Swift"))
        let request = LinuxDoListRequest(key: key, query: query)
        let model = LinuxDoListModel()
        var preparations = 0
        func prepare() -> [LinuxDoRepoMembership] {
            preparations += 1
            return []
        }
        await model.update(request, store: fixture.store, prepareMemberships: prepare)
        await model.loadMore(requested: request, store: fixture.store)
        model.scrollAnchor = model.rows[24].repoID
        let loadedIDs = model.rows.map(\.repoID)
        await model.update(request, store: fixture.store, prepareMemberships: prepare)
        #expect(preparations == 1)
        #expect(model.rows.map(\.repoID) == loadedIDs)
        #expect(model.rows.count == 40)
        #expect(model.hasMore)

        let updated = try makeLinuxDoCatalog(languages: Array(repeating: "Swift", count: 94), revision: 2)
        await fixture.api.setResponse(LinuxDoResponse(payload: updated, etag: "catalog-v2"))
        await fixture.store.refreshCatalog(force: true)
        let nextKey = try #require(fixture.store.catalogKey)
        let nextRequest = LinuxDoListRequest(key: nextKey, query: query)
        await model.update(nextRequest, store: fixture.store, prepareMemberships: prepare)
        #expect(preparations == 2)
        #expect(model.rows.count == 40)
        #expect(model.total == 94)
        #expect(model.scrollAnchor == loadedIDs[24])
        #expect(model.request?.presentationID == request.presentationID)
        await model.loadMore(requested: request, store: fixture.store)
        #expect(model.rows.count == 40)
    }

    /// 搜索与排序变化必须失效旧结果，推广时间排序不能被星标排序缓存覆盖。
    @Test func searchSortAndExternalMembershipRunBeforePagination() async throws {
        let fixture = try await makeLinuxDoFixture(languages: Array(repeating: "Swift", count: 95),
                                                  promotions: ["1": "2026-11-17T00:00:00Z"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let key = try #require(fixture.store.catalogKey)
        #expect(try await fixture.repository.page(key: key, query: .init())?.rows.first?.repoID == 1)
        #expect(try await fixture.repository.page(key: key, query: .init(recentPromotionFirst: false))?.rows.first?.repoID == 95)
        let membership = LinuxDoRepoMembership(ids: [2], includes: true)
        let search = LinuxDoCatalogQuery(search: "REPO-1", recentPromotionFirst: false)
        let page = try #require(try await fixture.repository.page(key: key, query: search, memberships: [membership]))
        #expect(page.rows.map(\.repoID) == [2])
        #expect(page.total == 1)
    }
}
