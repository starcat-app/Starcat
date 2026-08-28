//
//  BatchAIRepositoryScope.swift
//  Starcat
//
//  手动批量 AI 整理的仓库输入范围。
//
//  关键约束：顶部未分类横幅在用户确认开始时读取最新未分类全集；多选入口则固定使用
//  点击按钮当刻的仓库快照，避免用户打开配置 Sheet 后列表刷新导致任务范围漂移。
//

import Foundation

enum BatchAIRepositoryScope {
    case allUntagged
    case selected([Repo])

    var isSelectionScoped: Bool {
        if case .selected = self { true } else { false }
    }

    func pendingCount(untaggedCount: Int) -> Int {
        switch self {
        case .allUntagged:
            max(0, untaggedCount)
        case .selected(let repositories):
            repositories.count
        }
    }

    /// 多选入口只保留数据库中没有任何标签关联的仓库，并保持用户原始选择顺序。
    ///
    /// 这里接收一次性批量查询结果，而不是逐仓读取标签，避免大量选择时产生 N+1 SQLite 查询。
    static func filterUntaggedRepositories(
        _ repositories: [Repo],
        tagAssignments: [Int64: [Tag]]
    ) -> [Repo] {
        repositories.filter { tagAssignments[$0.id]?.isEmpty != false }
    }

    /// 只有“全部未分类”需要延迟读取数据库；已选范围必须返回点击入口时的值快照。
    @MainActor
    func resolveRepositories(
        fetchUntagged: () async throws -> [Repo]
    ) async rethrows -> [Repo] {
        switch self {
        case .allUntagged:
            try await fetchUntagged()
        case .selected(let repositories):
            repositories
        }
    }
}

/// 批量标签配置 Sheet 的一次性展示载荷。
///
/// 仓库范围和跳过数必须作为同一个 `sheet(item:)` 参数传入，避免首次展示时
/// `sheet(isPresented:)` 的内容闭包读到上一轮的全部未分类状态。
struct BatchAIOptionsPresentation: Identifiable {
    let id = UUID()
    let scope: BatchAIRepositoryScope
    let skippedTaggedCount: Int

    var usesSelectedRepositories: Bool { scope.isSelectionScoped }

    func pendingCount(untaggedCount: Int) -> Int {
        scope.pendingCount(untaggedCount: untaggedCount)
    }
}
