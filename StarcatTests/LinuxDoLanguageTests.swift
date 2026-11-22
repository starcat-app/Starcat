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
    @Test func aggregatesNormalizedLanguagesWithoutLosingRepositories() throws {
        let repos = try repositories(["Swift", " swift ", "Python", nil, "", "  "])
        let languages = LinuxDoStore.languageAggregates(in: repos)
        #expect(languages.count == 3)
        #expect(languages.first { $0.key == "Swift" }?.count == 2)
        #expect(languages.first { $0.key == "Python" }?.count == 1)
        #expect(languages.first { $0.key == TrendingLanguage.uncategorizedKey }?.count == 3)
        #expect(languages.reduce(0) { $0 + $1.count } == repos.count)
        for language in languages {
            let matching = repos.filter {
                LinuxDoStore.matchesLanguage($0.language, selection: language.key, interestedLanguages: [])
            }
            #expect(matching.count == language.count)
        }
    }

    /// 空缓存与全部有语言的快照都保留未分类零计数入口，不把空缓存解释为另一来源。
    @Test func emptyAndFullyClassifiedCatalogsKeepZeroUncategorizedRow() throws {
        let empty = LinuxDoStore.languageAggregates(in: [])
        #expect(empty.map(\.key) == [TrendingLanguage.uncategorizedKey])
        #expect(empty.first?.count == 0)
        let languages = LinuxDoStore.languageAggregates(in: try repositories(["Rust", "Go"]))
        #expect(languages.first { $0.key == TrendingLanguage.uncategorizedKey }?.count == 0)
        #expect(languages.reduce(0) { $0 + $1.count } == 2)
    }

    @Test(arguments: [nil, "", "Rust", " Swift "] as [String?])
    func allLanguagesDoesNotExcludeUnknownLanguages(language: String?) {
        #expect(LinuxDoStore.matchesLanguage(language, selection: nil, interestedLanguages: ["Swift"]))
        #expect(LinuxDoStore.matchesLanguage(language, selection: "", interestedLanguages: []))
    }

    @Test(arguments: [nil, "", "  ", "Swift"] as [String?])
    func uncategorizedMatchesOnlyEmptyMainLanguage(language: String?) {
        let expected = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect(LinuxDoStore.matchesLanguage(language, selection: TrendingLanguage.uncategorizedKey, interestedLanguages: []) == expected)
    }

    /// “其他”不能吞掉未分类，也不能把大小写不同的感兴趣语言当成新语言。
    @Test(arguments: [nil, "", "  ", "Swift", "sWiFt", " Python ", "Rust"] as [String?])
    func otherUsesInterestedLanguagesRatherThanGlobalSelection(language: String?) {
        let expected = language == "Rust"
        #expect(LinuxDoStore.matchesLanguage(language, selection: TrendingLanguage.otherRawValue, interestedLanguages: ["Swift", " python "]) == expected)
    }

    @Test func namedLanguageAndInterestChangesAreAppliedLocally() {
        #expect(LinuxDoStore.matchesLanguage(" Swift ", selection: "sWiFt", interestedLanguages: []))
        #expect(!LinuxDoStore.matchesLanguage(nil, selection: "Swift", interestedLanguages: []))
        #expect(!LinuxDoStore.matchesLanguage("Python", selection: "Swift", interestedLanguages: []))
        #expect(LinuxDoStore.matchesLanguage("Rust", selection: TrendingLanguage.otherRawValue, interestedLanguages: []))
        #expect(!LinuxDoStore.matchesLanguage("Rust", selection: TrendingLanguage.otherRawValue, interestedLanguages: ["rust"]))
    }

    /// 来源内单选与 toolbar 全局多选取交集；选择侧栏语言不能清空全局筛选。
    @Test func localLanguageSelectionIntersectsWithGlobalLanguages() throws {
        let repos = try repositories(["Swift", "Python", "Rust", nil])
        let local = repos.filter {
            LinuxDoStore.matchesLanguage($0.language, selection: "Swift", interestedLanguages: ["Swift"])
        }
        let globalLanguages = ["Python"]
        let intersection = local.filter { repo in
            globalLanguages.contains { $0.caseInsensitiveCompare(repo.language ?? "") == .orderedSame }
        }
        #expect(local.map(\.language) == ["Swift"])
        #expect(intersection.isEmpty)
        #expect(globalLanguages == ["Python"])
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
    @Test func changingLanguageResetsLoadedPagesAndEmptyCategoryIdentity() throws {
        let repos = try repositories(Array(repeating: "Swift", count: 70) + Array(repeating: "Rust", count: 25))
        let model = LinuxDoListModel()
        for language in ["Swift", "Rust", "Python", "Go"] {
            let matching = repos.filter {
                LinuxDoStore.matchesLanguage($0.language, selection: language, interestedLanguages: [])
            }
            model.reset(repositories: matching, promotionDates: [:], search: "", recentPromotionFirst: false, identity: "linuxdo:\(language)")
            #expect(model.total == matching.count)
            #expect(model.rows.count == min(20, matching.count))
            #expect(model.identity == "linuxdo:\(language)")
            if language == "Swift" {
                model.loadMore()
                #expect(model.rows.count == 40)
            }
        }
        #expect(model.rows.isEmpty)
        #expect(!model.hasMore)
    }

    /// 分类回切保持窗口内已加载页；使用带计数的输入确认命中时连全量筛选也不会执行。
    @Test func sameQueryReusesPreparedRowsAndLoadedPages() throws {
        let repos = try repositories(Array(repeating: "Swift", count: 95))
        let model = LinuxDoListModel()
        var preparations = 0
        func prepare() -> [DiscoveryRepoDTO] {
            preparations += 1
            return repos
        }
        model.reset(repositories: prepare(), promotionDates: [:], search: "", recentPromotionFirst: false, identity: "provider:7:Swift")
        model.loadMore()
        let loadedIDs = model.rows.map(\.repoID)
        model.reset(repositories: prepare(), promotionDates: [:], search: "", recentPromotionFirst: false, identity: "provider:7:Swift")
        #expect(preparations == 1)
        #expect(model.rows.map(\.repoID) == loadedIDs)
        #expect(model.rows.count == 40)
        #expect(model.hasMore)

        model.reset(repositories: prepare(), promotionDates: [:], search: "", recentPromotionFirst: false, identity: "provider:8:Swift")
        #expect(preparations == 2)
        #expect(model.rows.count == 20)
        #expect(model.total == 95)
    }

    /// 搜索与排序变化必须失效旧结果，推广时间排序不能被星标排序缓存覆盖。
    @Test func changedQueryRebuildsSearchAndPromotionOrder() throws {
        let repos = try repositories(["Swift", "Rust", "Go"])
        let model = LinuxDoListModel()
        let dates = ["1": "2026-11-17T00:00:00Z"]
        model.reset(repositories: repos, promotionDates: dates, search: "", recentPromotionFirst: false, identity: "stars")
        #expect(model.rows.map(\.repoID) == [3, 2, 1])
        model.reset(repositories: repos, promotionDates: dates, search: "", recentPromotionFirst: true, identity: "promoted")
        #expect(model.rows.map(\.repoID) == [1, 3, 2])
        model.reset(repositories: repos, promotionDates: dates, search: "repo-1", recentPromotionFirst: true, identity: "promoted:repo-1")
        #expect(model.rows.map(\.repoID) == [2])
        #expect(model.total == 1)
        #expect(!model.hasMore)
    }

    /// 通过现有 API 解码契约生成最小公开仓库样本，不依赖生产目录的数量或语言分布。
    private func repositories(_ languages: [String?]) throws -> [DiscoveryRepoDTO] {
        try languages.enumerated().map { index, language in
            var object: [String: Any] = [
                "repo_id": index + 1, "owner": "test", "name": "repo-\(index)",
                "full_name": "test/repo-\(index)", "stars": index, "forks": 0,
                "watchers": 0, "subscribers": 0, "open_issues": 0,
                "is_archived": false, "is_fork": false, "release_download_count": 0,
            ]
            if let language { object["language"] = language }
            return try JSONDecoder().decode(DiscoveryRepoDTO.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
}
