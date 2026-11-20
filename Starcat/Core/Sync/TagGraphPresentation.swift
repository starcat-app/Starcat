// 搜索不筛掉画布中的节点或连线。
import Foundation
import GRDB

extension TagGraphSnapshot {
    /// 图谱规模可达数千仓库，浮层只需收集最先匹配的少量结果。
    func matchingNodes(_ search: String, limit: Int = 20) -> [TagGraphNode] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return Array(nodes.lazy.filter { $0.name.localizedStandardContains(needle) }.prefix(limit))
    }
}

/// 账户内的轻量归属索引，在 GRDB 读队列构建。只有当前展示页和点选资料会进入界面。
struct TagGraphPresentationIndex: Equatable, Sendable {
    let graph: TagGraphSnapshot
    let tags: [TagGraphNode]
    let nodesByID: [String: TagGraphNode]
    let membersByTag: [String: [TagGraphEdge]]
    let tagDates: [String: Date]

    init(graph: TagGraphSnapshot, tagDates: [String: Date] = [:]) {
        self.graph = graph
        self.tagDates = tagDates
        tags = graph.nodes.filter { $0.kind == .tag }
        nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        membersByTag = Dictionary(grouping: graph.edges, by: \.source)
    }

    static func read(in db: Database) throws -> Self {
        let graph = try TagGraphQuery.snapshot(in: db, sortByRecentStar: true)
        let rows = try Row.fetchAll(db, sql: "SELECT id, datetime(created_at) AS created FROM tags")
        let dates = rows.reduce(into: [String: Date]()) { dates, row in
            let id: String = row["id"]
            dates["tag:" + id] = row["created"]
        }
        return Self(graph: graph, tagDates: dates)
    }
}
