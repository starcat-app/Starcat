// Empty and isolated graphs are valid without inventing links or dropping tags.
import Testing
@testable import Starcat

@Suite("Tag graph isolated nodes")
struct TagGraphIsolatedNodesTests {
    @Test("Unused and single-tag nodes survive when no edges exist")
    func emptyAndIsolatedGraphs() async throws {
        let sample = try TagGraphFixture()
        #expect(try await sample.snapshot() == TagGraphSnapshot(nodes: [], edges: []))
        try await sample.db.insertRepoFixtures(count: 1)
        try await sample.tags.create(.fixture(id: "cli", name: "CLI"))
        try await sample.tags.create(.fixture(id: "parent", name: "资料"))
        try await sample.links.addTag(repoId: 1, tagId: "cli")
        let snapshot = try await sample.snapshot()
        #expect(snapshot.nodes.map(\.name) == ["CLI", "资料"])
        #expect(snapshot.nodes.map(\.repoCount) == [1, 0])
        #expect(snapshot.edges.isEmpty)
    }
}
