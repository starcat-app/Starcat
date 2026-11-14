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
            ContentUnavailableView(
                "skills.workspace.selection.title",
                systemImage: "doc.text",
                description: Text("skills.workspace.selection.description")
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultCursorShield()
    }
}

/// Sidebar 仅列库筛选；Agent 和来源从真实扫描结果加入，避免显示未检测工具。
private struct SkillLibrarySidebar: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Bindable var viewModel: SkillWorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("skills.workspace.title", systemImage: "square.stack.3d.up")
                .font(interfaceScale.font(.workspaceTitle))
                .padding(16)

            List(selection: $viewModel.filter) {
                Section("skills.workspace.library") {
                    ForEach(SkillWorkspaceFilter.allCases) { filter in
                        Label(LocalizedStringKey(filter.titleKey), systemImage: filter.systemImage)
                            .tag(filter)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

/// 搜索和筛选状态独立于仓库列表；尚未接本机库时展示真实空态。
private struct SkillLibraryList: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Bindable var viewModel: SkillWorkspaceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(viewModel.selectedFilter.titleKey))
                .font(interfaceScale.font(.panelTitle))

            TextField("repo.skills.search", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("repo.skills.search"))

            Divider()

            ContentUnavailableView(
                "repo.skills.list.empty",
                systemImage: "square.stack.3d.up",
                description: Text("skills.workspace.empty.description")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
    }
}
