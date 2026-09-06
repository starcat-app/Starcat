//
//  RAGWorkspaceConversationRail.swift
//  Starcat
//
//  知识库 RAG 工作台的会话导航栏与分组管理。
//

import AppKit
import SwiftUI

struct RAGWorkspaceConversationRail: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.ragSettingsNavigation) private var settingsNavigation

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    /// 把全局 selection 拆成行级状态，切换时只失效旧、新两行。
    @State private var selectionStore = RAGConversationRailSelectionStore()
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var conversationDropTarget: RAGConversationDropTarget?
    /// 正在拖拽的会话；源行压暗，避免系统 preview 与源行叠成残影。
    @State private var draggingConversationID: UUID?
    /// 已接受落点：源行先全隐，等系统 lift 淡出后再改列表，减轻松手叠影。
    @State private var settlingConversationID: UUID?
    /// 取消尚未完成的落点 settle，避免连拖时旧 Task 误改分组。
    @State private var dropSettleTask: Task<Void, Never>?
    /// 取消拖拽时系统 preview `onDisappear` 不一定触发；用 mouseUp 兜底清掉压暗态。
    @State private var dragSessionBox = RAGConversationDragSessionBox()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "square.3.layers.3d.bottom.filled")
                        .font(iconFont(size: 24, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("rag.workspace.title")
                            .font(ragFont(.headline, weight: .semibold))
                        Text("rag.workspace.subtitle")
                            .font(ragFont(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                indexSummary

                Button {
                    Task { await viewModel.newConversation() }
                } label: {
                    LocalHoverSurface(
                        normalBackground: Color.accentColor.opacity(0.11),
                        hoveredBackground: Color.accentColor.opacity(0.18),
                        cornerRadius: 7
                    ) {
                        Label {
                            Text("rag.workspace.newConversation")
                                .foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                            .font(ragFont(.callout, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("rag.workspace.recentConversations")
                            .font(ragFont(.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer(minLength: 4)
                        Button {
                            viewModel.presentCreateGroup()
                        } label: {
                            Image(systemName: "folder.badge.plus")
                                .font(iconFont(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("rag.workspace.group.create")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        conversationDropTarget == .ungrouped
                            ? Color.accentColor.opacity(0.08)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7)
                    )
                    .overlay {
                        if conversationDropTarget == .ungrouped {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                        }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let conversationID = Self.conversationID(fromDropItems: items) else {
                            return false
                        }
                        // 先 return true 让拖拽会话结束；列表改动放到 settle 阶段，避免预览卡片残留叠影。
                        scheduleConversationDrop(conversationID: conversationID, toGroupID: nil)
                        return true
                    } isTargeted: { targeted in
                        updateDropTarget(.ungrouped, isTargeted: targeted)
                    }

                    // 置顶会话直接顶到列表最前，不单独做「置顶」分组标题；靠 pin 图标区分即可。
                    ForEach(viewModel.conversationRailPresentation.pinnedRows) { entry in
                        conversationRow(entry.conversation, rowIndex: entry.rowIndex)
                    }

                    ForEach(viewModel.conversationGroups) { group in
                        groupSection(group)
                    }

                    ForEach(viewModel.conversationRailPresentation.ungroupedRows) { entry in
                        conversationRow(entry.conversation, rowIndex: entry.rowIndex)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .onChange(of: viewModel.conversationRailPresentation.groupIDs) { _, ids in
            expandedGroupIDs.formUnion(ids)
        }
        .background {
            RAGWorkspaceConversationSelectionSynchronizer(
                viewModel: viewModel,
                selectionStore: selectionStore
            )
        }
        .onDisappear {
            dropSettleTask?.cancel()
            dropSettleTask = nil
            settlingConversationID = nil
            draggingConversationID = nil
            conversationDropTarget = nil
            dragSessionBox.stop()
        }
    }

    private func ragFont(_ role: RAGFontRole, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        interfaceScale.font(role.typography, weight: weight, design: design)
    }

    private func iconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }

    var indexSummary: some View {
        Button {
            viewModel.openKnowledgeBaseEntry(
                presentingWindow: NSApp.keyWindow,
                settingsNavigation: settingsNavigation
            )
        } label: {
            LocalHoverSurface(
                normalBackground: Color(nsColor: .textBackgroundColor).opacity(0.58),
                hoveredBackground: Color.accentColor.opacity(0.08),
                cornerRadius: 8
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("rag.workspace.status.knowledgeBase", systemImage: "books.vertical")
                            .font(ragFont(.callout, weight: .semibold))
                        Spacer()
                        Image(systemName: viewModel.isKnowledgeBaseEmpty ? "plus.circle" : "arrow.up.right.square")
                            .font(iconFont(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.isKnowledgeBaseEmpty {
                        Text("rag.workspace.status.knowledgeBaseEmpty")
                            .font(ragFont(.caption2))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                // padding、背景和命中形状必须属于 Button label；如果放在 Button 外层，
                // 留白区域虽然会显示 hover 和手型指针，却不会触发按钮 action。
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .help(
            Text(
                viewModel.isKnowledgeBaseEmpty
                    ? "rag.workspace.addToLibrary.openHelp"
                    : "rag.browser.open"
            )
        )
    }

    func groupSection(_ group: RAGConversationGroup) -> some View {
        let isSelected = viewModel.selectedGroupID == group.id
        let isExpanded = expandedGroupIDs.contains(group.id)
        let isDropTarget = conversationDropTarget == .group(group.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    // 单击目录行：展开/折叠，并选中该一级分组（新会话归入此处）。
                    // 动画与元数据 / 调试折叠同款 0.16s；开启「减少动态效果」时瞬时切换。
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        if isExpanded {
                            expandedGroupIDs.remove(group.id)
                        } else {
                            expandedGroupIDs.insert(group.id)
                        }
                    }
                    viewModel.selectedGroupID = group.id
                } label: {
                    HStack(spacing: 8) {
                        // 固定 chevron.right + 旋转，避免换 symbol 时无过渡。
                        Image(systemName: "chevron.right")
                            .font(iconFont(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Image(systemName: "folder.fill")
                            .font(iconFont(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        Text(group.title)
                            .font(ragFont(.callout, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        // 计数只统计组内未置顶会话；置顶已上浮到顶部置顶区，避免展开后数字与实际条数对不上。
                        Text("\(viewModel.conversationRailPresentation.rows(inGroupID: group.id).count)")
                            .font(ragFont(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                Menu {
                    Button("rag.workspace.group.rename") {
                        viewModel.presentRenameGroup(group)
                    }
                    Button("common.delete", role: .destructive) {
                        Task { await viewModel.deleteGroup(id: group.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(iconFont(size: 13, weight: .medium))
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .foregroundStyle(.secondary)
                .help("rag.workspace.group.actions")
                .padding(.trailing, 6)
            }
            .background(isSelected ? Color.accentColor.opacity(0.11) : Color.clear)
            .overlay {
                // 落点用描边 + 浅底，避免整行大面积 fill 与拖拽 preview 同色叠影。
                if isDropTarget {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 8)
            .dropDestination(for: String.self) { items, _ in
                guard let conversationID = Self.conversationID(fromDropItems: items) else {
                    return false
                }
                scheduleConversationDrop(conversationID: conversationID, toGroupID: group.id)
                return true
            } isTargeted: { targeted in
                updateDropTarget(.group(group.id), isTargeted: targeted)
            }

            if isExpanded {
                ForEach(viewModel.conversationRailPresentation.rows(inGroupID: group.id)) { entry in
                    conversationRow(entry.conversation, rowIndex: entry.rowIndex)
                        .padding(.leading, 14)
                        // 仅淡入淡出：去掉 .move，降低松手时与 drag preview 的位移叠影。
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
        }
    }

    func conversationRow(_ conversation: RAGConversationSummary, rowIndex: Int) -> some View {
        let isDragging = draggingConversationID == conversation.id
        let isSettling = settlingConversationID == conversation.id
        return RAGWorkspaceConversationRow(
            viewModel: viewModel,
            selectionState: selectionStore.state(for: conversation.id),
            conversation: conversation,
            rowIndex: rowIndex,
            isDragging: isDragging,
            isSettling: isSettling,
            onSelected: {
                selectionStore.select(conversation.id)
            },
            onDragStarted: {
                beginConversationDrag(conversation.id)
            },
            onDragEnded: {
                // 成功路径由 settle 清理；取消路径以 mouseUp 兜底，这里再补一次。
                endConversationDragIfCancelled(conversation.id)
            }
        )
    }

    /// 解析 `dropDestination(for: String.self)` 的会话 UUID。
    private static func conversationID(fromDropItems items: [String]) -> UUID? {
        guard let raw = items.first else { return nil }
        return UUID(uuidString: raw)
    }

    private func updateDropTarget(_ target: RAGConversationDropTarget, isTargeted: Bool) {
        if isTargeted {
            conversationDropTarget = target
        } else if conversationDropTarget == target {
            conversationDropTarget = nil
        }
    }

    /// 拖起：记录源行，并监听 mouseUp；取消落点时清掉压暗（preview onDisappear 在 macOS 上不可靠）。
    private func beginConversationDrag(_ conversationID: UUID) {
        settlingConversationID = nil
        draggingConversationID = conversationID
        dragSessionBox.onMouseUp = { [dragSessionBox] in
            Task { @MainActor in
                // 给 dropDestination 一点时间先把 settling 设上；否则成功落点会被误判成取消。
                try? await Task.sleep(for: .milliseconds(64))
                if settlingConversationID == nil {
                    if draggingConversationID == conversationID {
                        draggingConversationID = nil
                    }
                    conversationDropTarget = nil
                }
                dragSessionBox.stop()
            }
        }
        dragSessionBox.start()
    }

    private func endConversationDragIfCancelled(_ conversationID: UUID) {
        guard settlingConversationID == nil else { return }
        if draggingConversationID == conversationID {
            draggingConversationID = nil
        }
        conversationDropTarget = nil
    }

    /// 先藏源行并 return drop；等系统 lift 淡出一小段后再改 `groupID`，减轻松手叠影。
    private func scheduleConversationDrop(conversationID: UUID, toGroupID groupID: UUID?) {
        conversationDropTarget = nil
        settlingConversationID = conversationID
        draggingConversationID = conversationID
        dragSessionBox.stop()

        dropSettleTask?.cancel()
        dropSettleTask = Task { @MainActor in
            // 让 dropDestination 先返回 true，AppKit 才能开始拆除拖拽会话。
            await Task.yield()
            if !reduceMotion {
                try? await Task.sleep(for: .milliseconds(120))
            } else {
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }

            if let groupID, !expandedGroupIDs.contains(groupID) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    _ = expandedGroupIDs.insert(groupID)
                }
            }

            await viewModel.moveConversation(id: conversationID, toGroupID: groupID)

            guard !Task.isCancelled else { return }
            if settlingConversationID == conversationID {
                settlingConversationID = nil
            }
            if draggingConversationID == conversationID {
                draggingConversationID = nil
            }
        }
    }
}

/// 单独观察会话选择和列表成员变化，避免这些读取把整个 `LazyVStack` 的 body 纳入依赖。
/// 行点击会提前更新 selectionStore；这里负责 bootstrap、失败回退及外部选择变化的对齐。
private struct RAGWorkspaceConversationSelectionSynchronizer: View {
    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    let selectionStore: RAGConversationRailSelectionStore

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: viewModel.selectedConversationID, initial: true) { _, selectedID in
                selectionStore.select(selectedID)
            }
            .onChange(of: viewModel.conversations.map(\.id), initial: true) { _, conversationIDs in
                selectionStore.retainConversationIDs(conversationIDs)
            }
    }
}

/// 拖拽会话 mouseUp 监听；取消落点时用于清掉源行压暗态。
@MainActor
private final class RAGConversationDragSessionBox {
    var onMouseUp: (() -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            Task { @MainActor in
                self?.onMouseUp?()
            }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        onMouseUp = nil
    }
}

/// RAG 侧栏标题编辑 sheet。
///
/// 为什么不用系统 `alert`：macOS alert 里的 `TextField` 宽度几乎固定且偏窄，
/// 对话标题常被截断。本 sheet 固定约 560pt，并由工作台根视图呈现，避免窄侧栏压宽。
struct RAGWorkspaceTitleEditSheet: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let titleKey: LocalizedStringKey
    let placeholderKey: LocalizedStringKey
    @Binding var draft: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @FocusState private var isFieldFocused: Bool

    private var canConfirm: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: interfaceScale.scaled(16)) {
            HStack(alignment: .center, spacing: 12) {
                Text(titleKey)
                    .font(ragFont(.headline, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                SheetCloseButton(
                    action: onCancel,
                    iconFont: iconFont(size: 16, scale: interfaceScale, weight: .medium),
                    frameSize: interfaceScale.scaled(26)
                )
            }

            TextField(placeholderKey, text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(ragFont(.body, scale: interfaceScale))
                .focused($isFieldFocused)
                .onSubmit {
                    guard canConfirm else { return }
                    onConfirm()
                }

            HStack {
                Spacer()
                Button("common.cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("common.ok", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm)
            }
        }
        .padding(interfaceScale.scaled(20))
        // 按常见长标题预留宽度；再靠 presentationSizing(.fitted) 让窗口跟着内容走。
        .frame(width: 560 * interfaceScale.multiplier)
        .fixedSize(horizontal: true, vertical: true)
        .appLocaleEnvironment()
        .onAppear {
            isFieldFocused = true
        }
    }
}
