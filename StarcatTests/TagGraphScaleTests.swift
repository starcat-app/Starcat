// 用两个可复现的 5,000 Star 收藏测量图谱和共同仓库首屏。建库和准备样本均在计时区间外。
import Foundation
import GRDB
import Testing
@testable import Starcat

/// 使用生产 DatabasePool 与 ViewModel，计时止于图和仓库数据交付主线程。画布绘制另做实机验收。
@MainActor @Suite("标签图谱规模样本")
struct TagGraphScaleTests {
    @Test func firstGraphAndIntersection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for tagCount in [17, 40] {
            let database = try DatabaseManager(userId: Int64(tagCount), basePathOverride: directory)
            try await Self.seed(database.writer, tagCount: tagCount)
            let clock = ContinuousClock()
            for round in 1...3 {
                let model = TagGraphViewModel()
                defer { model.clear() }
                let opened = clock.now
                model.bind(reader: database.writer) { true }
                try await Self.waitForDelivery { model.graph != nil }
                let graphReady = clock.now
                let graph = try #require(model.graph)
                #expect(graph.nodes.count == tagCount)
                if tagCount == 40 { #expect(graph.edges.count == 780) }
                let edge = try #require(graph.edges.first)
                let selected = clock.now
                model.select(.edge(edge.id))
                try await Self.waitForDelivery { model.page != nil }
                let pageReady = clock.now
                let page = try #require(model.page)
                #expect(page.total == edge.sharedCount && page.items.count == min(20, page.total))
                print("TAG_GRAPH_SAMPLE tags=\(tagCount) edges=\(graph.edges.count) shared=\(page.total) " +
                      "round=\(round) graph=\(opened.duration(to: graphReady)) page=\(selected.duration(to: pageReady))")
            }
        }
    }

    /// 1 ms 轮询仅为测量主线程交付的上界。耗时作为观测值输出，避免随 CI 负载改变正确性结论。
    private static func waitForDelivery(_ ready: () -> Bool) async throws {
        let clock = ContinuousClock(), deadline = clock.now + .seconds(15)
        while !ready(), clock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        try #require(ready())
    }

    /// 典型样本每仓 0～3 个标签。密集样本每仓 8 个，首仓用全部 40 个，使 780 条边都可核对。
    private static func seed(_ writer: any DatabaseWriter, tagCount: Int) async throws {
        try await writer.write { db in
            try db.execute(sql: """
                WITH RECURSIVE seq(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM seq WHERE i<5000)
                INSERT INTO repos (id, owner, name, full_name, html_url, topics, is_starred, starred_at)
                SELECT i, 'sample', 'r'||i, 'sample/r'||i, 'https://example.invalid/r'||i,
                       '[]', 1, '2026-11-20T00:00:00Z' FROM seq
                """)
            try db.execute(sql: """
                WITH RECURSIVE seq(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM seq WHERE i+1<?)
                INSERT INTO tags (id, name, created_at, updated_at)
                SELECT printf('t%02d',i), 'Tag '||i, '2026-11-20', '2026-11-20' FROM seq
                """, arguments: [tagCount])
            // 按仓库 ID 轮换首标签，让最热门关系统计的也是一批不同仓库。
            try db.execute(sql: """
                WITH RECURSIVE slots(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM slots WHERE i+1<?)
                INSERT INTO repo_tags (repo_id, tag_id, created_at)
                SELECT r.id, printf('t%02d', (r.id + s.i) % ?), '2026-11-20'
                FROM repos r JOIN slots s ON s.i < CASE WHEN ?=17 THEN r.id % 4
                                                        WHEN r.id=1 THEN 40 ELSE 8 END
                """, arguments: [tagCount, tagCount, tagCount])
        }
    }
}
