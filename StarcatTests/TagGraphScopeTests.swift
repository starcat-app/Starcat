// Verifies that only applied memberships in this account contribute nodes and edges.
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
            try db.execute(sql: "INSERT INTO ai_organization_drafts VALUES ('pending', 'test', '{}', 0, 0)")
            try db.execute(sql: """
                INSERT INTO ai_organization_draft_items VALUES ('pending', 3, '{"tagIDs":["agent"]}', 0)
                """)
        }
        #expect(try await sample.snapshot() == before)
    }

    @Test("Identical tag and repository IDs in different account stores do not pool data")
    func independentAccounts() async throws {
        let a = try TagGraphFixture()
        try await a.seed()
        let b = try TagGraphFixture()
        try await b.db.insertRepoFixtures(count: 1)
        try await b.tags.create(.fixture(id: "agent", name: "Agent"))
        try await b.links.setTags(repoId: 1, tagIds: ["agent"])
        let graphA = try await a.snapshot()
        let graphB = try await b.snapshot()
        #expect(graphA == TagGraphFixture.expectedSnapshot)
        #expect(graphB.nodes.map(\.id) == ["tag:agent", "repo:1"])
        #expect(graphB.edges == [TagGraphEdge(source: "tag:agent", target: "repo:1")])
    }
}
