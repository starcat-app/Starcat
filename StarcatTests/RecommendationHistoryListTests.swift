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

    @Test("万条历史分页完整且无重复，查询变化恢复首屏并清除不可见选择")
    func largeHistoryPaginationAndQueryReset() {
        let model = RecommendationHistoryListModel()
        let entries = (1...10_050).reversed().map { entry(Int64($0)) }
        model.rebuild(entries: entries, starredIDs: [])
        #expect(model.rows.count == 100)
        #expect(model.rows.first?.id == 10_050)
        let identity = model.paginationIdentity
        for _ in 0..<100 { model.loadMore() }
        #expect(model.rows.map(\.id) == entries.map(\.id))
        #expect(Set(model.rows.map(\.id)).count == entries.count)
        #expect(!model.hasMore)
        model.loadMore()
        #expect(model.rows.count == entries.count)
        #expect(model.paginationIdentity == identity)
        model.selectedID = 10_000
        model.filter = .starred
        let starredIDs = Set((1...450).map(Int64.init))
        model.rebuild(entries: entries, starredIDs: starredIDs)
        #expect(model.filtered.count == 450)
        #expect(model.rows.count == 100)
        #expect(model.rows.first?.id == 450)
        #expect(model.selectedID == nil)
        #expect(model.paginationIdentity != identity)
        model.loadMore()
        #expect(model.rows.count == 200)
        model.filter = .all
        model.search = "repo9999"
        model.rebuild(entries: entries, starredIDs: starredIDs)
        #expect(model.rows.map(\.id) == [9999])
        #expect(model.visibleLimit == 100)
        #expect(!model.hasMore)
    }

    @Test("相同 ID 的内容和反馈刷新当前页，保留已加载范围与有效选择")
    func sameIDsRefreshVisibleContent() {
        let model = RecommendationHistoryListModel()
        var entries = (1...350).map { entry(Int64($0)) }
        model.rebuild(entries: entries, starredIDs: [])
        model.loadMore()
        model.selectedID = 150
        let identity = model.paginationIdentity
        let revision = model.revision
        entries[149] = entry(150, dismissed: true, description: "Updated project description")
        model.rebuild(entries: entries, starredIDs: [])
        #expect(model.rows.count == 200)
        #expect(model.rows[149].item?.description == "Updated project description")
        #expect(model.rows[149].isDismissed)
        #expect(model.selectedEntry?.isDismissed == true)
        #expect(model.selectedID == 150)
        #expect(model.paginationIdentity == identity)
        #expect(model.revision == revision)
        model.filter = .dismissed
        model.rebuild(entries: entries, starredIDs: [])
        #expect(model.rows.map(\.id) == [150])
        #expect(model.selectedID == 150)
        entries[149] = entry(150)
        model.rebuild(entries: entries, starredIDs: [])
        #expect(model.rows.isEmpty)
        #expect(model.selectedID == nil)
    }

    private func entry(
        _ id: Int64, dismissed: Bool = false, description: String = "Offline description"
    ) -> RecommendationHistoryEntry {
        RecommendationHistoryEntry(id: id, item: item(id, description: description), recommendedAt: nil,
                                   recommendedDay: "2026-11-15", batchID: nil, isDismissed: dismissed)
    }

    private func item(_ id: Int64, description: String) -> RepoRecommendationItem {
        RepoRecommendationItem(repoID: id, fullName: "owner/repo\(id)", description: description,
                               language: "Swift", stars: 10, forks: 1, archived: false,
                               score: 0.5, source: "starcat_trained", reasons: ["costar"])
    }
}
