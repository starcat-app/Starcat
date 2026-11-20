// 精确延迟读取结果，验证切号与旧回调不会覆盖当前账户。
import GRDB
import Testing
@testable import Starcat

@MainActor @Suite("Tag graph subscriptions")
struct TagGraphSessionTests {
    @Test func staleFramesAndAccountChanges() async throws {
        let a = try TagGraphFixture(), b = try TagGraphFixture()
        try await a.seed()
        try await b.db.insertRepoFixtures(count: 1)
        try await b.tags.create(.fixture(id: "agent", name: "Agent"))
        try await b.links.setTags(repoId: 1, tagIds: ["agent"])
        let model = TagGraphViewModel()
        defer { model.clear() }

        model.bind(reader: a.db.writer) { true }
        try await TagGraphObservationTests.waitUntil { model.graph?.nodes.count == 9 }
        let oldGeneration = model.generation
        let lateA = model.graph
        model.bind(reader: b.db.writer) { true }
        #expect(model.graph == nil)
        model.apply(.init(graph: try #require(lateA)), generation: oldGeneration)
        try await TagGraphObservationTests.waitUntil { model.graph?.nodes.count == 2 }
        #expect(model.graph?.edges == [TagGraphEdge(source: "tag:agent", target: "repo:1")])

        model.bind(reader: a.db.writer) { true }
        try await TagGraphObservationTests.waitUntil { model.graph?.edges.count == 7 }
    }
}
