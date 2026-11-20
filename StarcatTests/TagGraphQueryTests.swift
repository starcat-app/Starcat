// Exercises the production membership projection against the migrated in-memory database.
import GRDB
import Testing
@testable import Starcat

/// Shared fixture from the tag graph requirements, with known tag-to-repository results.
struct TagGraphFixture {
    let db: InMemoryDatabaseManager
    var tags: GRDBTagRepository { GRDBTagRepository(database: db) }
    var links: GRDBRepoTagRepository { GRDBRepoTagRepository(database: db) }

    static let tagNames = [
        ("agent", "Agent"), ("cli", "CLI"), ("parent", "资料"), ("python", "Python"), ("rag", "RAG"),
    ]
    static let avatarURL = "https://avatars.githubusercontent.com/u/42"
    static let tagNodes = tagNames.map { id, name in
        TagGraphNode(id: "tag:\(id)", kind: .tag, name: name, color: "#FF5722", icon: "tag")
    }
    static let repoNodes = (1...4).map { id in
        TagGraphNode(id: "repo:\(id)", kind: .repo, name: "octo/demo-\(id)", avatarURL: id == 1 ? avatarURL : nil)
    }

    static let expectedEdges: [TagGraphEdge] = [
        .init(source: "tag:agent", target: "repo:1"),
        .init(source: "tag:python", target: "repo:1"),
        .init(source: "tag:rag", target: "repo:1"),
        .init(source: "tag:agent", target: "repo:2"),
        .init(source: "tag:rag", target: "repo:2"),
        .init(source: "tag:python", target: "repo:3"),
        .init(source: "tag:cli", target: "repo:4"),
    ]

    static var expectedSnapshot: TagGraphSnapshot { .init(nodes: tagNodes + repoNodes, edges: expectedEdges) }

    init(userID: Int64? = nil) throws { db = try InMemoryDatabaseManager(userId: userID) }

    func seed() async throws {
        try await db.insertRepoFixtures(count: 6)
        for (id, name) in Self.tagNames {
            try await tags.create(.fixture(id: id, name: name))
        }
        try await links.setTags(repoId: 1, tagIds: ["agent", "rag", "python"])
        try await links.setTags(repoId: 2, tagIds: ["agent", "rag"])
        try await links.setTags(repoId: 3, tagIds: ["python"])
        try await links.setTags(repoId: 4, tagIds: ["cli"])
        try await links.setTags(repoId: 6, tagIds: ["agent", "rag"])
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE tags SET parent_id = 'parent' WHERE id = 'rag'")
            try db.execute(sql: "UPDATE repos SET owner_avatar = ? WHERE id = 1", arguments: [Self.avatarURL])
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 6")
        }
    }

    func snapshot() async throws -> TagGraphSnapshot {
        try await db.writer.read { try TagGraphQuery.snapshot(in: $0) }
    }
}

@Suite("Tag graph query")
struct TagGraphQueryTests {
    @Test("Graph contains tags, tagged Stars and one edge per membership")
    func fixedSample() async throws {
        let sample = try TagGraphFixture()
        try await sample.seed()
        #expect(try await sample.snapshot() == TagGraphFixture.expectedSnapshot)
    }
}
