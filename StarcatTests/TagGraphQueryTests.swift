// Exercises the production graph projection against the migrated in-memory database.
import GRDB
import Testing
@testable import Starcat

/// Shared fixture from the tag graph requirements, with known AND and OR results.
struct TagGraphFixture {
    let db: InMemoryDatabaseManager
    var tags: GRDBTagRepository { GRDBTagRepository(database: db) }
    var links: GRDBRepoTagRepository { GRDBRepoTagRepository(database: db) }

    init() throws { db = try InMemoryDatabaseManager() }

    func seed() async throws {
        try await db.insertRepoFixtures(count: 6)
        for (id, name) in [("agent", "Agent"), ("rag", "RAG"), ("python", "Python"), ("cli", "CLI"), ("parent", "资料")] {
            try await tags.create(.fixture(id: id, name: name))
        }
        try await links.setTags(repoId: 1, tagIds: ["agent", "rag", "python"])
        try await links.setTags(repoId: 2, tagIds: ["agent", "rag"])
        try await links.setTags(repoId: 3, tagIds: ["python"])
        try await links.setTags(repoId: 4, tagIds: ["cli"])
        try await links.setTags(repoId: 6, tagIds: ["agent", "rag"])
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE tags SET parent_id = 'parent' WHERE id = 'rag'")
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 6")
        }
    }

    func snapshot() async throws -> TagGraphSnapshot {
        try await db.writer.read { try TagGraphQuery.snapshot(in: $0) }
    }
}

@Suite("Tag graph query")
struct TagGraphQueryTests {
    @Test("Graph counts come from current Stars and applied tags")
    func fixedSample() async throws {
        let sample = try TagGraphFixture()
        try await sample.seed()
        let graph = try await sample.snapshot()
        #expect(Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.name, $0.repoCount) }) == [
            "Agent": 2, "RAG": 2, "Python": 2, "CLI": 1, "资料": 0,
        ])
        #expect(graph.edges == [
            TagGraphEdge(leftID: "agent", rightID: "rag", sharedCount: 2),
            TagGraphEdge(leftID: "agent", rightID: "python", sharedCount: 1),
            TagGraphEdge(leftID: "python", rightID: "rag", sharedCount: 1),
        ])
    }
}
