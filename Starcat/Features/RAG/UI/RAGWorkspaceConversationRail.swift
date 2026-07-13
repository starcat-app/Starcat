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

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @State private var renameTarget: RAGConversationSummary?
    @State private var renameDraft = ""
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var isCreateGroupPresented = false
    @State private var createGroupDraft = ""
    @State private var renameGroupTarget: RAGConversationGroup?
    @State private var renameGroupDraft = ""
    @State private var conversationDropTarget: RAGConversationDropTarget?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "text.book.closed.fill")
                        .font(iconFont(size: 18, weight: .semibold))
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
                    Label("rag.workspace.newConversation", systemImage: "plus")
                        .font(ragFont(.callout, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        // rail 本身是 controlBackground；这里用 textBackground + separator
                        // 描边做出可见灰底，明暗主题都对比够用，且不是 accent 蓝。
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
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
                            createGroupDraft = String.l10n("rag.workspace.group.newTitle")
                            isCreateGroupPresented = true
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
                    .onDrop(
                        of: [.plainText],
                        isTargeted: Binding(
                            get: { conversationDropTarget == .ungrouped },
                            set: { conversationDropTarget = $0 ? .ungrouped : nil }
                        )
                    ) { providers in
                        handleConversationDrop(providers, toGroupID: nil)
                    }

                    ForEach(viewModel.conversationGroups) { group in
                        groupSection(group)
                    }

                    ForEach(viewModel.conversations(inGroupID: nil)) { conversation in
                        conversationRow(conversation)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
        .alert("rag.workspace.conversation.rename.title", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("rag.workspace.conversation.rename.placeholder", text: $renameDraft)
            Button("common.cancel", role: .cancel) { renameTarget = nil }
            Button("common.ok") { guard let target = renameTarget else { return }; let title = renameDraft; renameTarget = nil; Task { await viewModel.renameConversation(id: target.id, title: title) } }.disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("rag.workspace.group.create.title", isPresented: $isCreateGroupPresented) {
            TextField("rag.workspace.group.rename.placeholder", text: $createGroupDraft)
            Button("common.cancel", role: .cancel) { createGroupDraft = "" }
            Button("common.ok") { let title = createGroupDraft; createGroupDraft = ""; Task { await viewModel.createGroup(title: title) } }.disabled(createGroupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("rag.workspace.group.rename.title", isPresented: Binding(get: { renameGroupTarget != nil }, set: { if !$0 { renameGroupTarget = nil } })) {
            TextField("rag.workspace.group.rename.placeholder", text: $renameGroupDraft)
            Button("common.cancel", role: .cancel) { renameGroupTarget = nil }
            Button("common.ok") { guard let target = renameGroupTarget else { return }; let title = renameGroupDraft; renameGroupTarget = nil; Task { await viewModel.renameGroup(id: target.id, title: title) } }.disabled(renameGroupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onChange(of: viewModel.conversationGroups.map(\.id)) { _, ids in expandedGroupIDs.formUnion(ids) }
    }

    private func ragFont(_ role: RAGFontRole, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        interfaceScale.font(role.typography, weight: weight, design: design)
    }

    private func iconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }

    var indexSummary: some View {
        Button { viewModel.showKnowledgeBrowser(presentingWindow: NSApp.keyWindow) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("rag.workspace.status.knowledgeBase", systemImage: "books.vertical")
                        .font(ragFont(.caption, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(iconFont(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("rag.browser.open")
    }

    func groupSection(_ group: RAGConversationGroup) -> some View {
        let isSelected = viewModel.selectedGroupID == group.id
        let isExpanded = expandedGroupIDs.contains(group.id)
        let isDropTarget = conversationDropTarget == .group(group.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    // 单击目录行：展开/折叠，并选中该一级分组（新会话归入此处）。
                    if isExpanded {
                        expandedGroupIDs.remove(group.id)
                    } else {
                        expandedGroupIDs.insert(group.id)
                    }
                    viewModel.selectedGroupID = group.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(iconFont(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Image(systemName: "folder.fill")
                            .font(iconFont(size: 13, weight: .medium))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        Text(group.title)
                            .font(ragFont(.callout, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(viewModel.conversations(inGroupID: group.id).count)")
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
                        renameGroupTarget = group
                        renameGroupDraft = group.title
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
            .background(
                isDropTarget
                    ? Color.accentColor.opacity(0.18)
                    : (isSelected ? Color.accentColor.opacity(0.11) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 8)
            .onDrop(
                of: [.plainText],
                isTargeted: Binding(
                    get: { conversationDropTarget == .group(group.id) },
                    set: { conversationDropTarget = $0 ? .group(group.id) : nil }
                )
            ) { providers in
                handleConversationDrop(providers, toGroupID: group.id)
            }

            if isExpanded {
                ForEach(viewModel.conversations(inGroupID: group.id)) { conversation in
                    conversationRow(conversation)
                        .padding(.leading, 14)
                }
            }
        }
    }

    func conversationRow(_ conversation: RAGConversationSummary) -> some View {
        let selected = conversation.id == viewModel.selectedConversationID
        return HStack(spacing: 0) {
            Button {
                Task { await viewModel.selectConversation(conversation.id) }
            } label: {
                HStack(spacing: 9) {
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
                            .font(ragFont(.callout, weight: selected ? .semibold : .regular))
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
                    renameTarget = conversation
                    renameDraft = conversation.title
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
        .background(selected ? Color.accentColor.opacity(0.11) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 8)
        .draggable(conversation.id.uuidString)
    }

    /// 从拖拽 payload 解析会话 UUID，再写入目标分组（`nil` = 未分组）。
    func handleConversationDrop(_ providers: [NSItemProvider], toGroupID groupID: UUID?) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let raw = object as? String,
                  let conversationID = UUID(uuidString: raw) else { return }
            Task { @MainActor in
                await viewModel.moveConversation(id: conversationID, toGroupID: groupID)
                conversationDropTarget = nil
            }
        }
        return true
    }
}
