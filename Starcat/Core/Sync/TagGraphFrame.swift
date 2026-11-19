// 当前账户的画布、选中关系与仓库证据共享一次 GRDB 读取。
import Foundation
import GRDB

/// 节点和无向边使用数据库 ID，改名不会丢失选择。
enum TagGraphSelection: Equatable, Sendable {
    case node(String)
    case edge(TagGraphPair)

    var tagIDs: Set<String> {
        switch self {
        case .node(let id): [id]
        case .edge(let pair): [pair.leftID, pair.rightID]
        }
    }

    func exists(in graph: TagGraphSnapshot) -> Bool {
        switch self {
        case .node(let id): graph.nodes.contains { $0.id == id }
        case .edge(let pair): graph.edges.contains { $0.id == pair }
        }
    }
}

/// 数据库观察同时跟踪图谱和选中页，边权相同时也能观察到成员替换。
struct TagGraphFrame: Sendable {
    let graph: TagGraphSnapshot
    let page: RepoTagIntersectionPage?
    let offset: Int

    static func read(in db: Database, selection: TagGraphSelection?, offset: Int, limit: Int) throws -> Self {
        let graph = try TagGraphQuery.snapshot(in: db)
        guard let selection, selection.exists(in: graph) else {
            return Self(graph: graph, page: nil, offset: 0)
        }
        let page = try RepoTagIntersection.page(in: db, tagIDs: selection.tagIDs, limit: limit, offset: offset)
        // 最后一页被删空时直接返回新的末页，保持页码和内容一致。
        if offset > 0, offset >= page.total {
            let last = max(0, page.total - 1) / limit * limit
            return Self(graph: graph, page: try RepoTagIntersection.page(in: db, tagIDs: selection.tagIDs,
                                                                       limit: limit, offset: last), offset: last)
        }
        return Self(graph: graph, page: page, offset: offset)
    }
}
