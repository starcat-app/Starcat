//
//  FollowGraphModel.swift
//  Starcat
//
//  可重建的双方向关系快照与纯图算法。使用数值用户 ID 作为跨 REST / GraphQL 的
//  共同身份，用户名只用于查询和展示；分页完整性不能从 totalCount 推断。
//

import Foundation

/// 探索方向与真实关注边分离：followers 沿入边查找，边本身永远是关注者指向被关注者。
enum FollowGraphRelation: String, Codable, CaseIterable, Sendable {
    case following, followers

    var ownerKey: KeyPath<FollowGraphEdge, String> { self == .following ? \.source : \.target }
    var neighborKey: KeyPath<FollowGraphEdge, String> { self == .following ? \.target : \.source }
    var defaultSampleCount: Int { self == .following ? 20 : 0 }
    var titleKey: String { self == .following ? "sidebar.stats.following" : "sidebar.stats.followers" }

    func edge(owner: String, neighbor: String) -> FollowGraphEdge {
        self == .following ? .init(source: owner, target: neighbor) : .init(source: neighbor, target: owner)
    }
}

/// 图谱只保留展示与查询所需的公开资料，不保存凭据。
struct FollowGraphNode: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var login: String
    var name: String?
    var avatarURL: String?
}

/// 边的身份不包含采集时间，否则重试会生成重复关系。
struct FollowGraphEdge: Codable, Hashable, Sendable {
    let source: String
    let target: String
}

/// 单个用户的分页状态；刷新未读到末页时保留旧关系。
struct FollowGraphProgress: Codable, Equatable, Sendable {
    var cursor: String?
    var complete = false
    var totalCount = 0
    var fetchedAt: Date?
}

/// 二维视口只保存图坐标中心与缩放，拒绝旧三维相机或不合法的页面消息。
struct FollowGraphViewport: Equatable {
    let x: Double
    let y: Double
    let zoom: Double

    /// 范围与 Canvas 的 minZoom / maxZoom 保持一致，不能让异常值进入视图变换。
    init?(values: [Double]) {
        guard values.count == 3, values.allSatisfy(\.isFinite),
              abs(values[0]) < 1_000_000, abs(values[1]) < 1_000_000,
              (0.05...8).contains(values[2]) else { return nil }
        x = values[0]
        y = values[1]
        zoom = values[2]
    }

    var values: [Double] { [x, y, zoom] }
}

/// 账户隔离快照。界面选择与视口只在同一会话保留，不污染关系数据。
struct FollowGraphSnapshot: Codable, Equatable, Sendable {
    let relation: FollowGraphRelation
    var formatVersion = 1
    let accountID: String
    let rootID: String
    var nodes: [String: FollowGraphNode]
    var edges: Set<FollowGraphEdge> = []
    var progress: [String: FollowGraphProgress] = [:]
    var savedAt = Date()

    init(root: FollowGraphNode, relation: FollowGraphRelation = .following) {
        self.relation = relation
        accountID = root.id
        rootID = root.id
        nodes = [root.id: root]
    }

    private enum CodingKeys: String, CodingKey {
        case relation, formatVersion, accountID, rootID, nodes, edges, progress, savedAt
    }

    /// 已发布的旧快照没有方向字段，仅解释为 following，绝不当成 followers 数据。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        relation = try values.decodeIfPresent(FollowGraphRelation.self, forKey: .relation) ?? .following
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        accountID = try values.decode(String.self, forKey: .accountID)
        rootID = try values.decode(String.self, forKey: .rootID)
        nodes = try values.decode([String: FollowGraphNode].self, forKey: .nodes)
        edges = try values.decode(Set<FollowGraphEdge>.self, forKey: .edges)
        progress = try values.decode([String: FollowGraphProgress].self, forKey: .progress)
        savedAt = try values.decode(Date.self, forKey: .savedAt)
    }

    func relationCount(for id: String) -> Int {
        edges.filter { $0[keyPath: relation.ownerKey] == id }.count
    }

    /// 磁盘是关系缓存，不代表每次打开都要绘制全部缓存。following 保留本人关注对象和每人
    /// 20 个二层样本；followers 只默认展示首层；手动展开只增加对应源的预算，不删除磁盘中已取得的关系。
    func presentation(expanded: [String: Int] = [:], selectedID: String? = nil) -> FollowGraphSnapshot {
        let outgoing = Dictionary(grouping: edges, by: { $0[keyPath: relation.ownerKey] })
        func targets(_ source: String) -> [String] {
            (outgoing[source] ?? []).map { $0[keyPath: relation.neighborKey] }.sorted {
                if let a = Int64($0), let b = Int64($1) { return a < b }
                return $0 < $1
            }
        }
        let firstLevel = targets(rootID)
        var visible = Set(firstLevel).union([rootID])
        // 取消直接关注后，仍可达的选中用户和新路径不能被二层样本预算隐藏。
        if let selectedID { visible.formUnion(path(to: selectedID)) }
        let limit = min(10_000, max(5_000, visible.count) + expanded.values.reduce(0, +))
        for source in firstLevel {
            for id in targets(source).prefix(expanded[source] ?? relation.defaultSampleCount) where visible.count < limit {
                visible.insert(id)
            }
        }
        // 显式展开的二层及更深节点必须先可达，孤立的旧会话选择不能重新引入分量。
        var pending = Set(expanded.keys).subtracting(firstLevel).subtracting([rootID])
        while let source = pending.sorted().first(where: { visible.contains($0) }) {
            pending.remove(source)
            for id in targets(source).prefix(expanded[source] ?? 0) where visible.count < limit {
                visible.insert(id)
            }
        }
        var result = self
        result.nodes = nodes.filter { visible.contains($0.key) }
        // 可见节点之间的已知入边 / 出边全部保留，避免人为隐藏交叉关系。
        result.edges = edges.filter { visible.contains($0.source) && visible.contains($0.target) }
        result.progress = progress.filter { visible.contains($0.key) }
        let visibleOutgoing = Dictionary(grouping: result.edges, by: { $0[keyPath: relation.ownerKey] })
        for id in result.progress.keys where (visibleOutgoing[id]?.count ?? 0) < (outgoing[id]?.count ?? 0) {
            result.progress[id]?.complete = false
        }
        return result
    }

    /// 只有完整刷新成功才替换当前方向的旧边；失败、限流、预算中止不能删除旧边。
    mutating func merge(_ page: FollowGraphPage, replacing: Set<String>? = nil) {
        nodes[page.source.id] = page.source
        for node in page.nodes { nodes[node.id] = node }
        if let replacing {
            edges = edges.filter { $0[keyPath: relation.ownerKey] != page.source.id }
            for id in replacing where id != page.source.id {
                edges.insert(relation.edge(owner: page.source.id, neighbor: id))
            }
        } else {
            for node in page.nodes where node.id != page.source.id {
                edges.insert(relation.edge(owner: page.source.id, neighbor: node.id))
            }
        }
        progress[page.source.id] = .init(
            cursor: page.cursor, complete: !page.hasNextPage,
            totalCount: page.totalCount, fetchedAt: Date()
        )
        savedAt = Date()
    }

    /// 只在远端关注操作成功后使用；取消关注不删除仍经其他路径可达的用户。
    mutating func setFollowing(_ following: Bool, node: FollowGraphNode) {
        guard node.id != rootID, relation == .following || nodes[node.id] != nil else { return }
        let edge = FollowGraphEdge(source: rootID, target: node.id)
        let wasFollowing = edges.contains(edge)
        if following {
            nodes[node.id] = node
            edges.insert(edge)
        } else {
            edges.remove(edge)
            pruneUnreachable()
        }
        // followers 的 root 分页统计入边；本人关注操作只影响被关注节点的入边统计。
        let owner = relation == .following ? rootID : node.id
        if progress[owner]?.complete == true {
            let count = relationCount(for: owner)
            progress[owner]?.totalCount = count
        } else if wasFollowing != following, let total = progress[owner]?.totalCount {
            progress[owner]?.totalCount = max(0, total + (following ? 1 : -1))
        }
        savedAt = Date()
    }

    /// 排序后 BFS 保证等长路径稳定，并用 visited 正确处理互相关注和环路。
    func paths() -> [String: String] {
        let adjacency = Dictionary(grouping: edges, by: { $0[keyPath: relation.ownerKey] })
        var parents: [String: String] = [:]
        var visited: Set<String> = [rootID]
        var queue = [rootID]
        var index = 0
        while index < queue.count {
            let source = queue[index]
            index += 1
            let targets = (adjacency[source] ?? []).map { $0[keyPath: relation.neighborKey] }.sorted {
                if let a = Int64($0), let b = Int64($1) { return a < b }
                return $0 < $1
            }
            for target in targets where visited.insert(target).inserted {
                parents[target] = source
                queue.append(target)
            }
        }
        return parents
    }

    func path(to target: String) -> [String] {
        if target == rootID { return [rootID] }
        let parents = paths()
        guard parents[target] != nil else { return [] }
        var result = [target]
        while let parent = parents[result.last!] { result.append(parent) }
        return relation == .following ? result.reversed() : result
    }

    /// 刷新最终成功后只保留根可达节点；不在部分分页期间执行。
    mutating func pruneUnreachable() {
        let reachable = Set(paths().keys).union([rootID])
        nodes = nodes.filter { reachable.contains($0.key) }
        edges = edges.filter { reachable.contains($0.source) && reachable.contains($0.target) }
        progress = progress.filter { reachable.contains($0.key) }
    }
}

/// 网络层交给图层的完整单页；rate limit 来自 GraphQL 自身配额。
struct FollowGraphPage: Sendable {
    let source: FollowGraphNode
    let nodes: [FollowGraphNode]
    let cursor: String?
    let hasNextPage: Bool
    let totalCount: Int
    let remaining: Int
    let resetAt: String
}

/// 独立协议让调度器测试无需 Keychain、真实网络或登录账号。
protocol FollowGraphProviding: Sendable {
    func page(login: String, cursor: String?, count: Int) async throws -> FollowGraphPage
}
