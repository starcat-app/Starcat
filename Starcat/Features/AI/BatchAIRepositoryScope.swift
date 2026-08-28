//
//  BatchAIRepositoryScope.swift
//  Starcat
//
//  手动批量 AI 整理的仓库输入范围。
//
//  关键约束：顶部未分类横幅在用户确认开始时读取最新未分类全集；多选入口则固定使用
//  点击按钮当刻的仓库快照，避免用户打开配置 Sheet 后列表刷新导致任务范围漂移。
//

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
