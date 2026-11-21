// Exercises the same AND predicate through the old repository and paged graph reads.
import GRDB
import Testing
@testable import Starcat

@Suite("Starred repository tag intersection")
struct RepoTagIntersectionTests {
    @Test("Every page reports the full AND count and pagination has no duplicates")
    func andPagination() async throws {
        let sample = try TagGraphFixture()
        try await sample.seed()
        let (first, second, last, narrow) = try await sample.db.writer.read { db in
            let pair: Set = ["agent", "rag"]
            return (
                try RepoTagIntersection.page(in: db, tagIDs: pair, limit: 1, offset: 0),
                try RepoTagIntersection.page(in: db, tagIDs: pair, limit: 1, offset: 1),
                try RepoTagIntersection.page(in: db, tagIDs: pair, limit: 1, offset: 2),
                try RepoTagIntersection.page(in: db, tagIDs: ["agent", "python"], limit: 1, offset: 0)
            )
        }
        #expect([first.total, second.total, last.total] == [2, 2, 2])
        #expect(first.items.count == 1 && second.items.count == 1 && last.items.isEmpty)
        #expect(Set((first.items + second.items).map(\.id)) == [1, 2])
        #expect(narrow.total == 1 && narrow.items.map(\.id) == [1])
        #expect(try await sample.links.fetchRepos(forTags: ["agent", "python"]).map(\.id) == [1])
    }
}
