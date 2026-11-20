// 从当前账户的数据库读取标签、已打标签的 Star 仓库及真实归属。
import GRDB

/// 类型前缀让数据库中的标签 ID 和仓库 ID 安全地共用同一张画布。
struct TagGraphNode: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case tag, repo }

    let id: String
    let kind: Kind
    let name: String
    var color: String? = nil
    var icon: String? = nil
    var avatarURL: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, kind, name, color, icon
        case avatarURL = "avatar_url"
    }
}

/// 端点顺序仅用于稳定传输。画布将成员关系视为无向连接。
struct TagGraphEdge: Codable, Equatable, Sendable {
    let source: String
    let target: String
}

struct TagGraphSnapshot: Equatable, Sendable {
    let nodes: [TagGraphNode]
    let edges: [TagGraphEdge]
}

/// 调用方使用同一次 read 或观察事务，避免更新期间出现游离的边。
enum TagGraphQuery {
    static func snapshot(in db: Database, sortByRecentStar: Bool = false) throws -> TagGraphSnapshot {
        let tags = try Row.fetchAll(db, sql: """
            SELECT id, name, color, icon FROM tags ORDER BY id
            """).map { row in
            TagGraphNode(id: "tag:" + row["id"], kind: .tag, name: row["name"],
                         color: row["color"], icon: row["icon"])
        }
        // EXISTS keeps one node per repository, regardless of how many tags it carries.
        let repos = try Row.fetchAll(db, sql: """
            SELECT r.id, r.full_name, r.owner_avatar
            FROM repos AS r
            WHERE r.is_starred = 1 AND EXISTS (SELECT 1 FROM repo_tags WHERE repo_id = r.id)
            ORDER BY r.id
            """).map { row in
            let id: Int64 = row["id"]
            return TagGraphNode(id: "repo:\(id)", kind: .repo, name: row["full_name"], avatarURL: row["owner_avatar"])
        }
        // The CLI/MCP page order stays unchanged. Only the visual index starts with recently starred repos.
        let order = sortByRecentStar ? "r.starred_at DESC, rt.repo_id, rt.tag_id" : "rt.repo_id, rt.tag_id"
        // (repo_id, tag_id) is the membership primary key. Each row becomes exactly one edge.
        let edges = try Row.fetchAll(db, sql: """
            SELECT rt.repo_id, rt.tag_id
            FROM repo_tags AS rt
            JOIN repos AS r ON r.id = rt.repo_id AND r.is_starred = 1
            ORDER BY \(order)
            """).map { row in
            let id: Int64 = row["repo_id"]
            return TagGraphEdge(source: "tag:" + row["tag_id"], target: "repo:\(id)")
        }
        return TagGraphSnapshot(nodes: tags + repos, edges: edges)
    }
}
