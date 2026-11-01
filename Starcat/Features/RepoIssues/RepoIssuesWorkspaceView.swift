//
//  RepoIssuesWorkspaceView.swift
//  Starcat
//
//  Issues 工作台：左侧 Issue 列表 + 右侧详情 / 编辑区的大尺寸模态窗口
//  （约 1100-1200pt 宽、左栏 320pt，对齐 dong4j 2026-11-01 设计图）。
//
//  布局：
//  顶栏（Issues + 仓库 ｜ 刷新 + 新建 Issue + 关闭）→ 左栏（搜索 / 未解决·已关闭 /
//  列表 / 底部计数）+ 右栏（详情态：标题头部 + Markdown 正文 + 评论时间线 + 底部评论框；
//  新建态：标题 + 描述表单 + 发布账号 footer）。
//
//  关键约束：
//  - 交互契约见 `RepoIssuesWorkspaceViewModel` 文件头（取消新建回跳、创建后自动选中、
//    草稿按仓库/issue 双轨、失败保留输入）。
//  - 左栏列表数据层完全复用 `RepoIssuesViewModel`（分页 / 筛选 / 搜索 / SWR 共享缓存）；
//    行内分页走共享 `automaticListPagination`。
//  - 新建态左侧列表保持可见且取消选中高亮（`isCreating` 优先于 selected 判断）。
//  - 评论 API / AI 生成 / Issue 模板 / 图片上传为业务阶段接线点（占位见 VM）。
//  - UI 规范：关闭走 `SheetCloseButton`、刷新走 `SyncIconButton`、plain Button 一律
//    `.focusEffectDisabled()`、分页走 `automaticListPagination`。
//

import MarkdownUI
import SwiftUI

struct RepoIssuesWorkspaceView: View {
    let repo: Repo
    let listViewModel: RepoIssuesViewModel

    @State private var viewModel: RepoIssuesWorkspaceViewModel

    init(
        repo: Repo,
        listViewModel: RepoIssuesViewModel,
        inbox: GitHubNotificationInboxService,
        threadRepository: any GitHubNotificationThreadRepositoryProtocol,
        apiClient: any GitHubAPIClientProtocol,
        aiService: RepoAIInsightService
    ) {
        self.repo = repo
        self.listViewModel = listViewModel
        _viewModel = State(
            initialValue: RepoIssuesWorkspaceViewModel(
                repo: repo,
                listViewModel: listViewModel,
                inbox: inbox,
                threadRepository: threadRepository,
                apiClient: apiClient,
                aiService: aiService
            )
        )
    }

    var body: some View {
        RepoIssuesWorkspaceContent(viewModel: viewModel)
            .task(id: repo.fullName) {
                // 旧浮层迁移时漏掉的锚点：VM 是挂载时创建的，owner/repoName 为空，
                // 必须 prepare 复位到当前仓库，否则 loadFirstPage 的空仓库守卫静默返回
                //（表现为「还没有 Issue / 已加载 0 条」且无任何报错）。
                viewModel.listViewModel.prepare(owner: repo.owner, repo: repo.name)
                await viewModel.listViewModel.loadFirstPageIfNeeded()
                await viewModel.listViewModel.refreshCountsIfNeeded()
                viewModel.loadCreateDraftIfNeeded()
                viewModel.autoSelectFirstIssueIfNeeded()
            }
            .onDisappear {
                viewModel.flushCreateDraft()
            }
            // 评论成功 / hydrate 完成：重建右栏详情项并同步左栏评论数（交互契约 ③）。
            .onReceive(NotificationCenter.default.publisher(for: .githubNotificationInboxDidChange)) { _ in
                Task { await viewModel.reloadDetailAfterInboxChange() }
            }
    }

}

/// 工作台内容（Preview 直接以种子 VM 实例化，便于 UI 迭代）。
struct RepoIssuesWorkspaceContent: View {
    @State var viewModel: RepoIssuesWorkspaceViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 尺寸（2026-11-01 dong4j 反馈首版过大）：宽 ~1040、高 ~660，按宿主屏幕可见区钳制。
    private static var workspaceSize: CGSize {
        let visible = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let width = min(1_040, max(880, visible.width - 200))
        let height = min(660, max(520, visible.height - 220))
        return CGSize(width: width, height: height)
    }

    private static let leftColumnWidth: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                leftColumn
                Divider()
                rightPane
            }
        }
        .frame(width: Self.workspaceSize.width, height: Self.workspaceSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .appLocaleEnvironment()
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
            Text(String.l10n("repo.issues.popover.title", defaultValue: "Issues"))
                .font(.headline)
            Text(verbatim: viewModel.repo.fullName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(viewModel.repo.fullName)
            Spacer()
            SyncIconButton(
                isRefreshing: viewModel.listViewModel.isLoading,
                tooltip: String.l10n("repo.issues.workspace.refresh", defaultValue: "刷新 Issues")
            ) {
                viewModel.refreshAll()
            }
            Button {
                // 过渡动画必须由状态变更点驱动（.animation(value:) 兜底实测不够）。
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    viewModel.startCreating()
                }
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
            .disabled(viewModel.isCreating)
            SheetCloseButton {
                viewModel.flushCreateDraft()
                dismiss()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - 左栏

    private var leftColumn: some View {
        VStack(spacing: 0) {
            searchField
            filterBar
            sortHint
            Divider()
            issueList
            Divider()
            listFooter
        }
        .frame(width: Self.leftColumnWidth)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                String.l10n("repo.issues.search.placeholder", defaultValue: "搜索标题或 Issue 编号"),
                text: Binding(
                    get: { viewModel.listViewModel.searchText },
                    set: { viewModel.listViewModel.searchText = $0 }
                )
            )
            .textFieldStyle(.plain)
            .onSubmit { viewModel.listViewModel.searchTextChanged() }
            .onChange(of: viewModel.listViewModel.searchText) { _, _ in
                viewModel.listViewModel.searchTextChanged()
            }
            if !viewModel.listViewModel.searchText.isEmpty {
                Button {
                    viewModel.listViewModel.searchText = ""
                    viewModel.listViewModel.searchTextChanged()
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
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            RepoIssuesStateFilter(
                selection: Binding(
                    get: { viewModel.listViewModel.stateFilter },
                    set: { viewModel.listViewModel.setStateFilter($0) }
                ),
                openCount: viewModel.listViewModel.openCount,
                closedCount: viewModel.listViewModel.closedCount
            )
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// 排序固定「最新更新」（API 侧 sort=updated），只做标注不做切换。
    private var sortHint: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.down")
                .font(.system(size: 9, weight: .semibold))
            Text(String.l10n("repo.issues.sort.updated", defaultValue: "最新更新"))
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var issueList: some View {
        let displayed = viewModel.listViewModel.displayedIssues
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if viewModel.listViewModel.isLoading && displayed.isEmpty {
                    RepoIssuesListSkeleton()
                } else if displayed.isEmpty {
                    emptyListState
                } else {
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, issue in
                        RepoIssueListRow(
                            issue: issue,
                            isSelected: !viewModel.isCreating
                                && viewModel.selectedIssue?.id == issue.id,
                            onSelect: { viewModel.select(issue) }
                        )
                        .automaticListPagination(
                            appearingIndex: index,
                            visibleItemCount: displayed.count,
                            loadedItemCount: viewModel.listViewModel.issues.count,
                            hasMore: viewModel.listViewModel.hasMore,
                            isLoading: viewModel.listViewModel.isLoading
                                || viewModel.listViewModel.isLoadingMore,
                            identity: "repo-issues-\(viewModel.repo.fullName)"
                        ) {
                            await viewModel.listViewModel.loadMoreIfNeeded()
                        }
                        if index < displayed.count - 1 {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
        }
        .onChange(of: viewModel.listViewModel.displayedIssues) { _, issues in
            // 列表落地 / 换筛选后，未选中时自动选第一条（新建态不打断）。
            if issues.first != nil {
                viewModel.autoSelectFirstIssueIfNeeded()
            }
        }
    }

    @ViewBuilder
    private var emptyListState: some View {
        let query = viewModel.listViewModel.normalizedSearchText
        VStack(spacing: 8) {
            if let errorMessage = viewModel.listViewModel.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                Text(verbatim: errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button(String.l10n("repo.issues.error.retry", defaultValue: "重试")) {
                    Task { await viewModel.listViewModel.loadFirstPage() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focusEffectDisabled()
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
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    /// 左栏底部计数：精确计数就绪显示「N 个未解决/已关闭 Issue」，否则显示已加载数。
    @ViewBuilder
    private var listFooter: some View {
        Group {
            switch viewModel.listViewModel.stateFilter {
            case .open:
                if let openCount = viewModel.listViewModel.openCount {
                    Text(String.l10n("repo.issues.workspace.footerOpen", defaultValue: "%d 个未解决 Issue")
                        .replacingOccurrences(of: "%d", with: "\(openCount)"))
                } else {
                    loadedCountText
                }
            case .closed:
                if let closedCount = viewModel.listViewModel.closedCount {
                    Text(String.l10n("repo.issues.workspace.footerClosed", defaultValue: "%d 个已关闭 Issue")
                        .replacingOccurrences(of: "%d", with: "\(closedCount)"))
                } else {
                    loadedCountText
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var loadedCountText: some View {
        Text(String.l10n("repo.issues.footer.loadedCountFormat", defaultValue: "已加载 %d 条")
            .replacingOccurrences(of: "%d", with: "\(viewModel.listViewModel.issues.count)"))
    }

    // MARK: - 右栏

    @ViewBuilder
    private var rightPane: some View {
        Group {
            if viewModel.isCreating {
                RepoIssueCreatePane(viewModel: viewModel)
                    .transition(.opacity)
            } else if viewModel.detailItem != nil {
            // 完整复用活动-issues 详情页（2026-11-01 dong4j 决策）：
            // 评论时间线 / AI 总结 / AI 写回复 / 翻译 / 关闭重开全部由它自带。
            GitHubNotificationDetailView(selectedItem: Binding(
                get: { viewModel.detailItem },
                set: { viewModel.detailItem = $0 }
            ), showsHeroTint: false)
            .background(Color(nsColor: .windowBackgroundColor))
            .transition(.opacity)
            } else {
                emptySelectionPlaceholder
                    .transition(.opacity)
            }
        }
        // 详情 / 新建切换过渡兜底：创建成功等 VM 内部触发的切换也走动画
        // （尊重 reduceMotion：时长归零瞬切）。
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: viewModel.paneMode)
    }

    private var emptySelectionPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(String.l10n("repo.issues.workspace.emptySelection", defaultValue: "选择左侧 Issue 查看详情"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 左栏列表行

/// 工作台左栏行：状态图标 + 标题 / #编号·时间 / 标签；右侧评论数。
/// 选中态 = 左侧 3pt accent 条 + accent 浅底（对齐设计图）。
private struct RepoIssueListRow: View {
    let issue: GitHubRepoIssue
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .opacity(isSelected ? 1 : 0)

                HStack(alignment: .top, spacing: 10) {
                    stateIcon
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: issue.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        // 标签与编号同一行（2026-11-01 dong4j 反馈）；0 评论也带徽标保持恒定行宽。
                        HStack(spacing: 4) {
                            Text("#\(issue.number)")
                                .font(.system(size: 11, design: .monospaced))
                            if let updatedAt = issue.updatedAt {
                                Text(updatedAt, style: .relative)
                            }
                            ForEach(issue.labels.prefix(2), id: \.name) { label in
                                issueLabelCapsule(label)
                            }
                            Spacer(minLength: 8)
                            MetaBadge(
                                systemImage: "bubble.right",
                                text: "\(issue.commentsCount)",
                                tint: .secondary
                            )
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }
                .padding(.leading, 11)
                .padding(.trailing, 12)
                .padding(.vertical, 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .background(rowBackground)
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                Color.accentColor.opacity(0.10)
            } else if isHovered {
                Color.primary.opacity(0.05)
            } else {
                Color.clear
            }
        }
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

    /// 标签胶囊：GitHub label 色（6 位 hex）做 14% 底 + 实色文字。
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

// MARK: - 状态筛选控件

/// 「未解决 / 已关闭」双段切换。
///
/// 为什么不用系统 `Picker(.segmented)`：macOS popover 内 NSSegmentedControl 按
/// intrinsic 宽度渲染并顶穿 HStack padding（2026-11-01 dong4j 截图：段落贴边、
/// `.frame(width:)` 压不住）。视觉对齐共享件 `CountedSegmentedControl`
/// （accent 选中底 + 白字 + 容器胶囊），但计数支持 nil——Search API 计数未就绪 /
/// 失败时只显示标题，不显示误导性的 0。
struct RepoIssuesStateFilter: View {
    @Binding var selection: GitHubRepoIssueState
    /// Search API 精确计数（不含 PR）；nil = 未就绪，段内只显示标题。
    let openCount: Int?
    let closedCount: Int?

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedItem: GitHubRepoIssueState?

    var body: some View {
        HStack(spacing: 0) {
            segmentButton(.open, count: openCount)
            segmentButton(.closed, count: closedCount)
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(colorScheme == .dark
                      ? StarcatSurface.panel(colorScheme: colorScheme)
                      : Color.primary.opacity(0.06))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String.l10n("repo.issues.popover.title", defaultValue: "Issues")))
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
    }

    /// 整段一个按钮：标题与计数不拆成两个点击目标。
    private func segmentButton(_ state: GitHubRepoIssueState, count: Int?) -> some View {
        Button {
            selection = state
        } label: {
            HStack(spacing: 5) {
                Text(String.l10n(
                    state == .open ? "repo.issues.filter.open" : "repo.issues.filter.closed",
                    defaultValue: state == .open ? "未解决" : "已关闭"
                ))
                if let count {
                    Text(verbatim: count.formatted())
                        .monospacedDigit()
                }
            }
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(selection == state ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selection == state ? Color.accentColor : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedItem, equals: state)
        .accessibilityAddTraits(selection == state ? .isSelected : [])
    }

    /// 保留方向键切换体验，并同步焦点，避免随后按空格又选回旧项。
    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let states: [GitHubRepoIssueState] = [.open, .closed]
        guard let index = states.firstIndex(of: focusedItem ?? selection) else { return .ignored }
        let next = index + offset
        guard states.indices.contains(next) else { return .handled }
        selection = states[next]
        focusedItem = states[next]
        return .handled
    }
}

// MARK: - 左栏加载骨架

/// 列表加载骨架：对齐真实行布局（状态圆 + 标题条 + 元信息条 + 标签条），
/// 配色 / shimmer 走共享 SkeletonPalette，固定 6 行铺满左栏可视区。
private struct RepoIssuesListSkeleton: View {
    private static let rowCount = 6

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SkeletonAnimatedPhase { phase in
            let palette = SkeletonPalette.forColorScheme(colorScheme)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<Self.rowCount, id: \.self) { index in
                    if index > 0 {
                        Divider().padding(.leading, 34)
                    }
                    row(index: index, phase: phase, palette: palette)
                }
            }
        }
    }

    private func row(index: Int, phase: Double, palette: SkeletonPalette) -> some View {
        let offset = Double(index) * 0.08
        return HStack(alignment: .top, spacing: 10) {
            SkeletonBlock(
                width: 14,
                height: 14,
                cornerRadius: 7,
                phase: phase,
                phaseOffset: offset,
                palette: palette
            )
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBlock(
                    width: 140 + CGFloat(index % 3) * 30,
                    height: 12,
                    cornerRadius: 3,
                    phase: phase,
                    phaseOffset: offset + 0.02,
                    palette: palette
                )
                SkeletonBlock(
                    width: 110,
                    height: 9,
                    cornerRadius: 3,
                    phase: phase,
                    phaseOffset: offset + 0.04,
                    palette: palette
                )
            }
            Spacer(minLength: 8)
            SkeletonBlock(
                width: 26,
                height: 12,
                cornerRadius: 6,
                phase: phase,
                phaseOffset: offset + 0.06,
                palette: palette
            )
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
    }
}

#if DEBUG

// MARK: - SwiftUI Preview（UI 调整专用样例数据，生产路径不触碰）

private extension RepoIssuesWorkspaceView {

    static func makePreviewRepo() -> Repo {
        Repo(
            id: 289,
            owner: "starcat-app",
            name: "Starcat",
            fullName: "starcat-app/Starcat",
            description: nil,
            language: "Swift",
            starsCount: 2_064,
            forksCount: 53,
            watchersCount: 53,
            topics: nil,
            license: nil,
            homepage: nil,
            htmlUrl: "https://github.com/starcat-app/Starcat",
            cloneUrl: nil,
            sshUrl: nil,
            isPrivate: false,
            isFork: false,
            isArchived: false,
            isStarred: true,
            pushedAt: nil,
            createdAt: nil,
            updatedAt: nil,
            starredAt: nil,
            cachedAt: nil
        )
    }

    static func makePreviewIssue(
        id: Int64,
        number: Int,
        title: String,
        comments: Int,
        label: String?,
        hoursAgo: TimeInterval,
        body: String? = nil
    ) -> GitHubRepoIssue {
        GitHubRepoIssue(
            id: id,
            number: number,
            title: title,
            state: .open,
            body: body,
            htmlURL: URL(string: "https://github.com/starcat-app/Starcat/issues/\(number)")!,
            authorLogin: "dong4j",
            labels: label.map { [GitHubRepoIssueLabel(name: $0, colorHex: "0e8a16")] } ?? [],
            commentsCount: comments,
            createdAt: Date().addingTimeInterval(-hoursAgo * 3_600),
            updatedAt: Date().addingTimeInterval(-hoursAgo * 3_600),
            closedAt: nil
        )
    }

    static func makePreviewIssues() -> [GitHubRepoIssue] {
        [
            makePreviewIssue(
                id: 1, number: 128, title: "支持按仓库保存 Issue 草稿", comments: 2,
                label: "enhancement", hoursAgo: 2,
                body: """
                ## 使用场景
                在多个仓库之间切换时，希望保留尚未提交的 Issue 内容。

                ## 期望行为
                按仓库自动保存草稿，再次打开时继续编辑。
                """
            ),
            makePreviewIssue(id: 2, number: 126, title: "切换仓库后阅读位置丢失", comments: 2, label: "bug", hoursAgo: 5),
            makePreviewIssue(id: 3, number: 124, title: "为时间线增加日期范围筛选", comments: 5, label: "enhancement", hoursAgo: 26),
            makePreviewIssue(id: 4, number: 121, title: "MCP 服务启动状态未更新", comments: 1, label: "bug", hoursAgo: 30),
            makePreviewIssue(id: 5, number: 119, title: "增加快捷键说明", comments: 0, label: nil, hoursAgo: 50),
            makePreviewIssue(id: 6, number: 117, title: "导出仓库列表时保留分组", comments: 4, label: "enhancement", hoursAgo: 74),
        ]
    }

    static func makePreviewViewModel(startInCreateMode: Bool) -> RepoIssuesWorkspaceViewModel {
        let listVM = RepoIssuesViewModel(client: GitHubAPIClient())
        listVM.prepare(owner: "starcat-app", repo: "Starcat")
        listVM.seedPreviewIssues(makePreviewIssues(), openCount: 12, closedCount: 38)
        let vm = RepoIssuesWorkspaceViewModel(repo: makePreviewRepo(), listViewModel: listVM)
        if startInCreateMode {
            vm.startCreating()
        } else {
            vm.seedPreviewState(selected: makePreviewIssues()[0])
        }
        return vm
    }

    /// 评论框 / 发布账号 footer 读 `AuthSession` 环境；Preview 用被动 Mock（不触发登录恢复）。
    static func makePreviewAuthSession() -> AuthSession {
        AuthSession(
            oauthService: MockGithubOAuthService(simulatedDelay: 0),
            apiClient: GitHubAPIClient()
        )
    }
}

#Preview("Issues 工作台 · 详情态") {
    RepoIssuesWorkspaceContent(
        viewModel: RepoIssuesWorkspaceView.makePreviewViewModel(startInCreateMode: false)
    )
    .environment(RepoIssuesWorkspaceView.makePreviewAuthSession())
    .environment(\.locale, .init(identifier: "zh-CN"))
}

#Preview("Issues 工作台 · 新建态") {
    RepoIssuesWorkspaceContent(
        viewModel: RepoIssuesWorkspaceView.makePreviewViewModel(startInCreateMode: true)
    )
    .environment(RepoIssuesWorkspaceView.makePreviewAuthSession())
    .environment(\.locale, .init(identifier: "zh-CN"))
}

#endif
