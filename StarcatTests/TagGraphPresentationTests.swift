// Verifies that search finds both node types without filtering the visible canvas.
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
}
