//
//  SkillWorkspaceView.swift
//  Starcat
//
//  独立 Skill 管理窗口的三栏外壳。导航、目录与阅读区分别承担稳定职责，
//  不复用项目详情安装 sheet 的会话状态，也不在视图求值时初始化本机存储。
//

import SwiftUI

/// 沿用 Starcat 原生 Sidebar / 内容区 / Inspector，栏宽只在重开时读入。
struct SkillWorkspaceView: View {
    @Bindable var viewModel: SkillWorkspaceViewModel
    @Bindable var chromeState: WorkspaceChromeState
    @State private var columnWidths = WorkspaceColumnWidthPersistence(
        layout: SkillWorkspaceWindowMetrics.columnLayout
    )

    var body: some View {
        WorkspaceColumns(chromeState: chromeState, columnWidths: columnWidths) {
            SkillLibrarySidebar(viewModel: viewModel)
        } runSurface: {
            SkillLibraryList(viewModel: viewModel)
        } inspector: {
            SkillDetailView(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultCursorShield()
    }
}

/// Agent 和来源从快照派生，避免显示尚未检测到的工具或来源。
private struct SkillLibrarySidebar: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Bindable var viewModel: SkillWorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("skills.workspace.title", systemImage: "square.stack.3d.up")
                .font(interfaceScale.font(.workspaceTitle))
                .padding(16)

            List(selection: $viewModel.navigation) {
                Section("skills.workspace.library") {
                    ForEach(SkillWorkspaceFilter.allCases) { filter in
                        HStack {
                            Label(LocalizedStringKey(filter.titleKey), systemImage: filter.systemImage)
                            Spacer(minLength: 8)
                            Text(viewModel.filterCounts[filter, default: 0], format: .number.locale(locale))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .tag(SkillWorkspaceNavigation.library(filter))
                    }
                }
                if !viewModel.agentNames.isEmpty {
                    Section("skills.workspace.agents") {
                        ForEach(viewModel.agentNames, id: \.self) { name in
                            Label(name, systemImage: "terminal")
                                .tag(SkillWorkspaceNavigation.agent(name))
                        }
                    }
                }
                if !viewModel.sources.isEmpty {
                    Section("skills.workspace.sources") {
                        ForEach(viewModel.sources, id: \.self) { source in
                            Label(source, systemImage: "arrow.triangle.branch")
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .tag(SkillWorkspaceNavigation.source(source))
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
    @State private var showsImport = false
    @State private var isCheckingUpdates = false
    @State private var updateMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                title.font(interfaceScale.font(.panelTitle))
                Spacer(minLength: 8)
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
                    showsImport = true
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
                ProgressView("skills.workspace.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    ForEach(viewModel.visibleItems) { item in
                        SkillLibraryRow(item: item)
                            .tag(item.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(16)
        .sheet(isPresented: $showsImport) {
            SkillImportSheet(viewModel: viewModel).appLocaleEnvironment()
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
