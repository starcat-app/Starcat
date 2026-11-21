// Verifies that search finds both node types without filtering the visible canvas.
import Foundation
import GRDB
import Testing
@testable import Starcat

@Suite("Tag graph presentation")
struct TagGraphPresentationTests {
    @Test("Search is bounded and matches tags and repositories")
    func search() async throws {
        let sample = try TagGraphFixture()
        try await sample.seed()
        let graph = try await sample.snapshot()
        #expect(graph.matchingNodes("").isEmpty)
        #expect(graph.matchingNodes(" cli ").map(\.id) == ["tag:cli"])
        #expect(graph.matchingNodes("资料").map(\.id) == ["tag:parent"])
        #expect(graph.matchingNodes("demo-1").map(\.id) == ["repo:1"])
        #expect(graph.matchingNodes("no match").isEmpty)
        #expect(graph.matchingNodes("demo", limit: 2).count == 2)
    }

    @MainActor
    @Test("Per-tag pages follow canvas acknowledgements and deduplicate shared repositories")
    func incrementalPages() async throws {
        let sample = try TagGraphFixture()
        try await sample.db.insertRepoFixtures(count: 93)
        try await sample.tags.create(.fixture(id: "agent", name: "Agent"))
        try await sample.tags.create(.fixture(id: "rag", name: "RAG"))
        try await sample.db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO repo_tags (repo_id, tag_id, created_at)
                SELECT id, 'agent', '2026-11-21' FROM repos;
                INSERT INTO repo_tags VALUES (32, 'rag', '2026-11-21');
                UPDATE repos SET starred_at = NULL;
                UPDATE repos SET starred_at = '2026-11-21T01:00:00Z' WHERE id = 93;
                UPDATE tags SET created_at = '2026-11-21T01:00:00Z' WHERE id = 'agent';
                """)
        }

        let model = TagGraphViewModel()
        defer { model.clear() }
        model.bind(reader: sample.db.writer) { true }
        try await TagGraphObservationTests.waitUntil { model.displayed != nil }
        let agent = "tag:agent", rag = "tag:rag"
        func agentRepos() -> [String] { model.displayed?.edges.filter { $0.source == agent }.map(\.target) ?? [] }
        func report(_ count: Int, revision: Int? = nil, selection: Int? = nil) {
            model.reportProgress(revision: revision ?? model.revision, selectedID: agent,
                                 selectionRevision: selection ?? model.selectionRevision, count: count)
        }
        #expect(agentRepos() == ["repo:93"] + (1...29).map { "repo:\($0)" })
        #expect(model.totalCount(for: agent) == 93 && model.totalCount(for: rag) == 1)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-11-21T01:00:00Z"))
        #expect(model.tagCreationDate(agent) == date)
        model.select(agent)
        model.loadMore(agent)
        #expect(agentRepos().count == 30)
        let initialRevision = model.revision
        report(30)
        model.loadMore(agent)
        #expect(agentRepos().count == 80)
        #expect(model.displayed?.edges.filter { $0.source == rag }.count == 1)
        #expect(model.displayed?.nodes.filter { $0.id == "repo:32" }.count == 1)
        report(80, revision: initialRevision)
        #expect(model.renderedMembershipCount == 30 && model.isRevealing(agent))
        model.loadMore(agent)
        #expect(agentRepos().count == 80)

        let initialSelection = model.selectionRevision
        model.select(rag)
        model.select(agent)
        report(80, selection: initialSelection)
        #expect(model.renderedMembershipCount == 0)
        report(80)
        model.loadMore(agent)
        #expect(agentRepos().count == 93)
        #expect(model.hasMore(for: agent))
        report(93)
        #expect(!model.hasMore(for: agent) && !model.isRevealing(agent))

        model.bind(reader: sample.db.writer) { true }
        try await TagGraphObservationTests.waitUntil { model.displayed != nil }
        #expect(model.selectedID == nil && model.renderedMembershipCount == 0)
        let initialPage = agentRepos()
        model.locate("repo:61")
        #expect(model.selectedID == "repo:61")
        #expect(agentRepos() == initialPage + ["repo:61"])
        model.select(agent)
        report(31)
        model.loadMore(agent)
        #expect(agentRepos().count == 81)
        #expect(agentRepos().contains("repo:61"))
    }
}
