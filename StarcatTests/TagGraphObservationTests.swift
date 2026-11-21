// 使用真实 GRDB 观察验证归属图失败恢复与成员变化。
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

    @Test("首次失败可重试，后续失败保留上次成功图")
    func retriesFailedReads() async throws {
        let fixture = try TagGraphFixture()
        try await fixture.seed()
        let model = TagGraphViewModel()
        defer { model.clear() }

        let writer = fixture.db.writer
        try await writer.write { try $0.execute(sql: "ALTER TABLE repo_tags RENAME TO saved_repo_tags") }
        model.bind(reader: writer) { true }
        try await Self.waitUntil { model.failed }
        #expect(model.graph == nil)
        try await writer.write { try $0.execute(sql: "ALTER TABLE saved_repo_tags RENAME TO repo_tags") }
        model.observe()
        try await Self.waitUntil { model.graph?.edges.count == 7 }

        let before = model.graph
        try await writer.write { try $0.execute(sql: "ALTER TABLE repo_tags RENAME TO saved_repo_tags") }
        model.observe()
        try await Self.waitUntil { model.failed }
        #expect(model.graph == before)
        try await writer.write { db in
            try db.execute(sql: "ALTER TABLE saved_repo_tags RENAME TO repo_tags")
            try db.execute(sql: "UPDATE repos SET is_starred = 0 WHERE id = 2")
        }
        model.observe()
        try await Self.waitUntil { model.graph?.edges.count == 5 }
        #expect(!model.failed && model.graph?.nodes.count == 8)
    }

    @Test func liveMembershipChangesUpdateTheWholeSnapshot() async throws {
        let fixture = try TagGraphFixture()
        try await fixture.seed()
        let model = TagGraphViewModel()
        defer { model.clear() }
        model.bind(reader: fixture.db.writer) { true }
        try await Self.waitUntil { model.graph?.edges.count == 7 }

        try await fixture.db.writer.write { db in
            try db.execute(sql: "UPDATE repo_tags SET repo_id=5 WHERE repo_id=1")
        }
        try await Self.waitUntil { model.graph?.nodes.contains { $0.id == "repo:5" } == true }
        #expect(model.graph?.edges.contains { $0.target == "repo:5" } == true)

        try await fixture.tags.delete(id: "rag")
        try await Self.waitUntil { model.graph?.edges.count == 5 }
        #expect(model.graph?.nodes.contains { $0.id == "tag:rag" } == false)
    }
}
