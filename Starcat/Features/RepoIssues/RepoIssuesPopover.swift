//
//  RepoIssuesPopover.swift
//  Starcat
//
//  详情页「Issues」入口的列表浮层（宽 600 / 最高 500，约 5 行可见，内部滚动）。
//
//  布局（对齐 dong4j 2026-11-01 设计图）：
//  顶部（标题 + 仓库全名 + 新建 Issue）→ 搜索 → 筛选（未解决/已关闭 + 排序标注）→
//  列表（状态图标 + 标题 + 标签 / 编号·作者·时间 + 评论数）→ 底部（已加载进度 + 在 GitHub 中打开）。
//
//  关键约束：
//  - 搜索、筛选、新建按钮固定在浮层上下边缘，只有列表滚动（设计要求）。
//  - 滚动分页走共享 `automaticListPagination`（预取窗口见 `ListPaginationPolicy`），
//    客户端过滤可能把已加载页滤空，所以再挂 `automaticListPaginationFill` 补齐可见窗口。
//  - 行点击 = 浏览器打开该 Issue；浮层本身不承载 Issue 详情。
//  - popover 是独立窗口层级，根视图必须挂 `.appLocaleEnvironment()`（i18n 军规）；
//    Esc 只关浮层不冒泡（`onExitCommand`）。
//  - 提交成功回列表高亮：`vm.highlightIssueNumber` 驱动行底色，4 秒自动清除。
//

import SwiftUI

struct RepoIssuesPopover: View {
    let repo: Repo
    @Bindable var viewModel: RepoIssuesViewModel
    /// 点击「新建 Issue」：先收起浮层（父级置 false），再打开新建 Sheet。
    let onNewIssue: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 设计图定宽 600；高度上限 500，内容不足时收缩。
    private static let popoverWidth: CGFloat = 600
    private static let popoverMaxHeight: CGFloat = 500

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            filterBar
            Divider()
            issueList
            Divider()
            footer
        }
        .frame(width: Self.popoverWidth)
        .frame(maxHeight: Self.popoverMaxHeight)
        .presentationBackground(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { dismiss() }
        .appLocaleEnvironment()
        .task(id: repo.fullName) {
            viewModel.prepare(owner: repo.owner, repo: repo.name)
            await viewModel.loadFirstPageIfNeeded()
            await viewModel.refreshCountsIfNeeded()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(String.l10n("repo.issues.popover.title", defaultValue: "Issues"))
                    .font(.headline)
                Text(verbatim: repo.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(repo.fullName)
            }
            Spacer()
            Button {
                onNewIssue()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text(String.l10n("repo.issues.popover.newIssue", defaultValue: "新建 Issue"))
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - 搜索

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                String.l10n("repo.issues.search.placeholder", defaultValue: "搜索标题或 Issue 编号"),
                text: $viewModel.searchText
            )
            .textFieldStyle(.plain)
            .onSubmit { viewModel.searchTextChanged() }
            .onChange(of: viewModel.searchText) { _, _ in
                viewModel.searchTextChanged()
            }
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                    viewModel.searchTextChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(String.l10n("common.clear", defaultValue: "清空"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.2))
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: - 筛选

    private var filterBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(
                get: { viewModel.stateFilter },
                set: { viewModel.setStateFilter($0) }
            )) {
                filterTag(.open)
                filterTag(.closed)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 250)

            Spacer()

            // 排序固定为「最新更新」（API 侧 sort=updated），这里只做标注不做切换。
            HStack(spacing: 3) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(String.l10n("repo.issues.sort.updated", defaultValue: "最新更新"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// 筛选 tab 文案 + 精确计数（Search API，不含 PR；计数未就绪时只显示文字）。
    private func filterTag(_ state: GitHubRepoIssueState) -> some View {
        let count: Int? = switch state {
        case .open: viewModel.openCount
        case .closed: viewModel.closedCount
        }
        return Text(count.map { countText in
            String.l10n(
                state == .open ? "repo.issues.filter.open" : "repo.issues.filter.closed",
                defaultValue: state == .open ? "未解决" : "已关闭"
            ) + " \(count)"
        } ?? String.l10n(
            state == .open ? "repo.issues.filter.open" : "repo.issues.filter.closed",
            defaultValue: state == .open ? "未解决" : "已关闭"
        ))
        .tag(state)
    }

    // MARK: - 列表

    private var issueList: some View {
        let displayed = viewModel.displayedIssues
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if displayed.isEmpty {
                    emptyState
                        .frame(minHeight: 180, maxHeight: .infinity)
                        // 客户端过滤把已加载页滤空时，靠 fill 继续翻底层分页补齐可见窗口。
                        .automaticListPaginationFill(
                            visibleItemCount: displayed.count,
                            loadedItemCount: viewModel.issues.count,
                            hasMore: viewModel.hasMore,
                            isLoading: viewModel.isLoading || viewModel.isLoadingMore,
                            identity: "repo-issues-\(repo.fullName)"
                        ) {
                            await viewModel.loadMoreIfNeeded()
                        }
                } else {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, issue in
                        RepoIssueRow(
                            issue: issue,
                            isHighlighted: viewModel.highlightIssueNumber == issue.number
                        )
                        .automaticListPagination(
                            appearingIndex: index,
                            visibleItemCount: displayed.count,
                            loadedItemCount: viewModel.issues.count,
                            hasMore: viewModel.hasMore,
                            isLoading: viewModel.isLoading || viewModel.isLoadingMore,
                            identity: "repo-issues-\(repo.fullName)"
                        ) {
                            await viewModel.loadMoreIfNeeded()
                        }
                        if index < displayed.count - 1 {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.regular)
            } else if viewModel.isRemoteSearching, displayed.isEmpty {
                ProgressView()
                    .controlSize(.regular)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let query = viewModel.normalizedSearchText
        VStack(spacing: 8) {
            if let errorMessage = viewModel.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(verbatim: errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String.l10n("repo.issues.error.retry", defaultValue: "重试")) {
                    Task { await viewModel.loadFirstPage() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusEffectDisabled()
            } else if viewModel.remoteSearchErrorMessage != nil && !query.isEmpty {
                // 客户端过滤为空 + 远程兜底失败：保留兜底错误提示。
                Text(verbatim: viewModel.remoteSearchErrorMessage ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if !query.isEmpty {
                Text(String.l10n("repo.issues.empty.noResults", defaultValue: "没有匹配的 Issue"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(String.l10n("repo.issues.empty.noIssues", defaultValue: "还没有 Issue"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            footerProgressText
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let url = viewModel.repoIssuesPageURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text(String.l10n("repo.issues.footer.openInGitHub", defaultValue: "在 GitHub 中打开"))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// 左下角进度：远程搜索结果 = "共 n 条"；普通列表 = "已加载 x / 共 y"（y 为精确计数）。
    @ViewBuilder
    private var footerProgressText: some View {
        if viewModel.remoteSearchResults != nil {
            Text(String.l10n("repo.issues.footer.remoteResultFormat", defaultValue: "共 %@ 条匹配")
                .replacingOccurrences(of: "%@", with: "\(viewModel.remoteSearchTotalCount)"))
        } else if viewModel.stateFilter == .open, let openCount = viewModel.openCount {
            Text(String.l10n("repo.issues.footer.loadedFormat", defaultValue: "已加载 %d / 共 %d")
                .replacingOccurrences(of: "%d", with: "\(viewModel.issues.count)")
                .replacingOccurrences(of: "%@", with: "\(openCount)"))
        } else {
            Text(String.l10n("repo.issues.footer.loadedCountFormat", defaultValue: "已加载 %d 条")
                .replacingOccurrences(of: "%d", with: "\(viewModel.issues.count)"))
        }
    }
}

// MARK: - 列表行

/// 单条 Issue 行：状态图标 + 标题 + 标签；第二行编号·作者·时间；右侧评论数。
/// 整行是按钮，点击在浏览器打开该 Issue。
private struct RepoIssueRow: View {
    let issue: GitHubRepoIssue
    let isHighlighted: Bool

    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(issue.htmlURL)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                stateIcon
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: issue.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        ForEach(issue.labels.prefix(3), id: \.name) { label in
                            issueLabelCapsule(label)
                        }
                    }

                    HStack(spacing: 4) {
                        Text("#\(issue.number)")
                            .font(.system(size: 11, design: .monospaced))
                        if let author = issue.authorLogin {
                            Text(verbatim: author)
                        }
                        // SwiftUI 原生相对时间（"2 小时前"），自动跟随语言并实时刷新。
                        if let updatedAt = issue.updatedAt {
                            Text(updatedAt, style: .relative)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                if issue.commentsCount > 0 {
                    // 非 icon-only 模式自带子视图合并朗读，无需单独 accessibilityLabel。
                    MetaBadge(
                        systemImage: "bubble.right",
                        text: "\(issue.commentsCount)",
                        tint: .secondary
                    )
                    .padding(.top, 1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .background(rowBackground)
    }

    private var rowBackground: some View {
        Group {
            if isHighlighted {
                Color.accentColor.opacity(0.14)
            } else if isHovered {
                Color.primary.opacity(0.05)
            } else {
                Color.clear
            }
        }
        .animation(.easeOut(duration: 0.18), value: isHighlighted)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    /// GitHub 惯例配色：open 绿圈 / closed 紫色对勾。
    private var stateIcon: some View {
        Group {
            switch issue.state {
            case .open:
                Image(systemName: "circle.circle")
                    .foregroundStyle(.green)
            case .closed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.purple)
            }
        }
        .font(.system(size: 14, weight: .medium))
    }

    /// 标签胶囊：GitHub label 色（6 位 hex）做 14% 底 + 实色文字，与项目胶囊风格一致。
    private func issueLabelCapsule(_ label: GitHubRepoIssueLabel) -> some View {
        let tint = issueLabelTint(label.colorHex)
        return Text(verbatim: label.name)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    /// GitHub label 色（不带 `#` 的 6 位 hex）→ SwiftUI Color。
    /// 解析失败（非法长度 / 非十六进制）回退中性灰，行不因脏数据渲染失败。
    private func issueLabelTint(_ colorHex: String) -> Color {
        var value: UInt64 = 0
        guard Scanner(string: colorHex).scanHexInt64(&value),
              let rgb = UInt32(exactly: value & 0xFF_FF_FF),
              colorHex.count == 6
        else { return Color(nsColor: .secondaryLabelColor) }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
