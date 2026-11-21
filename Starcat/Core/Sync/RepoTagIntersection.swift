// Shared AND query for the tag repository, graph evidence and public tools.
import GRDB

/// `total` counts the full intersection, even if the requested page is empty.
struct RepoTagIntersectionPage: Sendable {
    let items: [Repo]
    let total: Int
}

enum RepoTagIntersection {
    /// Retains the repository's unpaged read behavior for existing callers.
    static func fetch(in db: Database, tagIDs: Set<String>) throws -> [Repo] {
        guard !tagIDs.isEmpty else { return [] }
        let filter = filter(for: tagIDs)
        return try Repo.fetchAll(db, sql: orderedRepos(filter.sql), arguments: filter.arguments)
    }

    /// Read count and rows on the caller's transaction so a write cannot separate the two.
    static func page(in db: Database, tagIDs: Set<String>, limit: Int, offset: Int) throws -> RepoTagIntersectionPage {
        guard !tagIDs.isEmpty else { return RepoTagIntersectionPage(items: [], total: 0) }
        let filter = filter(for: tagIDs)
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (\(filter.sql))", arguments: filter.arguments) ?? 0
        let items = offset < total ? try Repo.fetchAll(
            db, sql: orderedRepos(filter.sql) + " LIMIT ? OFFSET ?",
            arguments: filter.arguments + StatementArguments([limit, offset])
        ) : []
        return RepoTagIntersectionPage(items: items, total: total)
    }

    private static func orderedRepos(_ ids: String) -> String {
        "SELECT r.* FROM repos r JOIN (\(ids)) matched ON matched.id = r.id ORDER BY r.starred_at DESC, r.id ASC"
    }

    /// `IN` selects candidate rows. `HAVING` ensures each candidate has all distinct requested tags.
    private static func filter(for tagIDs: Set<String>) -> (sql: String, arguments: StatementArguments) {
        let placeholders = Array(repeating: "?", count: tagIDs.count).joined(separator: ", ")
        var arguments = StatementArguments(tagIDs.sorted())
        arguments += StatementArguments([tagIDs.count])
        return ("""
            SELECT r.id FROM repos r
            JOIN repo_tags rt ON rt.repo_id = r.id
            WHERE rt.tag_id IN (\(placeholders)) AND r.is_starred = 1
            GROUP BY r.id
            HAVING COUNT(DISTINCT rt.tag_id) = ?
            """, arguments)
    }
}
