// 精确延迟 A 的读取结果，验证切号、快速切换关系以及旧画布消息。
import GRDB
import Testing
@testable import Starcat

@MainActor @Suite("Tag graph subscriptions")
struct TagGraphSessionTests {
    @Test func staleFramesAndCanvasEvents() async throws {
        let a = try TagGraphFixture(), b = try TagGraphFixture()
        try await a.seed()
        try await b.db.insertRepoFixtures(count: 1)
        for id in ["agent", "rag"] { try await b.tags.create(.fixture(id: id, name: id)) }
        try await b.links.setTags(repoId: 1, tagIds: ["agent", "rag"])
        let model = TagGraphViewModel()
        defer { model.clear() }
        model.bind(reader: a.db.writer) { true }
        try await TagGraphObservationTests.waitUntil { model.graph?.nodes.count == 5 }
        model.select(.edge(TagGraphPair("agent", "rag")))
        let oldSession = model.session, oldGeneration = model.generation
        let lateA = try await a.db.writer.read { try TagGraphFrame.read(in: $0, selection: .edge(TagGraphPair("agent", "rag")), offset: 0, limit: 1) }
        model.select(.edge(TagGraphPair("agent", "python")))
        model.apply(lateA, generation: oldGeneration)
        #expect(!model.accepts(session: oldSession, generation: oldGeneration))
        try await TagGraphObservationTests.waitUntil { model.page?.total == 1 }
        model.bind(reader: b.db.writer) { true }
        #expect(model.graph == nil && model.page == nil && model.selection == nil)
        model.apply(lateA, generation: oldGeneration)
        try await TagGraphObservationTests.waitUntil { model.graph?.nodes.count == 2 }
        #expect(!model.accepts(session: oldSession, generation: model.generation))
        model.select(.edge(TagGraphPair("agent", "rag")))
        try await TagGraphObservationTests.waitUntil { model.page?.total == 1 }
        model.bind(reader: a.db.writer) { true }
        try await TagGraphObservationTests.waitUntil { model.graph?.edges.first?.sharedCount == 2 }
    }
}
