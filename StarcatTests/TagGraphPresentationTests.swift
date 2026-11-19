// Verifies that changing the visible graph does not lose valid tags or raw counts.
import Testing
@testable import Starcat

@Suite("Tag graph presentation")
struct TagGraphPresentationTests {
    @Test("Higher thresholds hide weaker links without changing the searchable tags")
    func edgeThresholdAndSearch() async throws {
        let sample = try TagGraphFixture()
        try await sample.seed()
        let graph = try await sample.snapshot()
        #expect(graph.visibleEdges(minimum: 2).map(\.sharedCount) == [2])
        #expect(graph.visibleEdges(minimum: 3).isEmpty)
        #expect(graph.matchingNodes("").count == 5)
        #expect(graph.matchingNodes(" cli ").map(\.repoCount) == [1])
        #expect(graph.matchingNodes("资料").map(\.repoCount) == [0])
        #expect(graph.matchingNodes("no match").isEmpty)
        #expect(graph.visibleEdges(minimum: 1) == graph.edges)
    }
}
