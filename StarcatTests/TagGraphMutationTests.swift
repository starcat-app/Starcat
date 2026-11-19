// 从专题样例分别应用标签与收藏写入，再用生产读取核对边权与成员。
import GRDB
import Testing
@testable import Starcat

@Suite("Tag graph mutations")
struct TagGraphMutationTests {
    @Test func starAndUnstar() async throws {
        let sample = try TagGraphFixture()
        try await sample.seed()
        for (starred, expected) in [(false, [Int64(1)]), (true, [1, 2])] {
            try await sample.db.writer.write { try $0.execute(sql: "UPDATE repos SET is_starred=? WHERE id=2", arguments: [starred]) }
            let frame = try await sample.db.writer.read {
                try TagGraphFrame.read(in: $0, selection: .edge(TagGraphPair("agent", "rag")), offset: 0, limit: 20)
            }
            #expect(frame.graph.edges.first { $0.id == TagGraphPair("agent", "rag") }?.sharedCount == expected.count)
            #expect(frame.page?.total == expected.count)
            #expect(frame.page?.items.map(\.id).sorted() == expected)
        }
    }

    @Test func renameMergeDeleteAndEditAssignments() async throws {
        let sample = try TagGraphFixture()
        try await sample.seed()
        let before = try await sample.snapshot()
        var tag = try #require(try await sample.tags.find(id: "rag"))
        tag.name = "Retrieval"
        try await sample.tags.update(tag)
        let renamed = try await sample.snapshot()
        #expect(renamed.edges == before.edges)
        #expect(renamed.nodes.first { $0.id == "rag" }?.name == "Retrieval")
        try await sample.links.addTag(repoId: 3, tagId: "rag")
        #expect(try await sample.snapshot().edges.first { $0.id == TagGraphPair("rag", "python") }?.sharedCount == 2)
        try await sample.links.removeTag(repoId: 3, tagId: "rag")
        #expect(try await sample.snapshot() == renamed)
        try await sample.tags.merge(source: "rag", into: "agent")
        let merged = try await sample.snapshot()
        #expect(merged.nodes.first { $0.id == "agent" }?.repoCount == 2)
        #expect(merged.edges == [TagGraphEdge(leftID: "agent", rightID: "python", sharedCount: 1)])
        try await sample.tags.delete(id: "python")
        #expect(try await sample.snapshot().edges.isEmpty)
    }
}
