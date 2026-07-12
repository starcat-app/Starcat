//
//  KnowledgeRAGWorkspaceView.swift
//  Starcat
//
//  知识库 RAG 的真实三栏工作台：会话历史、问答时间线、证据/计划/索引 Inspector。
//
//  工作台遵循主窗口与 Agent Workspace 的同一视觉契约。输入框显式承载 @repo、模型和
//  附件；Issues 等远程上下文只在 Planner 命中后进入确认流程，不提供 slash command。
//

import AppKit
import SwiftUI

struct KnowledgeRAGWorkspaceView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(AppSettings.self) private var settings

    let chromeState: WorkspaceChromeState
    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @State private var inspectorTab: RAGInspectorTab = .evidence
    @State private var composerContentHeight: CGFloat = 0
    @State private var expandedDebugTraceIDs: Set<UUID> = []
    @State private var renameTarget: RAGConversationSummary?
    @State private var renameDraft = ""
    /// `@` 候选弹层锚点：相对输入框（NSScrollView）左上角，落在 `@` 字形下方。
    @State private var mentionCaretAnchor: CGPoint = .zero
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var isCreateGroupPresented = false
    @State private var createGroupDraft = ""
    @State private var renameGroupTarget: RAGConversationGroup?
    @State private var renameGroupDraft = ""
    @State private var conversationDropTarget: RAGConversationDropTarget?

    /// Inspector 标题 / tabs / 内容共用水平 inset，避免三层左右错位。
    private static let inspectorContentInset: CGFloat = 14

    var body: some View {
        HStack(spacing: 0) {
            if !chromeState.isLeftColumnCollapsed {
                conversationRail
                    .frame(width: 286)
                Divider()
            }

            answerSurface
                .layoutPriority(1)

            if !chromeState.isRightColumnCollapsed {
                Divider()
                inspector
                    .frame(minWidth: 320, idealWidth: 356, maxWidth: 400)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultCursorShield()
        .task { await viewModel.bootstrap() }
        .task { await viewModel.observeKnowledgeBoundaryChanges() }
        .task { await viewModel.observeIndexChanges() }
        .environment(\.openURL, OpenURLAction { url in
            viewModel.handleLink(url)
            return .handled
        })
        .alert(
            "rag.workspace.error.title",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("common.ok") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert(
            "rag.workspace.conversation.rename.title",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("rag.workspace.conversation.rename.placeholder", text: $renameDraft)
            Button("common.cancel", role: .cancel) {
                renameTarget = nil
            }
            Button("common.ok") {
                guard let target = renameTarget else { return }
                let title = renameDraft
                renameTarget = nil
                Task { await viewModel.renameConversation(id: target.id, title: title) }
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "rag.workspace.group.create.title",
            isPresented: $isCreateGroupPresented
        ) {
            TextField("rag.workspace.group.rename.placeholder", text: $createGroupDraft)
            Button("common.cancel", role: .cancel) {
                createGroupDraft = ""
            }
            Button("common.ok") {
                let title = createGroupDraft
                createGroupDraft = ""
                Task { await viewModel.createGroup(title: title) }
            }
            .disabled(createGroupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "rag.workspace.group.rename.title",
            isPresented: Binding(
                get: { renameGroupTarget != nil },
                set: { if !$0 { renameGroupTarget = nil } }
            )
        ) {
            TextField("rag.workspace.group.rename.placeholder", text: $renameGroupDraft)
            Button("common.cancel", role: .cancel) {
                renameGroupTarget = nil
            }
            Button("common.ok") {
                guard let target = renameGroupTarget else { return }
                let title = renameGroupDraft
                renameGroupTarget = nil
                Task { await viewModel.renameGroup(id: target.id, title: title) }
            }
            .disabled(renameGroupDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onChange(of: viewModel.conversationGroups.map(\.id)) { _, ids in
            // 新建分组默认展开，避免用户找不到刚创建的目录。
            expandedGroupIDs.formUnion(ids)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: chromeState.isLeftColumnCollapsed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: chromeState.isRightColumnCollapsed)
    }

    // MARK: - Conversation rail

    private var conversationRail: some View {
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
    }

    private var indexSummary: some View {
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

    private func groupSection(_ group: RAGConversationGroup) -> some View {
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

    private func conversationRow(_ conversation: RAGConversationSummary) -> some View {
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
    private func handleConversationDrop(_ providers: [NSItemProvider], toGroupID groupID: UUID?) -> Bool {
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

    // MARK: - Answer surface

    private var answerSurface: some View {
        VStack(spacing: 0) {
            answerHeader
            Divider()
            messageTimeline
            if !viewModel.pendingRemoteRequests.isEmpty {
                Divider()
                remoteConfirmation
            }
            Divider()
            commandComposer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var answerHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.conversations.first(where: { $0.id == viewModel.selectedConversationID })?.title ?? String.l10n("rag.workspace.newConversation"))
                    .font(ragFont(.headline, weight: .semibold))
                    .lineLimit(1)
                Text(stateText(viewModel.answerState))
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // 会话标题右侧：复制 / 导出全部对话（右对齐）。
            if !viewModel.messages.isEmpty {
                CopyFeedbackButton(
                    providesContent: { viewModel.conversationTranscriptMarkdown },
                    tooltip: "rag.workspace.conversation.copyAll"
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(iconFont(size: 13, weight: .medium))
                        .foregroundStyle(didCopy ? Color.green : .secondary)
                        .frame(width: 24, height: 24)
                }
                Button {
                    viewModel.exportConversation()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(iconFont(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("rag.workspace.conversation.exportAll")
            }
            if viewModel.isAnswering {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
    }

    private var messageTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if viewModel.messages.isEmpty && viewModel.streamingAnswer.isEmpty {
                        emptyConversation
                    }
                    ForEach(viewModel.messages) { message in
                        messageView(message)
                            .id(message.id)
                    }
                    if !viewModel.streamingAnswer.isEmpty {
                        assistantMessage(
                            content: viewModel.streamingAnswer,
                            citations: [],
                            showsActions: false
                        )
                            .id("streaming-answer")
                    } else if viewModel.isAnswering {
                        workingIndicator
                            .id("working-indicator")
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.streamingAnswer) { _, _ in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo("streaming-answer", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let id = viewModel.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    /// 新会话空态：与 AI 问答共用 EmptyStateView，水平居中 + 偏上留白。
    private var emptyConversation: some View {
        EmptyStateView(
            systemImage: "text.book.closed",
            title: "rag.workspace.empty.title",
            subtitle: "rag.workspace.empty.subtitle",
            subtitleHorizontalPadding: 40
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func messageView(_ message: RAGStoredMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
                    .font(ragFont(.body))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 680, alignment: .trailing)
            }
        } else {
            assistantMessage(
                content: message.content,
                citations: message.citations,
                showsActions: true
            )
        }
    }

    /// 单条助手回答。复制 / 导出放在正文下方，仅悬停显示；流式中关闭动作条。
    private func assistantMessage(
        content: String,
        citations: [RAGCitation],
        showsActions: Bool
    ) -> some View {
        RAGAssistantMessageBlock(
            content: content,
            citations: citations,
            showsActions: showsActions,
            onSelectCitation: { citation in
                viewModel.selectCitation(citation)
                inspectorTab = .evidence
            },
            onExport: { viewModel.exportAnswer(content) }
        )
    }

    private var workingIndicator: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(stateText(viewModel.answerState))
                .font(ragFont(.callout))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var remoteConfirmation: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("rag.workspace.remote.confirmTitle", systemImage: "network")
                    .font(ragFont(.callout, weight: .semibold))
                Spacer()
                Button("rag.workspace.remote.skip") { viewModel.skipRemoteContext() }
                    .buttonStyle(.borderless)
                Button("rag.workspace.remote.continue") { viewModel.confirmRemoteContext() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.approvedRemoteResources.isEmpty)
            }
            RAGFlowLayout(spacing: 7) {
                ForEach(viewModel.pendingRemoteRequests, id: \.resource) { request in
                    let enabled = viewModel.approvedRemoteResources.contains(request.resource)
                    Button {
                        viewModel.toggleRemoteResource(request.resource)
                    } label: {
                        Label(remoteResourceName(request.resource), systemImage: enabled ? "checkmark.circle.fill" : "circle")
                            .font(ragFont(.caption, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(enabled ? .orange : .gray)
                    .help(request.reason)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.orange.opacity(0.07))
    }

    // MARK: - Composer

    private var commandComposer: some View {
        let hasContextChips = !viewModel.selectedRepoContexts.isEmpty
            || !viewModel.attachments.isEmpty
            || !viewModel.githubLinkContexts.isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            // chip 放在输入框外（对齐 Agent），并按中栏宽度自动换行。
            if hasContextChips {
                HStack(alignment: .top, spacing: 8) {
                    RAGFlowLayout(spacing: 7) {
                        ForEach(viewModel.selectedRepoContexts) { repo in
                            contextChip(title: "@\(repo.fullName)", icon: "shippingbox") {
                                viewModel.removeMention(repoID: repo.id)
                            }
                        }
                        ForEach(viewModel.attachments) { attachment in
                            contextChip(title: attachmentChipTitle(attachment), icon: attachmentIcon(attachment)) {
                                viewModel.removeAttachment(attachment.id)
                            }
                        }
                        ForEach(viewModel.githubLinkContexts, id: \.url) { reference in
                            githubLinkChip(reference)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        viewModel.clearComposerContext()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(iconFont(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("rag.workspace.composer.clearContext")
                }
                .padding(.horizontal, 16)
            }

            if let reason = viewModel.composerBlockingReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(ragFont(.caption))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }

            // 输入主体：文本区 + 底栏；与上方 chip 分离。
            VStack(alignment: .leading, spacing: 8) {
                RAGComposerTextEditor(
                    text: $viewModel.draftQuestion,
                    placeholder: String.l10n(
                        settings.aiChatRequiresCommandReturn
                            ? "rag.workspace.composer.placeholder.commandSend"
                            : "rag.workspace.composer.placeholder.returnSend"
                    ),
                    font: composerNSFont,
                    maximumHeight: composerMaximumHeight,
                    onHeightChange: { composerContentHeight = $0 },
                    onMentionAnchorChange: { mentionCaretAnchor = $0 },
                    onCommand: handleComposerCommand
                )
                // AppKit scroll view 在弹性 VStack 中会忽略子视图的最大高度；由外层显式
                // 约束，首帧严格保持两行，文本变多时再增长到既有上限。
                .frame(height: composerEditorHeight)
                .background(alignment: .topLeading) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .offset(x: mentionCaretAnchor.x, y: mentionCaretAnchor.y)
                        .popover(
                            isPresented: Binding(
                                get: { viewModel.isMentionPickerPresented },
                                set: { presented in
                                    if !presented {
                                        viewModel.dismissMentionPicker()
                                    }
                                }
                            ),
                            attachmentAnchor: .rect(.bounds),
                            arrowEdge: .top
                        ) {
                            mentionPicker
                        }
                }
                .onChange(of: viewModel.draftQuestion) { _, _ in
                    viewModel.handleDraftQuestionChanged()
                }

                HStack(alignment: .center, spacing: 8) {
                    modelMenu

                    if !viewModel.selectedRepoContexts.isEmpty {
                        explicitModeMenu
                    }

                    Spacer(minLength: 8)

                    // 附件在发送按钮左侧，对齐 Agent 输入框。
                    Button { viewModel.chooseAttachments() } label: {
                        Image(systemName: "paperclip")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .foregroundStyle(.secondary)
                    .help("rag.workspace.composer.attach")

                    if viewModel.isAnswering {
                        Button { viewModel.cancelAnswer() } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(iconFont(size: 22, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("rag.workspace.composer.cancel")
                    } else {
                        let canSend = !viewModel.draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && viewModel.composerBlockingReason == nil
                        Button { viewModel.send() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(iconFont(size: 22, weight: .semibold))
                                .foregroundStyle(canSend ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .disabled(!canSend)
                        .help("rag.workspace.composer.send")
                    }
                }
            }
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }

    private func contextChip(title: String, icon: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(title).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.remove")
        }
        .font(ragFont(.caption, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // 与 Agent 输入框上方标签一致：thinMaterial 胶囊，避免贴在 window 底上时几乎看不见。
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    private func githubLinkChip(_ reference: RAGGitHubLinkReference) -> some View {
        HStack(spacing: 5) {
            Button { viewModel.openGitHubLink(reference) } label: {
                Label(githubLinkTitle(reference), systemImage: githubLinkIcon(reference))
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(githubLinkOpenHint(reference))
            Button { viewModel.removeGitHubLink(reference.url) } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.remove")
        }
        .font(ragFont(.caption, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
    }

    /// 简易多选列表：单行仓库名 + checkmark；弹层本身锚在 `@` 光标处。
    private var mentionPicker: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.mentionSuggestions) { repo in
                    Button { viewModel.toggleMention(repo) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(ragFont(.caption, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .opacity(viewModel.isMentionSelected(repo) ? 1 : 0)
                                .frame(width: 12, alignment: .center)
                            Text(repo.fullName)
                                .font(ragFont(.callout))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            repo.id == viewModel.highlightedMentionRepoIDValue
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                }
            }
        }
        .frame(
            width: 280,
            height: min(CGFloat(viewModel.mentionSuggestions.count) * 28 + 8, 260)
        )
        .padding(.vertical, 4)
    }

    private var modelMenu: some View {
        Menu {
            // 用 inline Picker：系统只给当前 selection 打勾，避免手写 checkmark 在
            // macOS Menu 里被全部渲染成已选状态。
            Picker("", selection: $viewModel.selectedModelID) {
                ForEach(viewModel.availableModels) { model in
                    modelPickerLabel(model)
                        .tag(Optional(model.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if let provider = viewModel.selectedModelProvider {
                    AIProviderIconView(provider: provider, size: 14)
                } else {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.secondary)
                }
                Text(viewModel.selectedModelDisplayName)
            }
            .font(ragFont(.caption, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("rag.workspace.composer.model")
    }

    private var explicitModeMenu: some View {
        Menu {
            // Text("key") 走 LocalizedStringKey；勿把 String 字面量传进 Text，否则会显示 raw key。
            Picker("", selection: $viewModel.explicitRepoMode) {
                Text("rag.workspace.repoMode.only").tag(RAGExplicitRepoMode.only)
                Text("rag.workspace.repoMode.prefer").tag(RAGExplicitRepoMode.prefer)
                Text("rag.workspace.repoMode.exclude").tag(RAGExplicitRepoMode.exclude)
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            Label {
                Text(repoModeKey(viewModel.explicitRepoMode))
            } icon: {
                Image(systemName: "scope")
            }
            .font(ragFont(.caption, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// 模型的 providerID 是配置 profile 的 ID，不是 AIServiceProvider 的 rawValue；
    /// 必须经 ViewModel 映射，才能在多个同类服务商 profile 共存时展示正确 logo。
    @ViewBuilder
    private func modelPickerLabel(_ model: AIModelDescriptor) -> some View {
        if let provider = viewModel.provider(for: model) {
            Label {
                Text(model.name)
            } icon: {
                AIProviderIconView(provider: provider, size: 15)
            }
        } else {
            Label(model.name, systemImage: "sparkles")
        }
    }

    // MARK: - Inspector

    private var inspector: some View {
        // 外层必须 leading：默认 center 会把标题整块居中，和下面左对齐正文错位。
        VStack(alignment: .leading, spacing: 0) {
            // 与中栏 answerHeader 同构（headline + caption + 上下 11pt），保证分割线水平对齐。
            // tabs 放在分割线下方，避免把右栏 header 撑高。
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("rag.workspace.inspector.title")
                        .font(ragFont(.headline, weight: .semibold))
                        .lineLimit(1)
                    Text("rag.workspace.inspector.subtitle")
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                #if DEBUG
                // Debug 总开关放在「引用」右侧；开启后才露出「调试」tab。
                HStack(spacing: 5) {
                    Image(systemName: "ladybug")
                        .font(iconFont(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(
                        get: { viewModel.isDebugModeEnabled },
                        set: { enabled in
                            viewModel.isDebugModeEnabled = enabled
                            if enabled {
                                inspectorTab = .debug
                            } else if inspectorTab == .debug {
                                inspectorTab = .evidence
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                }
                .help("rag.workspace.debug.enabled")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("rag.workspace.debug.enabled")
                #endif
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)

            Divider()

            Picker("", selection: $inspectorTab) {
                ForEach(visibleInspectorTabs) { tab in
                    Text(tab.titleKey).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Self.inspectorContentInset)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                switch inspectorTab {
                case .evidence: evidenceInspector
                case .plan: planInspector
                case .index: indexInspector
                #if DEBUG
                case .debug: debugInspector
                #endif
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.26))
    }

    /// 调试 tab 仅在 DEBUG 且开关打开时出现，避免未开启时占 segmented 宽度。
    private var visibleInspectorTabs: [RAGInspectorTab] {
        #if DEBUG
        if viewModel.isDebugModeEnabled {
            return Array(RAGInspectorTab.allCases)
        }
        return RAGInspectorTab.allCases.filter { $0 != .debug }
        #else
        return Array(RAGInspectorTab.allCases)
        #endif
    }

    private var evidenceInspector: some View {
        VStack(alignment: .leading, spacing: 10) {
            if allCitations.isEmpty {
                Text("rag.workspace.inspector.noCitations")
                    .font(ragFont(.body))
                    .foregroundStyle(.secondary)
            } else {
                Text("rag.workspace.inspector.citations")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                // 手风琴：引用列表在上，点一条在该行下方展开细节。
                ForEach(allCitations) { citation in
                    let isExpanded = viewModel.selectedCitation?.id == citation.id
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            viewModel.toggleCitation(citation)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(citation.repoFullName)
                                        .font(ragFont(.callout, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text("\(citation.source.rawValue) · \(citation.sectionTitle)")
                                        .font(ragFont(.caption))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "chevron.right")
                                    .font(iconFont(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()

                        if isExpanded {
                            citationDetail(citation)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 10)
                        }
                    }
                    .background(
                        isExpanded
                            ? Color.accentColor.opacity(0.08)
                            : Color(nsColor: .textBackgroundColor).opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
            }

            if !viewModel.remoteBlocks.isEmpty {
                Divider().padding(.top, 4)
                Text("rag.workspace.inspector.remoteContext")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(viewModel.remoteBlocks, id: \.id) { block in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(block.title)
                            .font(ragFont(.callout, weight: .semibold))
                        Text(block.errorMessage ?? block.content)
                            .font(ragFont(.caption))
                            .foregroundStyle(block.errorMessage == nil
                                ? Color(nsColor: .secondaryLabelColor)
                                : Color.orange)
                            .lineLimit(6)
                        inspectorValue(
                            "rag.workspace.inspector.fetchedAt",
                            value: localizedTimestamp(block.fetchedAt)
                        )
                        if let url = block.sourceURL {
                            Link(destination: url) {
                                Label("rag.workspace.inspector.openGitHub", systemImage: "arrow.up.right.square")
                            }
                            .font(ragFont(.caption))
                        }
                    }
                    .padding(.vertical, 5)
                }
            }

            if !viewModel.historicalRemoteContextAudits.isEmpty {
                Divider().padding(.top, 4)
                Text("rag.workspace.inspector.remoteContext")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ForEach(viewModel.historicalRemoteContextAudits) { audit in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(audit.title)
                            .font(ragFont(.callout, weight: .semibold))
                        if let errorMessage = audit.errorMessage {
                            Text(errorMessage)
                                .font(ragFont(.caption))
                                .foregroundStyle(.orange)
                        }
                        inspectorValue("rag.workspace.inspector.fetchedAt", value: audit.fetchedAt)
                        if let url = audit.sourceURL {
                            Link(destination: url) {
                                Label("rag.workspace.inspector.openGitHub", systemImage: "arrow.up.right.square")
                            }
                            .font(ragFont(.caption))
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .padding(Self.inspectorContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: viewModel.selectedCitation?.id)
    }

    @ViewBuilder
    private func citationDetail(_ citation: RAGCitation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            inspectorValue("rag.workspace.inspector.source", value: citation.source.rawValue)
            inspectorValue("rag.workspace.inspector.location", value: citation.sectionTitle)
            inspectorValue("rag.workspace.inspector.matchType", value: citation.hitKind.rawValue)
            inspectorValue(
                "rag.workspace.inspector.relevance",
                value: String(format: "%.3f", locale: locale, citation.score)
            )
            if let chunk = viewModel.selectedCitationChunk, viewModel.selectedCitation?.id == citation.id {
                Text("rag.workspace.inspector.chunkPreview")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(chunk.content)
                    .font(ragFont(.caption))
                    .textSelection(.enabled)
                    .lineLimit(12)
                if chunk.isTruncated {
                    Label("rag.workspace.inspector.chunkTruncated", systemImage: "scissors")
                        .font(ragFont(.caption))
                        .foregroundStyle(.orange)
                }
            }
            if citation.chunkID == nil {
                Label("rag.workspace.inspector.chunkMissing", systemImage: "exclamationmark.triangle.fill")
                    .font(ragFont(.caption))
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("rag.workspace.inspector.openStarcat") { viewModel.openCitation(citation) }
                Button("rag.workspace.inspector.openGitHub") { viewModel.openGitHub(citation) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private var planInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let plan = viewModel.queryPlan {
                inspectorValue("rag.workspace.inspector.planMode", value: plan.mode.rawValue)
                inspectorValue("rag.workspace.inspector.semanticQuery", value: plan.semanticQuery)
                inspectorValue("rag.workspace.inspector.confidence", value: plan.confidence.rawValue)
                if !plan.userVisiblePlan.chips.isEmpty {
                    RAGFlowLayout(spacing: 7) {
                        ForEach(plan.userVisiblePlan.chips, id: \.self) { chip in
                            Text(chip)
                                .font(ragFont(.caption, weight: .semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                if !plan.remoteContextRequests.isEmpty {
                    Divider()
                    ForEach(plan.remoteContextRequests, id: \.resource) { request in
                        Label(remoteResourceName(request.resource), systemImage: "network")
                            .font(ragFont(.callout, weight: .semibold))
                        Text(request.reason)
                            .font(ragFont(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("rag.workspace.inspector.noPlan")
                    .font(ragFont(.body))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Self.inspectorContentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var indexInspector: some View {
        VStack(alignment: .leading, spacing: 13) {
            coverageRow("rag.workspace.status.repos", value: "\(viewModel.indexCoverage.indexedRepoCount)/\(viewModel.indexCoverage.knowledgeRepoCount)", color: .blue)
            coverageRow("rag.workspace.status.readyChunks", value: "\(viewModel.indexCoverage.readyChunks)", color: .green)
            coverageRow("rag.workspace.status.pendingChunks", value: "\(viewModel.indexCoverage.pendingChunks)", color: .orange)
            coverageRow("rag.workspace.status.failedChunks", value: "\(viewModel.indexCoverage.failedChunks)", color: .red)
            coverageRow("rag.workspace.status.staleChunks", value: "\(viewModel.indexCoverage.staleChunks)", color: .purple)
            Divider()
            HStack {
                Spacer()
                globalIndexStatisticsLabel
                indexProgressLabel
                Button {
                    viewModel.rebuildIndex()
                } label: {
                    HStack(spacing: 6) {
                        rebuildIndexIcon
                        Text("rag.workspace.index.rebuild")
                    }
                }
                .disabled(viewModel.isIndexing)
            }
        }
        .padding(Self.inspectorContentInset)
    }

    #if DEBUG
    /// 「调试」tab 内容：开关已在 header，这里只展示已开启后的 trace 列表。
    private var debugInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Spacer()
                CopyFeedbackButton(
                    providesContent: { viewModel.debugTraceText },
                    tooltip: "rag.workspace.debug.copyAll"
                ) { didCopy in
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                }
                .disabled(viewModel.debugTraces.isEmpty)
                Button("rag.workspace.debug.clear") {
                    viewModel.clearDebugTraces()
                    expandedDebugTraceIDs = []
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.debugTraces.isEmpty)
            }

            if viewModel.debugTraces.isEmpty {
                Text("rag.workspace.debug.empty")
                    .font(ragFont(.body))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.debugTraces.sorted { $0.startedAt < $1.startedAt }) { trace in
                    let isExpanded = expandedDebugTraceIDs.contains(trace.id)
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                if isExpanded { expandedDebugTraceIDs.remove(trace.id) }
                                else { expandedDebugTraceIDs.insert(trace.id) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                    .font(ragFont(.caption2, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12)
                                Text(debugTraceCategoryKey(trace.category))
                                    .font(ragFont(.caption, weight: .semibold))
                                Spacer()
                                Text(localizedTimestamp(trace.startedAt))
                                    .font(ragFont(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(debugTraceStateKey(trace.state))
                                    .font(ragFont(.caption2, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()

                        if isExpanded {
                            ForEach(trace.events) { event in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 6) {
                                        Text(debugStageKey(event.stage))
                                            .font(ragFont(.caption, weight: .semibold))
                                        Spacer()
                                        Text(String(format: String.l10n("rag.workspace.debug.elapsedFormat"), locale: locale, event.elapsedSeconds))
                                            .font(ragFont(.caption2, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        CopyFeedbackButton(
                                            providesContent: { event.payload },
                                            tooltip: "rag.workspace.debug.copy"
                                        ) { didCopy in
                                            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                                                .foregroundStyle(didCopy ? Color.green : Color.secondary)
                                        }
                                    }
                                    Text(event.payload)
                                        .font(ragFont(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                .padding(10)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
        .padding(Self.inspectorContentInset)
    }

    private func debugStageKey(_ stage: RAGDebugEvent.Stage) -> LocalizedStringKey {
        switch stage {
        case .request: return "rag.workspace.debug.stage.request"
        case .plan: return "rag.workspace.debug.stage.plan"
        case .candidates: return "rag.workspace.debug.stage.candidates"
        case .retrieval: return "rag.workspace.debug.stage.retrieval"
        case .remoteContext: return "rag.workspace.debug.stage.remoteContext"
        case .prompt: return "rag.workspace.debug.stage.prompt"
        case .response: return "rag.workspace.debug.stage.response"
        case .titlePrompt: return "rag.workspace.debug.stage.titlePrompt"
        case .titleResponse: return "rag.workspace.debug.stage.titleResponse"
        case .failure: return "rag.workspace.debug.stage.failure"
        }
    }

    private func debugTraceCategoryKey(_ category: RAGDebugTraceCategory) -> LocalizedStringKey {
        switch category {
        case .questionAnswer: return "rag.workspace.debug.category.questionAnswer"
        case .conversationTitle: return "rag.workspace.debug.category.conversationTitle"
        }
    }

    private func debugTraceStateKey(_ state: RAGDebugTrace.State) -> LocalizedStringKey {
        switch state {
        case .running: return "rag.workspace.debug.state.running"
        case .completed: return "rag.workspace.debug.state.completed"
        case .failed: return "rag.workspace.debug.state.failed"
        case .cancelled: return "rag.workspace.debug.state.cancelled"
        }
    }
    #endif

    private func inspectorValue(_ label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(ragFont(.callout, weight: .semibold))
                .textSelection(.enabled)
        }
    }

    private func coverageRow(_ label: LocalizedStringKey, value: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(ragFont(.callout))
            Spacer()
            Text(value)
                .font(ragFont(.callout, weight: .semibold, design: .monospaced))
        }
    }

    @ViewBuilder
    private var rebuildIndexIcon: some View {
        if reduceMotion {
            Image(systemName: "arrow.triangle.2.circlepath")
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, options: .repeating, isActive: viewModel.isIndexing)
        }
    }

    private var globalIndexStatisticsLabel: some View {
        HStack(spacing: 8) {
            statisticValue(
                "\(viewModel.indexCoverage.indexedRepoCount)/\(viewModel.indexCoverage.knowledgeRepoCount)",
                label: "rag.workspace.status.repos"
            )
            statisticValue(
                "\(viewModel.indexCoverage.readyChunks)",
                label: "rag.workspace.status.readyChunks"
            )
        }
        .font(ragFont(.caption2))
        .foregroundStyle(.secondary)
    }

    private func statisticValue(_ value: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: 3) {
            Text(value).monospacedDigit()
            Text(label)
        }
    }

    @ViewBuilder
    private var indexProgressLabel: some View {
        switch viewModel.indexingStatus {
        case .fetchingReadmes(let processed, let total):
            compactIndexProgress("rag.workspace.index.fetchingReadmes", processed: processed, total: total)
        case .building(let processed, let total):
            compactIndexProgress("rag.workspace.index.buildingChunks", processed: processed, total: total)
        case .embedding(let processed, let total):
            compactIndexProgress("rag.workspace.index.embeddingChunks", processed: processed, total: total)
        case .idle, .completed, .failed:
            EmptyView()
        }
    }

    private func compactIndexProgress(_ title: LocalizedStringKey, processed: Int, total: Int) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Text("\(processed)/\(total)").monospacedDigit()
        }
        .font(ragFont(.caption2))
        .foregroundStyle(.secondary)
    }

    private var composerNSFont: NSFont {
        NSFont.systemFont(ofSize: 13 * interfaceScale.multiplier)
    }

    private var composerMinimumHeight: CGFloat {
        let lineHeight = composerNSFont.ascender - composerNSFont.descender + composerNSFont.leading
        return ceil(lineHeight * 2 + RAGComposerTextEditor.verticalInset * 2)
    }

    private var composerMaximumHeight: CGFloat {
        118 * interfaceScale.multiplier
    }

    private var composerEditorHeight: CGFloat {
        min(max(composerContentHeight, composerMinimumHeight), composerMaximumHeight)
    }

    private func handleComposerCommand(_ command: RAGComposerTextEditor.Command) -> Bool {
        switch command {
        case .returnKey(let modifiers):
            let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            // @ 候选打开时：Enter 切换勾选；Cmd+Enter 仍走发送偏好。
            if viewModel.isMentionPickerPresented, !flags.contains(.command) {
                viewModel.selectHighlightedMention()
                return true
            }
            // 与设置「需按 ⌘ + 回车键发送 AI 问题」同一偏好：
            // 开=⌘↩发送 / Return 换行；关=Return 发送 / ⌘↩ 换行。
            if settings.aiChatRequiresCommandReturn {
                if flags.contains(.command) {
                    viewModel.send()
                    return true
                }
                return false
            }
            if flags.contains(.command) {
                return false
            }
            viewModel.send()
            return true
        case .upArrow:
            guard viewModel.isMentionPickerPresented else { return false }
            viewModel.moveMentionSelection(by: -1)
            return true
        case .downArrow:
            guard viewModel.isMentionPickerPresented else { return false }
            viewModel.moveMentionSelection(by: 1)
            return true
        case .escape:
            guard viewModel.isMentionPickerPresented else { return false }
            viewModel.dismissMentionPicker()
            return true
        }
    }

    private func localizedTimestamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    /// 右侧「证据」列表：按相关度降序，同分再按仓库名稳定排序。
    private var allCitations: [RAGCitation] {
        var seen = Set<UUID>()
        return viewModel.messages
            .flatMap(\.citations)
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.repoFullName.localizedStandardCompare($1.repoFullName) == .orderedAscending
            }
    }

    // MARK: - Display helpers

    private func stateText(_ state: RAGAnswerState) -> String {
        switch state {
        case .idle, .completed: return String.l10n("rag.workspace.header.ready")
        case .planning: return String.l10n("rag.workspace.state.planning")
        case .needsClarification: return String.l10n("rag.workspace.state.needsClarification")
        case .noKnowledgeRepos: return String.l10n("rag.workspace.state.noKnowledgeRepos")
        case .noCandidates: return String.l10n("rag.workspace.state.noCandidates")
        case .noIndex: return String.l10n("rag.workspace.state.noIndex")
        case .noRelevantChunks: return String.l10n("rag.workspace.state.noRelevantChunks")
        case .retrieving: return String.l10n("rag.workspace.state.retrieving")
        case .awaitingRemoteContextConfirmation: return String.l10n("rag.workspace.state.awaitingRemote")
        case .fetchingRemoteContext: return String.l10n("rag.workspace.state.fetchingRemote")
        case .generating: return String.l10n("rag.workspace.state.generating")
        case .cancelled: return String.l10n("rag.workspace.state.cancelled")
        case .failed(let message): return message
        }
    }

    private func repoModeKey(_ mode: RAGExplicitRepoMode) -> LocalizedStringKey {
        switch mode {
        case .only: return "rag.workspace.repoMode.only"
        case .prefer: return "rag.workspace.repoMode.prefer"
        case .exclude: return "rag.workspace.repoMode.exclude"
        }
    }

    private func githubLinkTitle(_ reference: RAGGitHubLinkReference) -> String {
        let name = "\(reference.owner)/\(reference.repo)"
        switch reference.relation {
        case .inKnowledge:
            return name
        case .knownButNotInKnowledge:
            return "\(name) · \(String.l10n("rag.workspace.link.knownButNotInLibrary"))"
        case .external:
            return "\(name) · \(String.l10n("rag.workspace.link.external"))"
        }
    }

    private func githubLinkIcon(_ reference: RAGGitHubLinkReference) -> String {
        switch reference.relation {
        case .inKnowledge, .knownButNotInKnowledge: return "shippingbox"
        case .external: return "arrow.up.right.square"
        }
    }

    private func githubLinkOpenHint(_ reference: RAGGitHubLinkReference) -> String {
        reference.relation == .knownButNotInKnowledge
            ? String.l10n("rag.workspace.inspector.openStarcat")
            : String.l10n("rag.workspace.inspector.openGitHub")
    }

    private func remoteResourceName(_ resource: RAGRemoteContextResource) -> String {
        switch resource {
        case .githubIssues: return "GitHub Issues"
        case .githubPullRequests: return "GitHub Pull Requests"
        case .githubReleases: return "GitHub Releases"
        case .githubContributors: return "GitHub Contributors"
        case .githubCommitActivity: return "GitHub Commit Activity"
        case .githubSecurityAdvisories: return "GitHub Security Advisories"
        }
    }

    private func attachmentChipTitle(_ attachment: RAGComposerAttachment) -> String {
        let size = ByteCountFormatter.string(fromByteCount: attachment.sizeInBytes, countStyle: .file)
        return "\(attachment.filename) · \(size)"
    }

    private func attachmentIcon(_ attachment: RAGComposerAttachment) -> String {
        switch attachment.handling {
        case .textContext: return "doc"
        case .vision: return "photo"
        case .unsupported: return "exclamationmark.triangle"
        }
    }

    private enum RAGFontRole {
        case headline, subheadline, body, callout, caption, caption2

        var typography: StarcatTypography {
            switch self {
            case .headline: return .panelTitle
            case .subheadline: return .rowTitle
            case .body: return .body
            case .callout: return .bodyEmphasis
            case .caption: return .caption
            case .caption2: return .captionSmall
            }
        }
    }

    private func ragFont(_ role: RAGFontRole, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        interfaceScale.font(role.typography, weight: weight, design: design)
    }

    private func iconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }
}

/// 助手回答块：动作条在整块底部（引用下方）；始终占位，悬停才显形，避免布局跳动。
/// 复制反馈播放期间强制保持可见，避免鼠标移开后看不到绿色 ✓。
private struct RAGAssistantMessageBlock: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    let content: String
    let citations: [RAGCitation]
    let showsActions: Bool
    let onSelectCitation: (RAGCitation) -> Void
    let onExport: () -> Void

    @State private var isHovered = false
    /// 与 `CopyFeedbackButton` 的 1.5s 反馈窗口对齐：反馈未结束前不因失悬停而隐藏。
    @State private var isCopyFeedbackPinned = false
    @State private var copyFeedbackPinTask: Task<Void, Never>?

    private var areActionsRevealed: Bool {
        isHovered || isCopyFeedbackPinned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("rag.workspace.message.assistant")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            RAGMarkdownText(content: content)
                .font(interfaceScale.font(.body))
                .textSelection(.enabled)
                .frame(maxWidth: 900, alignment: .leading)

            if !citations.isEmpty {
                // 随中栏宽度自动换行，与输入框上方附件 chip 同一套 FlowLayout。
                RAGFlowLayout(spacing: 7) {
                    ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                        Button {
                            onSelectCitation(citation)
                        } label: {
                            Text("\(index + 1). \(citation.repoFullName)")
                                .font(interfaceScale.font(.caption, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showsActions {
                HStack(spacing: 10) {
                    CopyFeedbackButton(
                        performCopy: {
                            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return false }
                            NSPasteboard.general.clearContents()
                            let ok = NSPasteboard.general.setString(trimmed, forType: .string)
                            if ok { pinActionsForCopyFeedback() }
                            return ok
                        },
                        tooltip: "rag.workspace.answer.copy"
                    ) { didCopy in
                        Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(interfaceScale.font(size: 12, weight: .medium))
                            .foregroundStyle(didCopy ? Color.green : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    Button(action: onExport) {
                        Image(systemName: "square.and.arrow.up")
                            .font(interfaceScale.font(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("rag.workspace.answer.export")
                    Spacer(minLength: 0)
                }
                // 始终占位：只切透明度 / 命中，避免悬停时把下方内容顶开。
                .opacity(areActionsRevealed ? 1 : 0)
                .allowsHitTesting(areActionsRevealed)
                .accessibilityHidden(!areActionsRevealed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: areActionsRevealed)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard showsActions else { return }
            isHovered = hovering
        }
        .onDisappear {
            copyFeedbackPinTask?.cancel()
            copyFeedbackPinTask = nil
        }
    }

    /// 钉住动作条直到复制反馈结束（与 CopyFeedbackButton 1.5s 窗口一致）。
    private func pinActionsForCopyFeedback() {
        isCopyFeedbackPinned = true
        copyFeedbackPinTask?.cancel()
        copyFeedbackPinTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            isCopyFeedbackPinned = false
        }
    }
}

/// RAG 输入框的 AppKit 桥接层。
///
/// SwiftUI `TextEditor` 会在弹性 VStack 中被扩展到远超 `maxHeight`，且 overlay
/// placeholder 无法与 NSTextView 的 insertion point 共享基线。本组件让 placeholder
/// 直接由同一个 NSTextView 绘制，并把内容实际高度回传给工作台，保证首帧两行且仍可
/// 在长问题时增长到调用方规定的上限。
private struct RAGComposerTextEditor: NSViewRepresentable {
    static let verticalInset: CGFloat = 4

    enum Command {
        case returnKey(NSEvent.ModifierFlags)
        case upArrow
        case downArrow
        case escape
    }

    @Binding var text: String
    let placeholder: String
    let font: NSFont
    let maximumHeight: CGFloat
    let onHeightChange: (CGFloat) -> Void
    /// `@` 字形相对 NSScrollView 左上角的锚点（弹层挂这里，避免整框居中）。
    let onMentionAnchorChange: (CGPoint) -> Void
    let onCommand: (Command) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = RAGComposerTextView()

        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)
        // Cmd+Enter 多数情况下不会进 insertNewline:，必须在 keyDown 拦截。
        textView.onCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.parent.onCommand(command) ?? false
        }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // 首次布局后再计算 usedRect，避免 NSTextLayoutManager 尚未拿到容器宽度时
        // 错报单行高度，导致窗口打开的一帧内输入框跳动。
        DispatchQueue.main.async {
            context.coordinator.reportHeight(for: textView)
            context.coordinator.reportMentionAnchor(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? RAGComposerTextView else { return }

        textView.font = font
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)
        textView.onCommand = { [weak coordinator = context.coordinator] command in
            coordinator?.parent.onCommand(command) ?? false
        }
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            context.coordinator.reportHeight(for: textView)
        }
        context.coordinator.reportMentionAnchor(for: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RAGComposerTextEditor

        init(parent: RAGComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? RAGComposerTextView else { return }
            parent.text = textView.string
            textView.needsDisplay = true
            reportHeight(for: textView)
            reportMentionAnchor(for: textView)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                // 去掉 capsLock 等噪声位，否则 .command 判断偶发失败。
                let modifiers = (NSApp.currentEvent?.modifierFlags ?? [])
                    .intersection(.deviceIndependentFlagsMask)
                return parent.onCommand(.returnKey(modifiers))
            case #selector(NSResponder.moveUp(_:)):
                return parent.onCommand(.upArrow)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onCommand(.downArrow)
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onCommand(.escape)
            default:
                return false
            }
        }

        func reportHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedHeight = layoutManager.usedRect(for: textContainer).height
            let height = min(
                ceil(usedHeight + RAGComposerTextEditor.verticalInset * 2),
                parent.maximumHeight
            )
            parent.onHeightChange(height)
        }

        /// 把最后一个未完成 `@token` 的字形矩形换算到 scrollView 坐标，供 SwiftUI 弹层锚定。
        func reportMentionAnchor(for textView: NSTextView) {
            guard let scrollView = textView.enclosingScrollView,
                  let at = textView.string.lastIndex(of: "@") else { return }
            let after = textView.string.index(after: at)
            let suffix = textView.string[after...]
            guard !suffix.contains(where: \.isWhitespace) else { return }

            if let layoutManager = textView.layoutManager,
               let textContainer = textView.textContainer {
                layoutManager.ensureLayout(for: textContainer)
            }

            let location = textView.string.utf16.distance(from: textView.string.startIndex, to: at)
            var actualRange = NSRange(location: 0, length: 0)
            let screenRect = textView.firstRect(
                forCharacterRange: NSRange(location: location, length: 1),
                actualRange: &actualRange
            )
            guard let window = textView.window, screenRect != .zero else { return }
            let windowRect = window.convertFromScreen(screenRect)
            let local = scrollView.convert(windowRect, from: nil)
            // AppKit Y 从底向上；SwiftUI topLeading offset 从顶向下，需要翻转。
            // 锚在 `@` 字形下缘，arrowEdge=.top 时弹层出现在光标正下方。
            let swiftY = scrollView.bounds.height - local.minY
            parent.onMentionAnchorChange(CGPoint(x: local.minX, y: swiftY))
        }
    }
}

/// placeholder 在 NSTextView 自身坐标系中绘制，基线与光标完全一致。
private final class RAGComposerTextView: NSTextView {
    var placeholder = ""
    /// 键盘命令回调（Cmd+Enter 发送等）；由 Representable 注入。
    var onCommand: ((RAGComposerTextEditor.Command) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 36 = Return，76 = 小键盘 Enter。
        // Cmd+Enter 通常不会走 insertNewline:，必须在 keyDown 拦下再交给 onCommand
        // （是否真正发送由设置里的 aiChatRequiresCommandReturn 决定）。
        if (event.keyCode == 36 || event.keyCode == 76), flags.contains(.command) {
            if onCommand?(.returnKey(flags)) == true {
                return
            }
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        placeholder.draw(
            at: NSPoint(x: textContainerInset.width, y: textContainerInset.height),
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.placeholderTextColor
            ]
        )
    }
}

private enum RAGConversationDropTarget: Equatable {
    case group(UUID)
    case ungrouped
}

private enum RAGInspectorTab: String, CaseIterable, Identifiable {
    case evidence
    case plan
    case index
    #if DEBUG
    case debug
    #endif

    var id: String { rawValue }
    var titleKey: LocalizedStringKey {
        switch self {
        case .evidence: return "rag.workspace.inspector.tab.evidence"
        case .plan: return "rag.workspace.inspector.tab.plan"
        case .index: return "rag.workspace.inspector.tab.index"
        #if DEBUG
        case .debug: return "rag.workspace.inspector.tab.debug"
        #endif
        }
    }
}

private struct RAGMarkdownText: View {
    let content: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: content) {
            Text(attributed)
        } else {
            Text(content)
        }
    }
}

/// 紧凑换行布局：Inspector chips / 输入框上方的 repo·附件 chip 共用，随容器宽度折行。
private struct RAGFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, item) in arrangement.items.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
            )
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, items: [(origin: CGPoint, size: CGSize)]) {
        let maxWidth = proposal.width ?? .infinity
        var items: [(origin: CGPoint, size: CGSize)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            // 单颗 chip 不应宽过容器，否则无法折行时仍会横向溢出。
            let size = subview.sizeThatFits(
                ProposedViewSize(width: maxWidth == .infinity ? nil : maxWidth, height: nil)
            )
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            items.append((CGPoint(x: x, y: y), size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: min(usedWidth, maxWidth), height: y + lineHeight), items)
    }
}
