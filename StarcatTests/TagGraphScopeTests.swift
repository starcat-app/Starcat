// Verifies that only distinct, applied tag pairs in this account contribute weight.
import GRDB
import Testing
@testable import Starcat

@Suite("Tag graph data scope")
struct TagGraphScopeTests {
    @Test("Duplicate assignment, hierarchy and pending AI work do not add edges")
    func onlyAppliedTags() async throws {
        let sample = try TagGraphFixture()
        try await sample.seed()
        let before = try await sample.snapshot()
        try await sample.links.addTag(repoId: 1, tagId: "agent")
        try await sample.db.writer.write { db in
            // A pending draft refers to r3 and Agent, but has not applied that tag.
            try db.execute(sql: "INSERT INTO ai_organization_drafts VALUES ('pending', 'test', '{}', 0, 0)")
            try db.execute(sql: """
                INSERT INTO ai_organization_draft_items VALUES ('pending', 3, '{"tagIDs":["agent"]}', 0)
                """)
        }
        let after = try await sample.snapshot()
        #expect(after == before)
        #expect(after.edges.first?.id == TagGraphPair("rag", "agent"))
        #expect(after.edges.allSatisfy { $0.leftID < $0.rightID })
    }

    @Test("Identical tag and repository IDs in different account stores do not pool data")
    func independentAccounts() async throws {
        let a = try TagGraphFixture()
        try await a.seed()
        let b = try TagGraphFixture()
        try await b.db.insertRepoFixtures(count: 1)
        try await b.tags.create(.fixture(id: "agent", name: "Agent"))
        try await b.tags.create(.fixture(id: "rag", name: "RAG"))
        try await b.links.setTags(repoId: 1, tagIds: ["rag", "agent"])
        let graphA = try await a.snapshot()
        let graphB = try await b.snapshot()
        #expect(graphA.edges.first?.sharedCount == 2)
        #expect(graphB.nodes.map(\.repoCount) == [1, 1])
        #expect(graphB.edges == [TagGraphEdge(leftID: "agent", rightID: "rag", sharedCount: 1)])
    }
}
