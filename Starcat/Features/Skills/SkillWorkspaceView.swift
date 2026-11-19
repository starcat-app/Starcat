//
//  SkillWorkspaceView.swift
//  Starcat
//
//  独立 Skill 管理窗口的三栏外壳。导航、目录与阅读区分别承担稳定职责，
//  不复用项目详情安装 sheet 的会话状态，也不在视图求值时初始化本机存储。
//

import AppKit
import SwiftUI

/// 使用原生 Sidebar 与内容分栏承载列表和阅读区，复用 Starcat 的窗口与栏宽偏好。
struct SkillWorkspaceView: View {
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Bindable var viewModel: SkillWorkspaceViewModel
    @Bindable var chromeState: WorkspaceChromeState
    @State private var columnWidths: WorkspaceColumnWidthPersistence

    /// 测试注入独立栏宽缓存，避免原生布局回归覆盖用户真实偏好。
    init(
        viewModel: SkillWorkspaceViewModel,
        chromeState: WorkspaceChromeState,
        columnWidths: WorkspaceColumnWidthPersistence? = nil
    ) {
        self.viewModel = viewModel
        self.chromeState = chromeState
        _columnWidths = State(initialValue: columnWidths ?? WorkspaceColumnWidthPersistence(
            layout: SkillWorkspaceWindowMetrics.columnLayout
        ))
    }

    var body: some View {
        // 阅读区需要 480–1100pt，属于主内容而非窄 Inspector。两层控制器在宽 Inspector
        // 下会反复协商 min/max size；用原生 HSplitView 分配内容尺寸，避免这条反馈路径。
        NavigationSplitView(columnVisibility: WorkspaceColumnVisibility.leftBinding(
            for: chromeState, reduceMotion: reduceMotion
        )) {
            SkillLibrarySidebar(viewModel: viewModel)
                .navigationSplitViewColumnWidth(
                    min: columnWidths.layout.left.minimum,
                    ideal: columnWidths.initialLeftColumnWidth,
                    max: columnWidths.layout.left.maximum
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                            columnWidths.scheduleLeftWidthPersistence(
                                width, isCollapsed: chromeState.isLeftColumnCollapsed
                            )
                        }
                    }
                }
        } detail: {
            HSplitView {
                GeometryReader { proxy in
                    SkillLibraryList(viewModel: viewModel)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                        .clipped()
                }
                .frame(minWidth: 280, idealWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

                if chromeState.isRightColumnPresented {
                    GeometryReader { proxy in
                        SkillDetailView(viewModel: viewModel)
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                            .clipped()
                    }
                    .frame(
                        minWidth: columnWidths.layout.right.minimum,
                        idealWidth: columnWidths.rightColumnWidthForPresentation,
                        maxWidth: columnWidths.layout.right.maximum,
                        maxHeight: .infinity
                    )
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                                columnWidths.scheduleRightWidthPersistence(
                                    width, isCollapsed: chromeState.isRightColumnCollapsed
                                )
                            }
                        }
                    }
                    .background(SkillDetailWidthRestorer(
                        preferredWidth: columnWidths.rightColumnWidthForPresentation
                    ))
                }
            }
            .background(WorkspaceSplitCollapsePolicy(transition: chromeState.columnTransition))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultCursorShield()
        .onChange(of: chromeState.leftColumnVisibility) { _, _ in
            columnWidths.cancelPendingPersistence()
        }
        .onChange(of: chromeState.isRightColumnPresented) { _, _ in
            columnWidths.cancelPendingPersistence()
        }
        .onDisappear {
            columnWidths.persistLastMeasuredWidths()
            columnWidths.cancelPendingPersistence()
        }
    }
}

/// HSplitView 重新插入阅读栏时可能只采用最小宽度；每次创建只恢复一次有效宽度。
/// 后续拖动与缩窗交回原生分栏，不把测量结果持续反向绑定到分隔条。
private struct SkillDetailWidthRestorer: NSViewRepresentable {
    let preferredWidth: CGFloat

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(preferredWidth: preferredWidth)
    }

    func updateNSView(_ view: ProbeView, context: Context) {}

    /// 只沿阅读栏自己的祖先查找内容分栏，不访问其他窗口或替换系统 delegate。
    final class ProbeView: NSView {
        private let preferredWidth: CGFloat
        private var didRestoreWidth = false

        init(preferredWidth: CGFloat) {
            self.preferredWidth = preferredWidth
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// 等原生分栏分配出有效尺寸后再恢复，且先置位，避免祖先重布局时再次执行。
        override func layout() {
            super.layout()
            guard !didRestoreWidth, window != nil, bounds.width > 0 else { return }
            var ancestor = superview
            while let current = ancestor {
                if let split = current as? NSSplitView,
                   split.isVertical, split.arrangedSubviews.count == 2 {
                    didRestoreWidth = true
                    split.setPosition(
                        split.bounds.width - preferredWidth - split.dividerThickness,
                        ofDividerAt: 0
                    )
                    return
                }
                ancestor = current.superview
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Agent 和来源从快照派生，避免显示尚未检测到的工具或来源。
private struct SkillLibrarySidebar: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Bindable var viewModel: SkillWorkspaceViewModel
    @Namespace private var selectionSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("skills.workspace.title", systemImage: "square.stack.3d.up")
                .font(interfaceScale.font(.workspaceTitle))
                .padding(16)

            List(selection: $viewModel.navigation) {
                Section("skills.workspace.library") {
                    ForEach(Array(SkillWorkspaceFilter.allCases.enumerated()), id: \.element.id) { index, filter in
                        HStack {
                            Label(LocalizedStringKey(filter.titleKey), systemImage: filter.systemImage)
                            Spacer(minLength: 8)
                            Text(viewModel.filterCounts[filter, default: 0], format: .number.locale(locale))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .listRowSurface(
                            index: index,
                            isSelected: viewModel.navigation == .library(filter),
                            selectionNamespace: selectionSpace
                        )
                        .tag(SkillWorkspaceNavigation.library(filter))
                        .listRowBackground(Color.clear)
                    }
                }
                if !viewModel.agentNames.isEmpty {
                    Section("skills.workspace.agents") {
                        ForEach(Array(viewModel.agentNames.enumerated()), id: \.element) { index, name in
                            Label(name, systemImage: "terminal")
                                .listRowSurface(index: index,
                                                isSelected: viewModel.navigation == .agent(name),
                                                selectionNamespace: selectionSpace)
                                .tag(SkillWorkspaceNavigation.agent(name))
                                .listRowBackground(Color.clear)
                        }
                    }
                }
                if !viewModel.sources.isEmpty {
                    Section("skills.workspace.sources") {
                        ForEach(Array(viewModel.sources.enumerated()), id: \.element) { index, source in
                            Label(source, systemImage: "arrow.triangle.branch")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .listRowSurface(index: index,
                                                isSelected: viewModel.navigation == .source(source),
                                                selectionNamespace: selectionSpace)
                                .tag(SkillWorkspaceNavigation.source(source))
                                .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

/// 搜索和筛选只消费快照；刷新失败时保留列表，不将错误根伪装成空库。
private struct SkillLibraryList: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(AppDependencies.self) private var dependencies: AppDependencies?
    @Bindable var viewModel: SkillWorkspaceViewModel
    @State private var isCheckingUpdates = false
    @State private var updateMessage: String?
    @State private var evaluationTask: SkillEvaluationPanelTaskLink?
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                title.font(interfaceScale.font(.panelTitle))
                Spacer(minLength: 8)
                if let dependencies, dependencies.distributionGate.isAvailable(.externalToolBridge) {
                    Button {
                        presentEvaluation(dependencies)
                    } label: {
                        Label("skills.evaluation.action", systemImage: "checklist")
                            .labelStyle(.iconOnly)
                    }
                    .help("skills.evaluation.action")
                    .accessibilityLabel(Text("skills.evaluation.action"))
                    .disabled(viewModel.selectedIDs.isEmpty || viewModel.libraryEnvironment == nil)
                }
                Button("skills.batch.title") {
                    let ids = viewModel.visibleItems.filter { viewModel.selectedIDs.contains($0.id) }.map(\.id)
                    SkillReviewWindowController.present(titleKey: "skills.batch.title") { close in
                        if let dependencies {
                            SkillBatchAssignmentSheet(viewModel: viewModel, entryIDs: ids, close: close)
                                .appHostEnvironment(dependencies)
                        } else {
                            SkillBatchAssignmentSheet(viewModel: viewModel, entryIDs: ids, close: close)
                                .appLocaleEnvironment()
                        }
                    }
                }
                .disabled(viewModel.selectedIDs.isEmpty || viewModel.libraryEnvironment == nil)
                Button {
                    viewModel.importPresentation = .manual
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .help("skills.import.title").accessibilityLabel(Text("skills.import.title"))
                .disabled(viewModel.libraryEnvironment == nil)
                SyncIconButton(
                    isRefreshing: viewModel.loadState == .loading,
                    tooltip: String.l10n("repo.skills.scan.refresh"),
                    action: viewModel.refreshLibrary
                )
            }

            TextField("repo.skills.search", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("repo.skills.search"))

            HStack {
                Button("skills.update.batch.title") {
                    let ids = viewModel.visibleItems.filter { viewModel.selectedIDs.contains($0.id) }.map(\.id)
                    SkillReviewWindowController.present(titleKey: "skills.update.batch.title", size: CGSize(width: 760, height: 740)) { close in
                        if let dependencies {
                            SkillBatchUpdateSheet(viewModel: viewModel, entryIDs: ids, close: close).appHostEnvironment(dependencies)
                        } else {
                            SkillBatchUpdateSheet(viewModel: viewModel, entryIDs: ids, close: close).appLocaleEnvironment()
                        }
                    }
                }
                .disabled(viewModel.selectedIDs.isEmpty || viewModel.libraryEnvironment == nil)
                Button("skills.update.check") {
                    guard let service = viewModel.libraryEnvironment?.updates else { return }
                    isCheckingUpdates = true
                    Task {
                        defer { isCheckingUpdates = false }
                        do { try await service.check() } catch { updateMessage = error.localizedDescription }
                        viewModel.refreshLibrary()
                    }
                }
                .disabled(isCheckingUpdates || viewModel.libraryEnvironment == nil)
                if isCheckingUpdates { ProgressView().controlSize(.small) }
                if let updateMessage { Text(verbatim: updateMessage).font(.caption).foregroundStyle(.secondary) }
            }

            Divider()

            if let message = viewModel.loadState.message, !viewModel.items.isEmpty {
                Label {
                    Text(verbatim: message).lineLimit(2).textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.secondary)
                .font(interfaceScale.font(.caption))
            }
            if viewModel.loadState == .loading && viewModel.items.isEmpty {
                ListLoadingSkeleton(rowHeight: 88, showsIcon: false)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if case .failed(let message) = viewModel.loadState, viewModel.items.isEmpty {
                ContentUnavailableView {
                    Label("repo.skills.status.failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(verbatim: message)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.visibleItems.isEmpty {
                ContentUnavailableView(
                    "repo.skills.list.empty",
                    systemImage: "square.stack.3d.up",
                    description: Text(LocalizedStringKey(viewModel.searchText.isEmpty
                        ? "skills.workspace.empty.description"
                        : "skills.workspace.search.empty"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $viewModel.selectedIDs) {
                    ForEach(Array(viewModel.visibleItems.enumerated()), id: \.element.id) { index, item in
                        SkillLibraryRow(item: item)
                            .listRowSurface(index: index, isSelected: viewModel.selectedIDs.contains(item.id))
                            .tag(item.id)
                    }
                }
                .listStyle(.inset)
                // 原生多选 List 保留身份，避免每次分类切换重建全部行与滚动宿主。
                .stableDetailTransition(value: viewModel.navigation)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: viewModel.items.isEmpty)
        .padding(16)
    }

    /// 与现有批量入口一样冻结选中的可见条目，多选顺序沿用目录列表。
    private func presentEvaluation(_ dependencies: AppDependencies) {
        let items = viewModel.visibleItems.filter { viewModel.selectedIDs.contains($0.id) }.map {
            SkillEvaluationPanelItem(target: .library($0.id), name: $0.name, source: $0.source)
        }
        guard !items.isEmpty else { return }
        SkillReviewWindowController.present(titleKey: "skills.evaluation.title") { close in
            SkillEvaluationPanel(items: items, service: dependencies.skillEvaluation, rememberedTask: $evaluationTask, close: close)
                .onChange(of: dependencies.databaseScopeRevision) { close() }
                .appHostEnvironment(dependencies)
        }
    }

    private var title: Text {
        switch viewModel.navigation ?? .library(.all) {
        case .library(let filter): Text(LocalizedStringKey(filter.titleKey))
        case .agent(let name), .source(let name): Text(verbatim: name)
        }
    }
}

/// 行内只展示可扫描的信息；完整路径和共享影响留给详情，避免列表膨胀成卡片。
private struct SkillLibraryRow: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    let item: SkillLibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: item.name)
                    .font(interfaceScale.font(.rowTitle))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if item.diagnostic != nil {
                    Image(systemName: "exclamationmark.circle")
                        .accessibilityLabel(Text("skills.workspace.filter.attention"))
                        .foregroundStyle(.secondary)
                } else if item.hasUpdate {
                    Image(systemName: "arrow.down.circle")
                        .accessibilityLabel(Text("skills.workspace.filter.updates"))
                        .foregroundStyle(.secondary)
                }
            }
            Text(verbatim: item.summary)
                .font(interfaceScale.font(.body))
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(item.managementKind == .managed
                ? "skills.workspace.filter.managed"
                : "skills.detail.external"))
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
