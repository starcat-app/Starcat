// 使用真实 GRDB 观察验证权重相等时的成员变化与关系消失。
import GRDB
import Testing
@testable import Starcat

@MainActor @Suite("Tag graph live evidence")
struct TagGraphObservationTests {
    /// 只等待异步观察交付可识别的状态，超时作为断言失败，而非固定延时猜测。
    static func waitUntil(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = clock.now + .seconds(5)
        while !predicate(), clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(predicate())
    }

    @Test("首次失败可重试，同账户刷新失败保留上次成功的图与仓库")
    func retriesFailedReads() async throws {
        let fixture = try TagGraphFixture()
        try await fixture.seed()
        let model = TagGraphViewModel()
        defer { model.clear() }

        // 暂时移走内存库中的关联表，让真实订阅读失败，同时保留可恢复的原数据。
        let writer = fixture.db.writer
        try await writer.write { try $0.execute(sql: "ALTER TABLE repo_tags RENAME TO saved_repo_tags") }
        model.bind(reader: writer) { true }
        try await Self.waitUntil { model.failed }
        #expect(model.graph == nil)
        try await writer.write { try $0.execute(sql: "ALTER TABLE saved_repo_tags RENAME TO repo_tags") }
        model.observe()
        try await Self.waitUntil { model.graph?.nodes.count == 5 }
        model.select(.edge(TagGraphPair("agent", "rag")))
        try await Self.waitUntil { model.page?.total == 2 }

        let before = model.graph
        try await writer.write { try $0.execute(sql: "ALTER TABLE repo_tags RENAME TO saved_repo_tags") }
        model.observe()
        try await Self.waitUntil { model.failed }
        #expect(model.graph == before)
        #expect(Set(model.page?.items.map(\.id) ?? []) == [1, 2])
        try await writer.write { db in
            try db.execute(sql: "ALTER TABLE saved_repo_tags RENAME TO repo_tags")
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 2")
        }
        model.observe()
        try await Self.waitUntil { model.page?.items.map(\.id) == [1] }
        #expect(!model.failed && model.page?.total == 1)
    }

    @Test func replacesMemberAndClosesVanishedEdge() async throws {
        let fixture = try TagGraphFixture()
        try await fixture.seed()
        let model = TagGraphViewModel()
        defer { model.clear() }
        model.bind(reader: fixture.db.writer) { true }
        try await Self.waitUntil { model.graph != nil }
        model.select(.edge(TagGraphPair("rag", "agent")))
        try await Self.waitUntil { model.page?.total == 2 }
        let before = model.graph
        // 同时交换两个仓库的全部标签，图的数据完全相同，只有证据发生变化。
        try await fixture.db.writer.write { db in
            try db.execute(sql: "UPDATE repo_tags SET repo_id=5 WHERE repo_id=1")
        }
        try await Self.waitUntil { Set(model.page?.items.map(\.id) ?? []) == [2, 5] }
        #expect(model.graph == before)
        try await fixture.tags.delete(id: "rag")
        try await Self.waitUntil { model.selectionDisappeared }
        #expect(model.selection == nil && model.page == nil)
    }
}
