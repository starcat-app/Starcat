//
//  RepoListView.swift
//  Starcat
//
//  中栏：仓库列表视图。
//
//  职责：
//  - 渲染 HomeViewModel.items，每行调度到 RepoRowView
//  - 响应行选中 → 写入 HomeViewModel.selectedRepo
//  - 空 / 加载 / 错误状态友好展示
//
//  设计约束：
//  - 用 SwiftUI List + selection binding，原生体验最佳
//  - 行密度由 AppSettings 注入，密度切换实时生效（@Observable 通知）
//

import SwiftUI

struct RepoListView: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var vm = viewModel

        Group {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.loadError, viewModel.items.isEmpty {
                emptyState(systemImage: "exclamationmark.triangle", title: "加载失败", subtitle: error)
            } else if viewModel.items.isEmpty {
                emptyState(systemImage: emptyImage, title: emptyTitle, subtitle: emptySubtitle)
            } else if viewModel.isMultiSelectMode {
                // W4 A5：多选模式 List binding 类型不同，必须分开渲染
                multiSelectList($vm.multiSelectedRepoIDs)
            } else {
                listContent($vm.selectedRepoID)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationSubtitle(navigationSubtitle)
        // W4 A5：多选模式底部浮动操作栏
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewModel.isMultiSelectMode {
                BatchActionBar()
            }
        }
    }

    // MARK: - 列表主体

    /// 关键写法：`List(selection: Binding<Repo.ID?>)` + `ForEach(items)`，
    /// 不显式写 `.tag(...)`。ForEach 看到 `Repo: Identifiable` 会自动使用 `repo.id`
    /// 作为每行的 selection identifier，selection binding 类型 (`Int64?`) 与之严格匹配，
    /// SwiftUI 内部无需再做 Hashable/Equatable 校对，是 macOS List selection 的最稳写法。
    private func listContent(_ selection: Binding<Int64?>) -> some View {
        List(selection: selection) {
            ForEach(viewModel.items) { repo in
                RepoRowView(repo: repo, density: settings.listDensity)
            }
        }
        .id(viewModel.itemsRevision)
        .transaction { transaction in
            transaction.animation = nil
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    /// W4 A5：多选 List。binding 类型 `Set<Int64>` → SwiftUI 自动启用多选行为。
    /// macOS 用户用 Cmd / Shift 加选，行级 checkbox 不必显式画。
    private func multiSelectList(_ selection: Binding<Set<Int64>>) -> some View {
        List(selection: selection) {
            ForEach(viewModel.items) { repo in
                RepoRowView(repo: repo, density: settings.listDensity)
            }
        }
        .id(viewModel.itemsRevision)
        .transaction { transaction in
            transaction.animation = nil
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private var navigationSubtitle: String {
        if viewModel.isMultiSelectMode {
            return "已选 \(viewModel.multiSelectedRepoIDs.count) / \(viewModel.items.count)"
        }
        return "\(viewModel.items.count) 个仓库"
    }

    // MARK: - 标题派生

    private var navigationTitle: String {
        if viewModel.isSearching {
            return "搜索：\(viewModel.searchQuery)"
        }
        return viewModel.selection.displayName
    }

    // MARK: - 空状态

    private var emptyImage: String {
        if viewModel.isSearching { return "magnifyingglass" }
        switch viewModel.selection {
        case .allStars:  return "star"
        case .untagged:  return "tag.slash"
        case .language:  return "chevron.left.forwardslash.chevron.right"
        case .tag:       return "tag.slash"
        }
    }

    private var emptyTitle: String {
        if viewModel.isSearching { return "无匹配结果" }
        switch viewModel.selection {
        case .allStars:        return "还没有 Stars"
        case .untagged:        return "所有仓库都已分类"
        case .language:        return "该语言下暂无仓库"
        case .tag:             return "该标签下暂无仓库"
        }
    }

    private var emptySubtitle: String {
        if viewModel.isSearching { return "试试别的关键词" }
        switch viewModel.selection {
        case .allStars:        return "点击右上角同步按钮拉取 GitHub Stars"
        case .untagged:        return "新增 Stars 默认进这里"
        case .language:        return "刷新或同步后试试"
        case .tag:             return "在仓库详情页给它打上该标签"
        }
    }

    private func emptyState(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
