// 搜索不筛掉画布中的节点或连线。
import Foundation

extension TagGraphSnapshot {
    /// 图谱规模可达数千仓库，浮层只需收集最先匹配的少量结果。
    func matchingNodes(_ search: String, limit: Int = 20) -> [TagGraphNode] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return Array(nodes.lazy.filter { $0.name.localizedStandardContains(needle) }.prefix(limit))
    }
}
