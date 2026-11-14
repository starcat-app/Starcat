//
//  RecommendationHistoryListTests.swift
//  StarcatTests
//
//  验证历史列表查询、选择与本地分页；不创建窗口或请求网络。
//

import Foundation
import Testing
@testable import Starcat

/// 列表会话独立于共享历史数据，切换覆盖层不重置本窗口查询。
@Suite("推荐历史列表")
@MainActor
struct RecommendationHistoryListTests {
    @Test("历史筛选按真实 Star 与主动反馈分类，搜索匹配仓库名和简介")
    func listFeedbackAndSearch() {
        let model = RecommendationHistoryListModel()
        let entries = [
            entry(10, dismissed: true), entry(11), entry(12, dismissed: true)
        ]
        model.rebuild(entries: entries, starredIDs: [10])
        #expect(model.rows.map(\.id) == [10, 11, 12])
        model.selectedID = 10
        model.filter = .starred
        model.rebuild(entries: entries, starredIDs: [10])
        #expect(model.rows.map(\.id) == [10])
        #expect(model.selectedID == 10)
        model.filter = .unanswered
        model.rebuild(entries: entries, starredIDs: [10])
        #expect(model.rows.map(\.id) == [11])
        #expect(model.selectedID == nil)
        model.filter = .dismissed
        model.rebuild(entries: entries, starredIDs: [10])
        #expect(model.rows.map(\.id) == [12])
        model.filter = .all
        model.search = "repo11"
        model.rebuild(entries: entries, starredIDs: [])
        #expect(model.rows.map(\.id) == [11])
        model.search = "offline"
        model.rebuild(entries: entries, starredIDs: [])
        #expect(model.rows.count == 3)
    }

    @Test("本地分页按查询重置，默认全部反馈变更保留选择，换账号立即清空")
    func listPaginationAndSelection() {
        let model = RecommendationHistoryListModel()
        model.activate(scope: "42|1")
        let entries = (1...250).reversed().map { entry(Int64($0)) }
        model.rebuild(entries: entries, starredIDs: [])
        #expect(model.rows.count == 100)
        model.loadMore()
        #expect(model.rows.count == 200)
        model.selectedID = 200
        let identity = model.paginationIdentity
        let revision = model.revision
        model.rebuild(entries: entries, starredIDs: [200])
        #expect(model.selectedID == 200)
        #expect(model.rows.count == 200)
        #expect(model.paginationIdentity == identity)
        #expect(model.revision == revision)
        model.search = "repo2"
        model.rebuild(entries: entries, starredIDs: [200])
        #expect(model.visibleLimit == 100)
        #expect(model.paginationIdentity != identity)
        model.activate(scope: "99|2")
        #expect(model.selectedID == nil)
        #expect(model.rows.isEmpty)
        #expect(model.search.isEmpty)
        #expect(model.filter == .all)
    }

    private func entry(_ id: Int64, dismissed: Bool = false) -> RecommendationHistoryEntry {
        RecommendationHistoryEntry(id: id, item: item(id), recommendedAt: nil,
                                   recommendedDay: "2026-11-15", batchID: nil, isDismissed: dismissed)
    }

    private func item(_ id: Int64) -> RepoRecommendationItem {
        RepoRecommendationItem(repoID: id, fullName: "owner/repo\(id)", description: "Offline description",
                               language: "Swift", stars: 10, forks: 1, archived: false,
                               score: 0.5, source: "starcat_trained", reasons: ["costar"])
    }
}
