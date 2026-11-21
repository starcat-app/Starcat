// 从专题样例分别应用标签与收藏写入，再用生产读取核对归属图。
import GRDB
import Testing
@testable import Starcat

@Suite("Tag graph mutations")
struct TagGraphMutationTests {
    @Test func starAndUnstar() async throws {
        let sample = try TagGraphFixture()
        try await sample.seed()
        try await sample.db.writer.write { try $0.execute(sql: "UPDATE repos SET is_starred=? WHERE id=2", arguments: [false]) }
        let unstarred = try await sample.snapshot()
        #expect(!unstarred.nodes.contains { $0.id == "repo:2" })
        #expect(unstarred.edges == TagGraphFixture.expectedEdges.filter { $0.target != "repo:2" })

        try await sample.db.writer.write { try $0.execute(sql: "UPDATE repos SET is_starred=? WHERE id=2", arguments: [true]) }
        #expect(try await sample.snapshot() == TagGraphFixture.expectedSnapshot)
    }

    @Test func renameAddRemoveMergeAndDelete() async throws {
        let sample = try TagGraphFixture()
        try await sample.seed()
        var tag = try #require(try await sample.tags.find(id: "rag"))
        tag.name = "Retrieval"
        try await sample.tags.update(tag)
        let renamed = try await sample.snapshot()
        #expect(renamed.edges == TagGraphFixture.expectedEdges)
        #expect(renamed.nodes.first { $0.id == "tag:rag" }?.name == "Retrieval")

        try await sample.links.addTag(repoId: 3, tagId: "rag")
        #expect(try await sample.snapshot().edges.contains(TagGraphEdge(source: "tag:rag", target: "repo:3")))
        try await sample.links.removeTag(repoId: 3, tagId: "rag")
        #expect(try await sample.snapshot() == renamed)

        try await sample.tags.merge(source: "rag", into: "agent")
        let merged = try await sample.snapshot()
        #expect(!merged.nodes.contains { $0.id == "tag:rag" })
        #expect(merged.edges == TagGraphFixture.expectedEdges.filter { $0.source != "tag:rag" })

        try await sample.tags.delete(id: "python")
        let deleted = try await sample.snapshot()
        #expect(!deleted.nodes.contains { $0.id == "tag:python" || $0.id == "repo:3" })
        #expect(!deleted.edges.contains { $0.source == "tag:python" })
    }
}
