//
//  RAGWorkspaceConversationRail.swift
//  Starcat
//
//  知识库 RAG 工作台的会话导航栏与分组管理。
//

import AppKit
import SwiftUI

/// 侧栏会话行的展示条目。
///
/// 同一会话会在「置顶区 / 原分组 / 未分组」之间迁移。若 `ForEach` 只使用会话 UUID，
/// `LazyVStack` 可能复用迁移前的缓存行，继续显示旧图标和旧位置；因此身份必须包含 placement。
struct RAGConversationRailRowEntry: Identifiable {
    enum Placement: Hashable {
        case pinned
        case ungrouped
        case group(UUID)
    }

    struct ID: Hashable {
        let conversationID: UUID
        let placement: Placement
    }

    let conversation: RAGConversationSummary
    let rowIndex: Int
    let placement: Placement

    var id: ID {
        ID(conversationID: conversation.id, placement: placement)
    }

    static func rows(
        from conversations: [RAGConversationSummary],
        placement: Placement
    ) -> [RAGConversationRailRowEntry] {
        conversations.enumerated().map { index, conversation in
            RAGConversationRailRowEntry(
                conversation: conversation,
                rowIndex: index,
                placement: placement
            )
        }
    }
}

struct RAGWorkspaceConversationRail: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.ragSettingsNavigation) private var settingsNavigation

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var conversationDropTarget: RAGConversationDropTarget?
    /// 正在拖拽的会话；源行压暗，避免系统 preview 与源行叠成残影。
    @State private var draggingConversationID: UUID?
    @State private var isKnowledgeBaseHovered = false
    @State private var isNewConversationHovered = false
    @State private var hoveredConversationID: UUID?

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
                        // 默认与当前会话选中态使用同一淡蓝底；hover 仅加深背景，不缩放整行。
                        .background(
                            Color.accentColor.opacity(isNewConversationHovered ? 0.18 : 0.11),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .pointerStyle(.link)
                .onHover { isNewConversationHovered = $0 }
                .onDisappear { isNewConversationHovered = false }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.15),
                    value: isNewConversationHovered
                )
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
                        finishConversationDrop(conversationID: conversationID, toGroupID: nil)
                        return true
                    } isTargeted: { targeted in
                        updateDropTarget(.ungrouped, isTargeted: targeted)
                    }

                    // 置顶会话直接顶到列表最前，不单独做「置顶」分组标题；靠 pin 图标区分即可。
                    ForEach(RAGConversationRailRowEntry.rows(
                        from: viewModel.pinnedConversations,
                        placement: .pinned
                    )) { entry in
                        conversationRow(entry.conversation, rowIndex: entry.rowIndex)
                    }

                    ForEach(viewModel.conversationGroups) { group in
                        groupSection(group)
                    }

                    ForEach(RAGConversationRailRowEntry.rows(
                        from: viewModel.unpinnedConversations(inGroupID: nil),
                        placement: .ungrouped
                    )) { entry in
                        conversationRow(entry.conversation, rowIndex: entry.rowIndex)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
        .onChange(of: viewModel.conversationGroups.map(\.id)) { _, ids in expandedGroupIDs.formUnion(ids) }
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
            // 默认保留知识库入口的灰底，hover 仅切换背景色，避免破坏侧栏布局稳定性。
            .background(
                isKnowledgeBaseHovered
                    ? Color.accentColor.opacity(0.08)
                    : Color(nsColor: .textBackgroundColor).opacity(0.58),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pointerStyle(.link)
        .onHover { isKnowledgeBaseHovered = $0 }
        .onDisappear { isKnowledgeBaseHovered = false }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.15),
            value: isKnowledgeBaseHovered
        )
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
                        Text("\(viewModel.unpinnedConversations(inGroupID: group.id).count)")
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
                finishConversationDrop(conversationID: conversationID, toGroupID: group.id)
                return true
            } isTargeted: { targeted in
                updateDropTarget(.group(group.id), isTargeted: targeted)
            }

            if isExpanded {
                ForEach(RAGConversationRailRowEntry.rows(
                    from: viewModel.unpinnedConversations(inGroupID: group.id),
                    placement: .group(group.id)
                )) { entry in
                    conversationRow(entry.conversation, rowIndex: entry.rowIndex)
                        .padding(.leading, 14)
                        // 仅淡入淡出：去掉 .move，降低松手时与 drag preview 的位移叠影。
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
        }
    }

    func conversationRow(_ conversation: RAGConversationSummary, rowIndex: Int) -> some View {
        let selected = conversation.id == viewModel.selectedConversationID
        let isHovered = conversation.id == hoveredConversationID
        let isDragging = draggingConversationID == conversation.id
        return HStack(spacing: 0) {
            Button {
                Task { await viewModel.selectConversation(conversation.id) }
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: conversation.isPinned ? "pin.fill" : "bubble.left")
                        .font(iconFont(size: 13, weight: .medium))
                        .foregroundStyle(
                            conversation.isPinned
                                ? Color.accentColor
                                : (selected ? Color.accentColor : .secondary)
                        )
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conversation.title)
                            .font(interfaceScale.font(
                                RAGConversationTypography.text,
                                weight: selected ? .semibold : .regular
                            ))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(String(conversation.updatedAt.prefix(10)))
                            .font(ragFont(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pointerStyle(.link)

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
                Image(systemName: "ellipsis")
                    .font(iconFont(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .help("rag.workspace.conversation.actions")
            .padding(.trailing, 6)
        }
        // 选中态始终优先；hover 只加深或补充轻量 accent 背景，不改变行尺寸。
        .background(conversationRowBackground(selected: selected, isHovered: isHovered, rowIndex: rowIndex))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 8)
        // 拖起时压暗源行，避免与系统 lift preview 叠成双影。
        .opacity(isDragging ? 0.35 : 1)
        .onHover { hovering in
            if hovering {
                hoveredConversationID = conversation.id
            } else if hoveredConversationID == conversation.id {
                hoveredConversationID = nil
            }
        }
        .onDisappear {
            if hoveredConversationID == conversation.id {
                hoveredConversationID = nil
            }
            if draggingConversationID == conversation.id {
                draggingConversationID = nil
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.15),
            value: isHovered
        )
        .draggable(conversation.id.uuidString) {
            conversationDragPreview(conversation)
                .onAppear { draggingConversationID = conversation.id }
                .onDisappear {
                    // 取消拖拽（未落到目标）时 preview 消失，清掉压暗态。
                    if draggingConversationID == conversation.id {
                        draggingConversationID = nil
                    }
                }
        }
    }

    /// 精简拖拽预览：不含 Menu / ellipsis，降低松手时系统预览与真实行叠影概率。
    @ViewBuilder
    private func conversationDragPreview(_ conversation: RAGConversationSummary) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: conversation.isPinned ? "pin.fill" : "bubble.left")
                .font(iconFont(size: 13, weight: .medium))
                .foregroundStyle(conversation.isPinned ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(interfaceScale.font(RAGConversationTypography.text, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(String(conversation.updatedAt.prefix(10)))
                    .font(ragFont(.caption2))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 220, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(reduceMotion ? 0 : 0.12), radius: reduceMotion ? 0 : 6, y: 2)
        .opacity(0.92)
    }

    /// 会话行沿用选中态淡蓝底；普通 hover 再弱一档，保留选中与悬停的视觉层级。
    private func conversationRowBackground(selected: Bool, isHovered: Bool, rowIndex: Int) -> Color {
        if selected {
            return Color.accentColor.opacity(isHovered ? 0.18 : 0.11)
        }
        if isHovered {
            return Color.accentColor.opacity(0.08)
        }
        return rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.045)
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

    /// 松手瞬间清高亮 / 压暗，再乐观改分组；折叠组先展开以免插入动画与 preview 打架。
    private func finishConversationDrop(conversationID: UUID, toGroupID groupID: UUID?) {
        conversationDropTarget = nil
        draggingConversationID = nil
        hoveredConversationID = nil

        // 折叠组先瞬时展开：松手这一拍若再叠开合动画，会与系统 preview 淡出打架。
        if let groupID, !expandedGroupIDs.contains(groupID) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                _ = expandedGroupIDs.insert(groupID)
            }
        }

        Task {
            await viewModel.moveConversation(id: conversationID, toGroupID: groupID)
        }
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
