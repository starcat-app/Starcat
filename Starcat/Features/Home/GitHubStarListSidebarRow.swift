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
///
/// 私有盾牌必须常驻名称后面：它表达 GitHub List 的可见性，不能和编辑按钮共用 hover
/// 显隐，否则用户扫一眼侧栏看不出哪些分组是私有的。
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

                // 只标私有：公开是默认态，侧栏不必再挂 globe。布局对齐主导航
                // 「我的项目」授权勾：名称后、计数前，始终占位；颜色同样用绿。
                if list.isPrivate {
                    privateShieldBadge
                }

                // 编辑按钮常驻占位、只切换透明度：hover 显隐不再改变行布局，
                // 鼠标划过时标题不会因布局抖动而乱晃。未 hover 时关掉 hit testing，
                // 点行空白仍能正常选中（等价于原来"不进视图树"不抢选中的意图）。
                editButton
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                    .accessibilityHidden(!isHovered)

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

    /// 实心底盾牌，规格和绿色对齐「我的项目」的 `checkmark.circle.fill`。
    ///
    /// 走 `SidebarSemanticIconStyle`：明亮主题选中蓝底时反成白色，不能手写
    /// `selection == item`（按下高亮与 binding 不同步）。黑暗主题选中时保留绿色，
    /// 和主导航授权勾同一套对比度策略。
    private var privateShieldBadge: some View {
        Image(systemName: "checkmark.shield.fill")
            .font(interfaceScale.font(.captionSmall))
            .foregroundStyle(SidebarSemanticIconStyle(semanticColor: .green))
            .frame(width: 18, height: 18)
            .accessibilityLabel(Text("githubStarLists.visibility.private"))
            .help(Text("githubStarLists.visibility.private"))
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
