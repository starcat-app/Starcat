// 订阅当前账户的归属索引。每个标签的展示范围和选择只在当前图谱会话有效。
import Foundation
import GRDB
import Observation

/// 取消订阅后仍可能有回调在主队列等候。每次绑定或重试推进代次，丢弃旧账户的结果。
@MainActor @Observable final class TagGraphViewModel {
    static let rootID = "app:starcat"
    private static let firstPageSize = 30
    private static let pageSize = 50

    private var index: TagGraphPresentationIndex?
    var graph: TagGraphSnapshot? { index?.graph }
    private(set) var displayed: TagGraphSnapshot?
    private(set) var selectedID: String?
    private(set) var selectionRevision = 0
    private(set) var renderedMembershipCount = 0
    private(set) var revision = 0
    private(set) var generation = 0
    private(set) var failed = false
    @ObservationIgnored private var pageLimits: [String: Int] = [:]
    @ObservationIgnored private var locatedRepositories: [String: Set<String>] = [:]
    private var displayedCounts: [String: Int] = [:]
    @ObservationIgnored private var reader: (any DatabaseReader)?
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var isCurrent: () -> Bool = { false }

    /// 宿主验证登录与数据库属于同一账户后绑定，旧快照先清除。
    func bind(reader: any DatabaseReader, isCurrent: @escaping () -> Bool) {
        clear()
        self.reader = reader
        self.isCurrent = isCurrent
        observe()
    }

    func clear() {
        observation?.cancel()
        observation = nil
        reader = nil
        isCurrent = { false }
        generation += 1
        index = nil
        displayed = nil
        displayedCounts = [:]
        pageLimits = [:]
        locatedRepositories = [:]
        select(nil)
        failed = false
    }

    func observe() {
        observation?.cancel()
        generation += 1
        let token = generation
        guard let reader, isCurrent() else { return }
        failed = false
        // GRDB 在数据库读取队列构造快照并比较内容；未改变的数据无需交付主线程。
        observation = ValueObservation.tracking { try TagGraphPresentationIndex.read(in: $0) }
            .removeDuplicates()
            .start(in: reader, scheduling: .async(onQueue: .main), onError: { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.accepts(generation: token) else { return }
                    self.failed = true
                }
            }, onChange: { [weak self] snapshot in
                MainActor.assumeIsolated { self?.apply(snapshot, generation: token) }
            })
    }

    func accepts(generation token: Int) -> Bool { token == generation && isCurrent() }

    func apply(_ next: TagGraphPresentationIndex, generation token: Int) {
        guard accepts(generation: token) else { return }
        index = next
        rebuildDisplay()
        failed = false
    }

    var selectedNode: TagGraphNode? { selectedID.flatMap { index?.nodesByID[$0] } }

    func tagCreationDate(_ id: String) -> Date? { index?.tagDates[id] }
    func totalCount(for tag: String) -> Int { index?.membersByTag[tag]?.count ?? 0 }
    func hasMore(for tag: String) -> Bool { renderedMembershipCount < totalCount(for: tag) }
    func isRevealing(_ tag: String) -> Bool {
        renderedMembershipCount < (displayedCounts[tag] ?? 0)
    }

    /// A → B → A 是两次独立选择。旧 A 卡片的回报不能更新新卡片。
    @discardableResult func select(_ id: String?) -> Bool {
        if let id, id != Self.rootID, displayed?.nodes.contains(where: { $0.id == id }) != true { return false }
        if selectedID != id {
            selectedID = id
            selectionRevision += 1
            resetRenderedProgress()
        }
        return true
    }

    func resetRenderedProgress() { renderedMembershipCount = 0 }

    func reportProgress(revision: Int, selectedID: String?, selectionRevision: Int, count: Int) {
        guard revision == self.revision, let selectedID, selectedID == self.selectedID,
              selectionRevision == self.selectionRevision, index?.nodesByID[selectedID]?.kind == .tag,
              (0...(displayedCounts[selectedID] ?? 0)).contains(count) else { return }
        if renderedMembershipCount != count { renderedMembershipCount = count }
    }

    /// 重复点击或上一批仍在入场时都沿用当前页。共享仓库只增加该标签自己的归属边。
    func loadMore(_ tag: String) {
        guard selectedID == tag, !isRevealing(tag), hasMore(for: tag) else { return }
        pageLimits[tag] = min(totalCount(for: tag), (displayedCounts[tag] ?? 0) + Self.pageSize)
        rebuildDisplay()
    }

    /// 搜索仍可查全库。定位未分页到的仓库时，只补入该仓库和一条真实归属。
    func locate(_ id: String) {
        if select(id) { return }
        guard let membership = index?.graph.edges.first(where: { $0.target == id }) else { return }
        let tag = membership.source
        locatedRepositories[tag, default: []].insert(id)
        pageLimits[tag] = (displayedCounts[tag] ?? 0) + 1
        rebuildDisplay()
        select(id)
    }

    private func rebuildDisplay() {
        guard let index else { return }
        var nodes = index.tags
        var edges: [TagGraphEdge] = []
        var includedRepos = Set<String>()
        var counts: [String: Int] = [:]
        for tag in index.tags {
            let members = index.membersByTag[tag.id] ?? []
            let limit = pageLimits[tag.id] ?? Self.firstPageSize
            let located = locatedRepositories[tag.id] ?? []
            // 搜索结果保证可定位。后续分页从其余仓库补足数量，不移除已入场项目。
            let extras = located.isEmpty ? [] : members.filter { located.contains($0.target) }
            let recent = members.lazy.filter { !located.contains($0.target) }.prefix(max(0, limit - extras.count))
            let page = Array(recent) + extras
            for edge in page where includedRepos.insert(edge.target).inserted {
                if let repo = index.nodesByID[edge.target] { nodes.append(repo) }
            }
            edges.append(contentsOf: page)
            counts[tag.id] = page.count
        }

        let next = TagGraphSnapshot(nodes: nodes, edges: edges)
        guard next != displayed else { return }
        displayed = next
        displayedCounts = counts
        revision += 1
        if !select(selectedID) { select(nil) }
        if let selectedID { renderedMembershipCount = min(renderedMembershipCount, counts[selectedID] ?? 0) }
    }
}
