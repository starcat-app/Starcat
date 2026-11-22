//
//  RecommendationHistoryListModel.swift
//  Starcat
//
//  窗口会话内保存历史查询、选择与本地分页，不把历史塞入星标管理集合。
//

import Foundation
import Observation

/// 完整历史用于去重，列表只发布当前页；来源/查询变化时重置分页，反馈刷新保留已加载范围。
@MainActor
@Observable
final class RecommendationHistoryListModel {
    var search = ""
    var filter: RecommendationHistoryFilter = .all
    var dateScope: RecommendationHistoryDateScope = .all
    var selectedID: Int64?
    private(set) var filtered: [RecommendationHistoryEntry] = []
    /// 当前页只在数据或分页变化时重建；每行读取分页计数不能再次复制整页数组。
    private(set) var rows: [RecommendationHistoryEntry] = []
    private(set) var visibleLimit = ListPaginationPolicy.repoCardPageSize
    private(set) var revision = 0
    private(set) var paginationIdentity = UUID()
    private var scope = ""
    private var lastQuery = ""
    private var didPrepareHistory = false

    var hasMore: Bool { visibleLimit < filtered.count }
    var selectedEntry: RecommendationHistoryEntry? { filtered.first { $0.id == selectedID } }

    func hasPreparedHistory(for scope: String) -> Bool {
        self.scope == scope && didPrepareHistory
    }

    /// 切账号即清查询和选择；不让旧详情留到新库返回后才消失。
    func activate(scope: String) {
        guard self.scope != scope else { return }
        self.scope = scope
        search = ""
        filter = .all
        dateScope = .all
        selectedID = nil
        filtered = []
        rows = []
        visibleLimit = ListPaginationPolicy.repoCardPageSize
        lastQuery = ""
        didPrepareHistory = false
        paginationIdentity = UUID()
        revision &+= 1
    }

    /// 首次推荐日、搜索与反馈共同筛选；保持仓储顺序，不混入其它探索模式的语言/分类。
    func rebuild(entries: [RecommendationHistoryEntry], starredIDs: Set<Int64>) {
        let previousIDs = filtered.map(\.id)
        let query = QuickSearchTextMatcher.normalized(search)
        let identity = "\(dateScope.identity)|\(filter.rawValue)|\(query)"
        if lastQuery != identity {
            visibleLimit = ListPaginationPolicy.repoCardPageSize
            lastQuery = identity
            paginationIdentity = UUID()
        }
        filtered = entries.filter { entry in
            guard dateScope.includes(entry) else { return false }
            guard filter == .all || entry.feedback(starredIDs: starredIDs) == filter else { return false }
            guard !query.isEmpty else { return true }
            let text = [entry.item?.fullName, entry.item?.description, entry.item?.language, String(entry.id)]
                .compactMap { $0 }.joined(separator: " ")
            return text.localizedStandardContains(query)
        }
        if let selectedID, !filtered.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        if filtered.map(\.id) != previousIDs { revision &+= 1 }
        // ID 相同也可能更新简介或反馈，不能只按 ID 变化刷新页面内容。
        refreshRows()
        didPrepareHistory = true
    }

    /// 追加当前筛选的下一页，保留选择和分页身份。
    func loadMore() {
        guard hasMore else { return }
        let nextRows = filtered.dropFirst(rows.count).prefix(ListPaginationPolicy.repoCardPageSize)
        visibleLimit += ListPaginationPolicy.repoCardPageSize
        rows.append(contentsOf: nextRows)
    }

    private func refreshRows() {
        rows = Array(filtered.prefix(visibleLimit))
    }
}
