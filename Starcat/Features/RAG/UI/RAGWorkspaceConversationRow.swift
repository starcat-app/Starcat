//
//  RAGWorkspaceConversationRow.swift
//  Starcat
//
//  RAG 会话侧栏的独立行视图，隔离选中态与 hover 更新，避免刷新整棵侧栏。
//

import Observation
import SwiftUI

/// 单行独享的选中态。不能让列表中每一行都直接读取 ViewModel 的
/// `selectedConversationID`：Observation 会把属性变化广播给所有读取者，长列表切换一次
/// 就会同时失效全部行，并触发 `LazyVStack` 重新测量整列。
@MainActor
@Observable
final class RAGConversationRowSelectionState {
    private(set) var isSelected: Bool

    init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    fileprivate func update(isSelected: Bool) {
        guard self.isSelected != isSelected else { return }
        self.isSelected = isSelected
    }
}

/// 把全局 selected ID 转成至多两个行状态更新（旧选中行 + 新选中行）。
///
/// 字典本身故意不参与 Observation；SwiftUI 只观察每行自己的小状态对象，避免会话越多，
/// 一次点选造成的无效 View 更新越多。删除会话后会同步裁掉状态，避免窗口常驻期间积累。
@MainActor
final class RAGConversationRailSelectionStore {
    private var states: [UUID: RAGConversationRowSelectionState] = [:]
    private(set) var selectedConversationID: UUID?

    func state(for conversationID: UUID) -> RAGConversationRowSelectionState {
        if let state = states[conversationID] {
            return state
        }
        let state = RAGConversationRowSelectionState(
            isSelected: conversationID == selectedConversationID
        )
        states[conversationID] = state
        return state
    }

    func select(_ conversationID: UUID?) {
        guard selectedConversationID != conversationID else { return }
        let previousID = selectedConversationID
        selectedConversationID = conversationID
        if let previousID {
            states[previousID]?.update(isSelected: false)
        }
        if let conversationID {
            state(for: conversationID).update(isSelected: true)
        }
    }

    func retainConversationIDs(_ conversationIDs: [UUID]) {
        let retained = Set(conversationIDs)
        states = states.filter { retained.contains($0.key) }
        if let selectedConversationID, !retained.contains(selectedConversationID) {
            self.selectedConversationID = nil
        }
    }
}

/// 单条 RAG 会话导航行。
///
/// 每个 SwiftUI `Menu` 都会桥接为 AppKit 菜单并同步解析菜单项的无障碍文本。长列表若让
/// 每行常驻一个菜单，切换选中项时会在主线程重建大量无关菜单。这里仅为选中行或当前
/// hover 行挂载菜单，同时保留固定宽度占位，避免操作按钮显隐造成标题跳动。
struct RAGWorkspaceConversationRow: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @Bindable var selectionState: RAGConversationRowSelectionState
    let conversation: RAGConversationSummary
    let rowIndex: Int
    /// 分组内的会话行不显示气泡图标；保留同宽占位，使文字与根级行文字对齐。
    let showsIcon: Bool
    let isDragging: Bool
    let isSettling: Bool
    let onSelected: () -> Void
    let onDragStarted: () -> Void
    let onDragEnded: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                // 先更新轻量行状态，再启动异步加载；高亮反馈不必等待 Task 首次调度。
                onSelected()
                Task { await viewModel.selectConversation(conversation.id) }
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    // 分组内行不渲染图标，但保留同宽占位，让文字与根级行文字纵向对齐。
                    if showsIcon {
                        Image(systemName: conversation.isPinned ? "pin.fill" : "bubble.left")
                            .font(iconFont(size: 13, weight: .medium))
                            .foregroundStyle(
                                conversation.isPinned
                                    ? Color.accentColor
                                    : (selectionState.isSelected ? Color.accentColor : .secondary)
                            )
                            .frame(width: 18)
                    } else {
                        Color.clear.frame(width: 18)
                    }
                    Text(conversation.title)
                        .font(interfaceScale.font(
                            RAGConversationTypography.text,
                            weight: selectionState.isSelected ? .semibold : .regular
                        ))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)

            Group {
                if Self.shouldMountActionMenu(isSelected: selectionState.isSelected, isHovered: isHovered) {
                    conversationActionMenu
                } else {
                    Color.clear
                        .frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 32, height: 26)
            .padding(.trailing, 6)
        }
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowBackground)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 8)
        // 菜单的挂载与卸载不参与动画；只让背景平滑变化，避免 AppKit 菜单桥接处于中间态。
        .onHover { isHovered = $0 }
        // settling：源行全隐；dragging：压暗。取消拖拽必须清掉 dragging，否则文案会一直发灰。
        .opacity(isSettling ? 0 : (isDragging ? 0.35 : 1))
        .draggable(conversation.id.uuidString) {
            conversationDragPreview
                .onAppear(perform: onDragStarted)
                .onDisappear(perform: onDragEnded)
        }
    }

    /// 菜单挂载条件保持纯函数，既能直接回归，也明确约束列表中同时存在的 AppKit 菜单数量。
    nonisolated static func shouldMountActionMenu(isSelected: Bool, isHovered: Bool) -> Bool {
        isSelected || isHovered
    }

    private var rowBackground: Color {
        if selectionState.isSelected {
            return Color.accentColor.opacity(isHovered ? 0.18 : 0.11)
        }
        if isHovered {
            return Color.accentColor.opacity(0.08)
        }
        return rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045)
    }

    private var conversationActionMenu: some View {
        Menu {
            Button(
                conversation.isPinned
                    ? "rag.workspace.conversation.unpin"
                    : "rag.workspace.conversation.pin"
            ) {
                Task {
                    await viewModel.setConversationPinned(
                        id: conversation.id,
                        isPinned: !conversation.isPinned
                    )
                }
            }
            Button("rag.workspace.conversation.rename") {
                viewModel.presentRenameConversation(conversation)
            }
            Menu("rag.workspace.conversation.moveToGroup") {
                Button("rag.workspace.conversation.ungroup") {
                    Task { await viewModel.moveConversation(id: conversation.id, toGroupID: nil) }
                }
                .disabled(conversation.groupID == nil)
                ForEach(viewModel.conversationGroups) { group in
                    Button(group.title) {
                        Task { await viewModel.moveConversation(id: conversation.id, toGroupID: group.id) }
                    }
                    .disabled(conversation.groupID == group.id)
                }
            }
            Button("common.delete", role: .destructive) {
                Task { await viewModel.deleteConversation(conversation.id) }
            }
        } label: {
            Label("rag.workspace.conversation.actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .font(iconFont(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .help("rag.workspace.conversation.actions")
    }

    /// 拖拽预览只复制可扫描的行内容，不挂载菜单或观察其它会话状态。
    private var conversationDragPreview: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: conversation.isPinned ? "pin.fill" : "bubble.left")
                .font(iconFont(size: 13, weight: .medium))
                .foregroundStyle(conversation.isPinned ? Color.accentColor : .secondary)
                .frame(width: 18)
            Text(conversation.title)
                .font(interfaceScale.font(RAGConversationTypography.text, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 220, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .opacity(0.92)
    }

    private func iconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }
}
