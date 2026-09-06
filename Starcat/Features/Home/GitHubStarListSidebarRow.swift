//
//  GitHubStarListSidebarRow.swift
//  Starcat
//
//  GitHub Stars List 的独立侧栏行，将 hover 更新限制在当前行。
//

import SwiftUI

/// GitHub Stars List 侧栏行。
///
/// 编辑按钮只在 hover 时出现，但 hover 不属于 `SidebarView` 的业务状态。把它保留在行内，
/// 可以避免光标经过多个分组时反复重算整棵 Sidebar、所有 section 和统计数字。
struct GitHubStarListSidebarRow: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var isHovered = false

    let list: GitHubStarList
    let count: Int
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onPrefetch: () -> Void

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(verbatim: list.name)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if isHovered {
                    editButton
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(count.formatted())
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(width: SidebarView.trailingFixedWidth, alignment: .trailing)
            }
        } icon: {
            Circle()
                .fill(
                    SidebarSemanticIconStyle(
                        semanticColor: Color(hex: list.colorHex) ?? .accentColor
                    )
                )
                .frame(width: 14, height: 14)
        }
        .contextMenu {
            Button(action: onEdit) {
                Label("sidebar.githubStarLists.edit", systemImage: "slider.horizontal.2.square")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("action.delete", systemImage: "trash")
            }
        }
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onPrefetch()
            }
        }
        .onDisappear {
            isHovered = false
        }
    }

    private var editButton: some View {
        Button(action: onEdit) {
            Image(systemName: "slider.horizontal.2.square")
                .font(interfaceScale.font(.iconMedium, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("sidebar.githubStarLists.edit"))
    }
}
