//
//  SkillDetailView.swift
//  Starcat
//
//  三栏工作台的主要阅读区。说明、文件、分配证据与版本各自独立，
//  外部条目只展示事实，尚未实现的写操作不生成占位按钮或乐观开关。
//

import SwiftUI

/// Tab 是本机窗口偏好，不随条目或 GitHub 账号变化。
enum SkillDetailTab: String, CaseIterable, Identifiable {
    case overview
    case files
    case assignments
    case versions

    var id: Self { self }
    var titleKey: String { "skills.detail.tab.\(rawValue)" }
}

/// 消费稳定条目快照，切换选择时不会保留上一条目的正文。
struct SkillDetailView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @AppStorage("skillWorkspace.selectedTab") private var selectedTab = SkillDetailTab.overview
    @Bindable var viewModel: SkillWorkspaceViewModel

    var body: some View {
        if let item = viewModel.selectedItem {
            VStack(alignment: .leading, spacing: 16) {
                header(item)
                Picker("skills.workspace.selection.title", selection: $selectedTab) {
                    ForEach(SkillDetailTab.allCases) { tab in
                        Text(LocalizedStringKey(tab.titleKey)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Divider()
                ScrollView {
                    detail(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .id(item.id)
            }
            .padding(20)
        } else if viewModel.selectedIDs.count > 1 {
            ContentUnavailableView(
                "skills.workspace.selection.multiple",
                systemImage: "square.stack",
                description: Text("skills.workspace.selection.description")
            )
        } else {
            ContentUnavailableView(
                "skills.workspace.selection.title",
                systemImage: "doc.text",
                description: Text("skills.workspace.selection.description")
            )
        }
    }

    private func header(_ item: SkillLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.managementKind == .managed {
                Text(LocalizedStringKey(item.updateState.titleKey)).font(.caption).foregroundStyle(.secondary)
                if let time = item.updateCheckedAt {
                    Text(Date(timeIntervalSince1970: time), format: .dateTime)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = item.updateMessage {
                    Text(verbatim: message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Text(verbatim: item.name)
                .font(interfaceScale.font(.workspaceTitle))
                .textSelection(.enabled)
            Text(verbatim: item.summary)
                .font(interfaceScale.font(.body))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack(spacing: 12) {
                Label(
                    LocalizedStringKey(item.managementKind == .managed
                        ? "skills.workspace.filter.managed"
                        : "skills.detail.external"),
                    systemImage: item.managementKind == .managed ? "shippingbox" : "folder"
                )
                if let source = item.source {
                    Text(verbatim: source).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("skills.detail.source.unknown")
                }
            }
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            if let diagnostic = item.diagnostic {
                Label {
                    Text(verbatim: diagnostic)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(interfaceScale.font(.body))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
                .help(diagnostic)
            }
        }
    }

    @ViewBuilder
    private func detail(_ item: SkillLibraryItem) -> some View {
        switch selectedTab {
        case .overview, .files:
            SkillContentView(item: item, tab: selectedTab, refreshID: viewModel.contentRefreshID)
                .id(item.id)
        case .assignments:
            SkillAssignmentsView(item: item, viewModel: viewModel).id(item.id)
        case .versions:
            if let revision = item.revision {
                Text(verbatim: revision).font(interfaceScale.font(.code))
            } else {
                Text("skills.detail.version.unknown").foregroundStyle(.secondary)
            }
        }
    }
}
