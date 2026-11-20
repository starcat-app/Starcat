// Empty and isolated graphs are valid without inventing nodes or links.
import Testing
@testable import Starcat

@Suite("Tag graph isolated nodes")
struct TagGraphIsolatedNodesTests {
    @Test("Unused tags survive, while untagged repositories stay out of the graph")
    func emptyAndIsolatedGraphs() async throws {
        let sample = try TagGraphFixture()
        #expect(try await sample.snapshot() == TagGraphSnapshot(nodes: [], edges: []))
        try await sample.db.insertRepoFixtures(count: 2)
        try await sample.tags.create(.fixture(id: "cli", name: "CLI"))
        try await sample.tags.create(.fixture(id: "parent", name: "资料"))
        try await sample.links.addTag(repoId: 1, tagId: "cli")
        let snapshot = try await sample.snapshot()
        #expect(snapshot.nodes.filter { $0.kind == .tag }.map(\.name) == ["CLI", "资料"])
        #expect(snapshot.nodes.filter { $0.kind == .repo }.map(\.name) == ["octo/demo-1"])
        #expect(snapshot.edges == [TagGraphEdge(source: "tag:cli", target: "repo:1")])
    }
}
