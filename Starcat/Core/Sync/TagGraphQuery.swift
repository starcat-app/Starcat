// Read-only projection of the current account's tags and starred repositories.
import GRDB

/// A node keeps its database identity when its display name or appearance changes.
struct TagGraphNode: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let color: String?
    let icon: String?
    let repoCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, color, icon
        case repoCount = "repo_count"
    }
}

/// An unordered pair has one canonical representation, even when selected from either end.
struct TagGraphPair: Hashable, Sendable {
    let leftID: String
    let rightID: String

    init(_ first: String, _ second: String) {
        // SQLite's BINARY collation orders the stored UTF-8 IDs bytewise.
        (leftID, rightID) = second.utf8.lexicographicallyPrecedes(first.utf8) ? (second, first) : (first, second)
    }
}

struct TagGraphEdge: Codable, Equatable, Identifiable, Sendable {
    let leftID: String
    let rightID: String
    let sharedCount: Int

    var id: TagGraphPair { TagGraphPair(leftID, rightID) }

    enum CodingKeys: String, CodingKey {
        case leftID = "left_id"
        case rightID = "right_id"
        case sharedCount = "shared_count"
    }
}

struct TagGraphSnapshot: Codable, Equatable, Sendable {
    let nodes: [TagGraphNode]
    let edges: [TagGraphEdge]
}

/// Call from one `read` or observation transaction so node and edge counts agree.
enum TagGraphQuery {
    static func snapshot(in db: Database) throws -> TagGraphSnapshot {
        // Start at tags so unused tags and tags on only one repository remain discoverable.
        let nodes = try Row.fetchAll(db, sql: """
            SELECT t.id, t.name, t.color, t.icon, COALESCE(c.n, 0) AS repo_count
            FROM tags AS t
            LEFT JOIN (
                SELECT rt.tag_id, COUNT(*) AS n
                FROM repo_tags AS rt
                JOIN repos AS r ON r.id = rt.repo_id AND r.is_starred = 1
                GROUP BY rt.tag_id
            ) AS c ON c.tag_id = t.id
            ORDER BY t.id
            """).map { row in
            TagGraphNode(id: row["id"], name: row["name"], color: row["color"],
                         icon: row["icon"], repoCount: row["repo_count"])
        }

        // The (repo_id, tag_id) primary key and strict ordering give each repo
        // exactly one vote per tag pair. Hierarchy and suggestions are separate tables/columns.
        let edges = try Row.fetchAll(db, sql: """
            SELECT a.tag_id AS left_id, b.tag_id AS right_id, COUNT(*) AS shared_count
            FROM repo_tags AS a
            JOIN repos AS r ON r.id = a.repo_id AND r.is_starred = 1
            JOIN repo_tags AS b ON b.repo_id = a.repo_id AND a.tag_id < b.tag_id
            GROUP BY a.tag_id, b.tag_id
            ORDER BY shared_count DESC, left_id, right_id
            """).map { row in
            TagGraphEdge(leftID: row["left_id"], rightID: row["right_id"], sharedCount: row["shared_count"])
        }
        return TagGraphSnapshot(nodes: nodes, edges: edges)
    }
}
