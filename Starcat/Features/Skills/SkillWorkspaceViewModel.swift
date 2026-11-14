//
//  SkillWorkspaceViewModel.swift
//  Starcat
//
//  独立 Skill 窗口的导航状态。只消费完整本机库快照，
//  窗口显式显示后才创建索引会话，不把演示条目混入生产模型。
//

import Foundation
import Observation

/// 库级筛选不使用仓库详情安装器的“待安装”等状态，避免混淆本机库与下载会话。
enum SkillWorkspaceFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case managed
    case external
    case updates
    case attention

    var id: Self { self }

    var titleKey: String {
        switch self {
        case .all: "repo.skills.list.all"
        case .managed: "skills.workspace.filter.managed"
        case .external: "skills.workspace.filter.external"
        case .updates: "skills.workspace.filter.updates"
        case .attention: "skills.workspace.filter.attention"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .managed: "shippingbox"
        case .external: "folder"
        case .updates: "arrow.down.circle"
        case .attention: "exclamationmark.circle"
        }
    }
}

/// 目录树中的库筛选、Agent 与来源互斥，避免多组选择同时生效却无法解释。
enum SkillWorkspaceNavigation: Hashable, Sendable {
    case library(SkillWorkspaceFilter)
    case agent(String)
    case source(String)
}

/// 刷新失败不代表旧条目消失；状态与条目快照分别更新。
enum SkillWorkspaceLoadState: Equatable, Sendable {
    case ready
    case loading
    case failed(String)
    case partial(String)

    var message: String? {
        switch self {
        case .failed(let message), .partial(let message): message
        case .ready, .loading: nil
        }
    }
}

/// 应用级协调器持有此会话，关闭主窗口或切换 GitHub 账号不会丢失本机导航。
@MainActor
@Observable
final class SkillWorkspaceViewModel {
    @ObservationIgnored private(set) var libraryEnvironment: SkillLibraryEnvironment?
    /// List 的单选绑定允许系统短暂清空选择；读取时回退到全部条目。
    var navigation: SkillWorkspaceNavigation? = .library(.all) {
        didSet { rebuildVisibleItems() }
    }
    var searchText = "" {
        didSet { rebuildVisibleItems() }
    }
    var selectedIDs: Set<UUID> = []
    var importPresentation: SkillImportPresentation?
    private(set) var items: [SkillLibraryItem] = []
    private(set) var visibleItems: [SkillLibraryItem] = []
    private(set) var loadState: SkillWorkspaceLoadState = .ready
    private(set) var contentRefreshID = UUID()
    private(set) var agentNames: [String] = []
    private(set) var sources: [String] = []
    private(set) var filterCounts: [SkillWorkspaceFilter: Int] = [:]

    var selectedItem: SkillLibraryItem? {
        guard selectedIDs.count == 1, let selectedID = selectedIDs.first else { return nil }
        return visibleItems.first { $0.id == selectedID }
    }

    /// 接受完整值快照，在 UI body 外集中重建导航计数和可见列表。
    func applySnapshot(_ items: [SkillLibraryItem], state: SkillWorkspaceLoadState = .ready) {
        self.items = items
        loadState = state
        if state != .loading { contentRefreshID = UUID() }
        agentNames = Set(items.flatMap { $0.locations.flatMap(\.agentNames) }).sorted()
        sources = Set(items.compactMap(\.source)).sorted()
        filterCounts = Dictionary(uniqueKeysWithValues: SkillWorkspaceFilter.allCases.map { filter in
            (filter, items.filter { matches($0, filter: filter) }.count)
        })
        rebuildVisibleItems()
    }

    /// 不清空上次成功结果，权限失败或离线仍保留可见的诊断上下文。
    func setLoadState(_ state: SkillWorkspaceLoadState) {
        loadState = state
    }

    /// 默认模型与 Preview 不读取本机路径；仅真实 Scene 的显示生命周期调用此入口。
    func startLibrary() {
        do {
            if libraryEnvironment == nil { libraryEnvironment = try SkillLibraryEnvironment(viewModel: self) }
            libraryEnvironment?.start()
        } catch {
            setLoadState(.failed(error.localizedDescription))
        }
    }

    func stopLibrary() { libraryEnvironment?.stop() }
    func refreshLibrary() { libraryEnvironment?.refresh() }

    /// 筛选变化后收敛选择，后续批量操作不会误处理已离开屏幕的隐藏目标。
    private func rebuildVisibleItems() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleItems = items.filter { item in
            let matchesNavigation: Bool
            switch navigation ?? .library(.all) {
            case .library(let filter):
                matchesNavigation = matches(item, filter: filter)
            case .agent(let name):
                matchesNavigation = item.locations.contains { $0.agentNames.contains(name) }
            case .source(let source):
                matchesNavigation = item.source == source
            }
            let searchable = [item.name, item.summary, item.source ?? ""].joined(separator: "\n")
            return matchesNavigation && (query.isEmpty || searchable.range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil)
        }
        selectedIDs.formIntersection(Set(visibleItems.map(\.id)))
    }

    private func matches(_ item: SkillLibraryItem, filter: SkillWorkspaceFilter) -> Bool {
        switch filter {
        case .all: true
        case .managed: item.managementKind == .managed
        case .external: item.managementKind == .external
        case .updates: item.hasUpdate
        case .attention: item.diagnostic != nil
        }
    }
}
