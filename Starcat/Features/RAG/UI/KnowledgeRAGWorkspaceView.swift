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

    let chromeState: WorkspaceChromeState
    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @State private var inspectorTab: RAGInspectorTab = .evidence
    @State private var composerContentHeight: CGFloat = 0
    @State private var expandedDebugTraceIDs: Set<UUID> = []
    @State private var renameTarget: RAGConversationSummary?
    @State private var renameDraft = ""

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
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: chromeState.isLeftColumnCollapsed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: chromeState.isRightColumnCollapsed)
    }

    // MARK: - Conversation rail

    private var conversationRail: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Button { viewModel.showKnowledgeBrowser() } label: {
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
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right.square")
                            .font(iconFont(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("rag.browser.open")

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
                        // 与会话行同款圆角方形，不用 .bordered 的胶囊形。
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    Text("rag.workspace.recentConversations")
                        .font(ragFont(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)

                    ForEach(viewModel.conversations) { conversation in
                        conversationRow(conversation)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34))
    }

    private var indexSummary: some View {
        Button { viewModel.showKnowledgeBrowser() } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Label("rag.workspace.status.knowledgeBase", systemImage: "books.vertical")
                        .font(ragFont(.caption, weight: .semibold))
                    Spacer()
                    Text("\(viewModel.indexCoverage.indexedRepoCount)/\(viewModel.indexCoverage.knowledgeRepoCount)")
                        .font(ragFont(.caption, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                // 覆盖率条会在 1/1 时一直满蓝，误读成装饰；只在真正 rebuild 时显示不确定进度。
                if viewModel.isIndexing {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                HStack {
                    Text(String(format: String.l10n("rag.workspace.status.readyChunksFormat"), locale: locale, viewModel.indexCoverage.readyChunks))
                    Spacer()
                    if viewModel.indexCoverage.pendingChunks + viewModel.indexCoverage.failedChunks + viewModel.indexCoverage.staleChunks > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("rag.workspace.status.indexIncomplete")
                    }
                }
                .font(ragFont(.caption2))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 8))
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("rag.browser.open")
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
            Spacer()
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
                        assistantMessage(content: viewModel.streamingAnswer, citations: [])
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
            assistantMessage(content: message.content, citations: message.citations)
        }
    }

    private func assistantMessage(content: String, citations: [RAGCitation]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("rag.workspace.message.assistant")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { viewModel.copyAnswer(content) } label: {
                    Image(systemName: "doc.on.doc").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("rag.workspace.answer.copy")
                Button { viewModel.exportAnswer(content) } label: {
                    Image(systemName: "square.and.arrow.up").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("rag.workspace.answer.export")
            }
            RAGMarkdownText(content: content)
                .font(ragFont(.body))
                .textSelection(.enabled)
                .frame(maxWidth: 900, alignment: .leading)
            if !citations.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(Array(citations.enumerated()), id: \.element.id) { index, citation in
                            Button {
                                viewModel.selectCitation(citation)
                                inspectorTab = .evidence
                            } label: {
                                Label("S\(index + 1) · \(citation.repoFullName)", systemImage: "quote.opening")
                                    .font(ragFont(.caption, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
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
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.selectedRepoContexts.isEmpty || !viewModel.attachments.isEmpty || !viewModel.githubLinkContexts.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
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
                }
                .scrollIndicators(.hidden)
            }

            if let reason = viewModel.composerBlockingReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(ragFont(.caption))
                    .foregroundStyle(.orange)
            }

            RAGComposerTextEditor(
                text: $viewModel.draftQuestion,
                placeholder: String.l10n("rag.workspace.composer.placeholder"),
                font: composerNSFont,
                maximumHeight: composerMaximumHeight,
                onHeightChange: { composerContentHeight = $0 },
                onCommand: handleComposerCommand
            )
            // AppKit scroll view 在弹性 VStack 中会忽略子视图的最大高度；由外层显式
            // 约束，首帧严格保持两行，文本变多时再增长到既有上限。
            .frame(height: composerEditorHeight)
            .onChange(of: viewModel.draftQuestion) { _, _ in
                viewModel.handleDraftQuestionChanged()
            }
            .popover(
                isPresented: Binding(
                    get: { viewModel.isMentionPickerPresented },
                    set: { _ in }
                ),
                arrowEdge: .bottom
            ) {
                mentionPicker
            }

            HStack(spacing: 8) {
                Button { viewModel.chooseAttachments() } label: {
                    Image(systemName: "paperclip")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("rag.workspace.composer.attach")

                modelMenu

                if !viewModel.selectedRepoContexts.isEmpty {
                    explicitModeMenu
                }

                Spacer()

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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private var mentionPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("rag.workspace.mention.title")
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.mentionSuggestions) { repo in
                        Button { viewModel.selectMention(repo) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repo.fullName)
                                        .font(ragFont(.callout, weight: .semibold))
                                    Text(repo.description ?? String.l10n("rag.workspace.mention.noDescription"))
                                        .font(ragFont(.caption))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                            .background(
                                repo.id == viewModel.highlightedMentionRepoIDValue
                                    ? Color.accentColor.opacity(0.12)
                                    : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }
                .padding(5)
            }
        }
        .frame(width: 360, height: min(CGFloat(viewModel.mentionSuggestions.count) * 54 + 42, 360))
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
            VStack(alignment: .leading, spacing: 2) {
                Text("rag.workspace.inspector.title")
                    .font(ragFont(.headline, weight: .semibold))
                    .lineLimit(1)
                Text("rag.workspace.inspector.subtitle")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)

            Divider()

            Picker("", selection: $inspectorTab) {
                ForEach(RAGInspectorTab.allCases) { tab in
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

    private var evidenceInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let citation = viewModel.selectedCitation {
                VStack(alignment: .leading, spacing: 9) {
                    Text(citation.repoFullName)
                        .font(ragFont(.subheadline, weight: .semibold))
                    inspectorValue("rag.workspace.inspector.source", value: citation.source.rawValue)
                    inspectorValue("rag.workspace.inspector.location", value: citation.sectionTitle)
                    inspectorValue("rag.workspace.inspector.matchType", value: citation.hitKind.rawValue)
                    inspectorValue("rag.workspace.inspector.relevance", value: String(format: "%.3f", locale: locale, citation.score))
                    if let chunk = viewModel.selectedCitationChunk {
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
                .padding(.bottom, 2)
                Divider()
            }

            Text("rag.workspace.inspector.otherCitations")
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(allCitations) { citation in
                Button {
                    viewModel.selectCitation(citation)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(citation.repoFullName)
                            .font(ragFont(.callout, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("\(citation.source.rawValue) · \(citation.sectionTitle)")
                            .font(ragFont(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }

            if !viewModel.remoteBlocks.isEmpty {
                Divider()
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
                Divider()
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
    private var debugInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 调试开关只出现在「调试」tab，避免其它 tab 顶部多出一行错位控件。
            Toggle(
                isOn: Binding(
                    get: { viewModel.isDebugModeEnabled },
                    set: { viewModel.isDebugModeEnabled = $0 }
                )
            ) {
                Label("rag.workspace.debug.enabled", systemImage: "ladybug")
                    .font(ragFont(.caption, weight: .semibold))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if !viewModel.isDebugModeEnabled {
                Text("rag.workspace.debug.disabledHint")
                    .font(ragFont(.body))
                    .foregroundStyle(.secondary)
            } else {
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
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedDebugTraceIDs.contains(trace.id) },
                                set: { isExpanded in
                                    if isExpanded { expandedDebugTraceIDs.insert(trace.id) }
                                    else { expandedDebugTraceIDs.remove(trace.id) }
                                }
                            )
                        ) {
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
                        } label: {
                            HStack(spacing: 6) {
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
                        }
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    }
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
            if viewModel.isMentionPickerPresented, !modifiers.contains(.command) {
                viewModel.selectHighlightedMention()
                return true
            }
            if modifiers.contains(.command) {
                viewModel.send()
                return true
            }
            return false
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

    private var allCitations: [RAGCitation] {
        var seen = Set<UUID>()
        return viewModel.messages.flatMap(\.citations).filter { seen.insert($0.id).inserted }
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
        let handling: String
        switch attachment.handling {
        case .textContext: handling = String.l10n("rag.workspace.attachment.textContext")
        case .vision: handling = String.l10n("rag.workspace.attachment.vision")
        case .unsupported: handling = String.l10n("rag.workspace.attachment.unsupported")
        }
        return "\(attachment.filename) · \(attachment.contentType) · \(handling) · \(size)"
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

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        // 首次布局后再计算 usedRect，避免 NSTextLayoutManager 尚未拿到容器宽度时
        // 错报单行高度，导致窗口打开的一帧内输入框跳动。
        DispatchQueue.main.async {
            context.coordinator.reportHeight(for: textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? RAGComposerTextView else { return }

        textView.font = font
        textView.placeholder = placeholder
        textView.setAccessibilityLabel(placeholder)
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            context.coordinator.reportHeight(for: textView)
        }
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
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let modifiers = NSApp.currentEvent?.modifierFlags ?? []
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
    }
}

/// placeholder 在 NSTextView 自身坐标系中绘制，基线与光标完全一致。
private final class RAGComposerTextView: NSTextView {
    var placeholder = ""

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

/// 少量 query/context chips 的紧凑换行布局，避免固定 HStack 在右侧 Inspector 中截断。
private struct RAGFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in arrangement.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (CGSize(width: min(usedWidth, maxWidth), height: y + lineHeight), points)
    }
}
