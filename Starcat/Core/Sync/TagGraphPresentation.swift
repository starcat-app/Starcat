// Presentation filters leave repository counts and the underlying graph intact.
import Foundation

extension TagGraphSnapshot {
    /// Thresholds hide edges only, including when every edge is hidden.
    func visibleEdges(minimum: Int) -> [TagGraphEdge] {
        edges.filter { $0.sharedCount >= minimum }
    }

    /// Includes unused tags as well as tags whose edges are filtered out.
    func matchingNodes(_ search: String) -> [TagGraphNode] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return nodes.filter { needle.isEmpty || $0.name.localizedStandardContains(needle) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }
}
