//
//  RAGWorkspaceAnswerSurface.swift
//  Starcat
//
//  知识库 RAG 工作台的回答时间线、远程确认与输入 Composer。
//

import AppKit
import SwiftUI

struct RAGWorkspaceAnswerSurface: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @State private var composerContentHeight: CGFloat = 0
    @State private var mentionCaretAnchor: CGPoint = .zero
    @State private var messageTail = ScrollTailController()
    @State private var isMessageTailScrollScheduled = false
    @State private var isMessageNearBottom = true

    private static let messageBottomAnchorID = "rag-message-bottom-anchor"
    private static let messageNearBottomThreshold: CGFloat = 64

    private func ragFont(_ role: RAGFontRole, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        interfaceScale.font(role.typography, weight: weight, design: design)
    }

    private func iconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }

    var body: some View {
        VStack(spacing: 0) {
            answerHeader
            Divider()
            // 空态放在 ScrollView 外，才能占满中栏剩余高度并真正上下居中。
            if showsEmptyConversation {
                emptyConversation
            } else {
                messageTimeline
            }
            if !viewModel.pendingRemoteRequests.isEmpty {
                Divider()
                remoteConfirmation
            }
            Divider()
            commandComposer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 新会话且尚未开始回答时显示空态提示。
    var showsEmptyConversation: Bool {
        viewModel.messages.isEmpty
            && viewModel.streamingAnswer.isEmpty
            && !viewModel.isAnswering
    }

    var answerHeader: some View {
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

    var messageTimeline: some View {
        let outlineTurns = RAGConversationOutlineBuilder.completeTurns(from: viewModel.messages)
        let hasTimelineContent = !viewModel.messages.isEmpty
            || !viewModel.streamingAnswer.isEmpty
            || viewModel.isAnswering
        // 显隐只看几何「是否离底」：不要读 messageTail.isFollowing，否则滚动 phase
        // 每次变化都会整页刷新，鼠标划过按钮时更容易闪没并卡顿。
        let showsScrollToBottom = hasTimelineContent && !isMessageNearBottom
        return ScrollViewReader { proxy in
            ZStack(alignment: .leading) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(viewModel.messages) { message in
                            messageView(message)
                                .id(message.id)
                        }
                        if !viewModel.executionSteps.isEmpty
                            || !viewModel.streamingAnswer.isEmpty
                            || viewModel.isAnswering {
                            liveAssistantMessage
                                .id("live-assistant-message")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(Self.messageBottomAnchorID)
                            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                                messageTail.updateBottomVisibility(isVisible)
                            }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onScrollPhaseChange { _, newPhase in
                    messageTail.updatePhase(newPhase)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let remaining = geometry.contentSize.height
                        - geometry.contentOffset.y
                        - geometry.containerSize.height
                    return remaining <= Self.messageNearBottomThreshold
                } action: { _, isNearBottom in
                    guard isMessageNearBottom != isNearBottom else { return }
                    isMessageNearBottom = isNearBottom
                }
                .onChange(of: viewModel.loadedMessageSequence) { _, _ in
                    // 只在 ViewModel 已写入历史 messages 后响应；监听 selectedConversationID 会早于
                    // LazyVStack 的内容更新，导致复用上一会话的顶部偏移。
                    isMessageNearBottom = true
                    messageTail.resumeFollowing()
                    forceMessageTailScroll(proxy: proxy)
                }
                .onChange(of: viewModel.streamingAnswer) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    scheduleMessageTailScroll(proxy: proxy)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    scheduleMessageTailScroll(proxy: proxy)
                }

                // 左侧大纲轨叠在时间线之上，但宽度仅覆盖横线/预览卡，不挡住正文点击。
                if !outlineTurns.isEmpty {
                    RAGConversationOutlineRail(
                        turns: outlineTurns,
                        onSelect: { turn in
                            messageTail.pauseFollowing()
                            isMessageNearBottom = false
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                                proxy.scrollTo(turn.userMessageID, anchor: .top)
                            }
                        },
                        timeLabel: messageTimeLabel
                    )
                    .padding(.leading, 6)
                    .padding(.vertical, 12)
                    .frame(maxHeight: .infinity, alignment: .leading)
                }
            }
            .overlay(alignment: .bottom) {
                if showsScrollToBottom {
                    scrollToBottomButton {
                        messageTail.resumeFollowing()
                        // 手动请求优先于旧的用户滚动 phase：本次必须到底，后续 token 才继续自动跟随。
                        forceMessageTailScroll(proxy: proxy)
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    /// 中栏底部居中的「滚到底部」快捷入口；仅在内容未贴底时出现。
    func scrollToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(iconFont(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(.regularMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("rag.workspace.scrollToBottom")
        .accessibilityLabel(Text("rag.workspace.scrollToBottom"))
        .pointerStyle(.link)
    }

    /// 合并流式回答与手动点击产生的尾部滚动请求。
    ///
    /// `ScrollViewProxy` 必须在本轮 SwiftUI 布局提交后才拥有最新 sentinel 位置；延迟一个
    /// 主线程周期并关闭动画，既保证按钮点击能到达真正底部，也避免每个 delta 叠加动画事务。
    func scheduleMessageTailScroll(proxy: ScrollViewProxy) {
        guard messageTail.isFollowing, !isMessageTailScrollScheduled else { return }
        isMessageTailScrollScheduled = true

        Task { @MainActor in
            await Task.yield()
            defer { isMessageTailScrollScheduled = false }
            guard messageTail.isFollowing else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.messageBottomAnchorID, anchor: .bottom)
            }
        }
    }

    /// 用户明确要求展示最新内容时的强制滚动。
    ///
    /// 它故意不检查 `messageTail.isFollowing`：按钮点击时旧的 `.decelerating` 回调可能尚未
    /// 结束，若沿用自动跟随的二次 guard，点击会被错误取消，表现为按钮消失却没有到底。
    func forceMessageTailScroll(proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            // 第一轮 yield 让 messages 进入 body，第二轮才确保 LazyVStack 已产生最新 sentinel。
            await Task.yield()

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.messageBottomAnchorID, anchor: .bottom)
            }
        }
    }

    /// 新会话空态：放大图标/文案，并在中栏剩余区域上下左右居中。
    var emptyConversation: some View {
        EmptyStateView(
            systemImage: "text.book.closed",
            title: "rag.workspace.empty.title",
            subtitle: "rag.workspace.empty.subtitle",
            iconSize: interfaceScale.scaled(52),
            spacing: 14,
            subtitleHorizontalPadding: 48,
            titleFont: interfaceScale.font(.workspaceTitle, weight: .semibold),
            subtitleFont: ragFont(.callout)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func messageView(_ message: RAGStoredMessage) -> some View {
        if message.role == .user {
            RAGUserMessageBlock(
                message: message,
                avatarURL: authSession.state.user?.avatarUrl,
                isEditing: viewModel.editingUserMessageID == message.id,
                showsPendingActions: viewModel.pendingActionUserMessageID == message.id
                    && viewModel.editingUserMessageID != message.id,
                editingDraft: $viewModel.editingUserDraft,
                onCopyToComposer: {
                    viewModel.copyQuestionToComposerAndPasteboard(message.content)
                },
                onBeginEdit: { viewModel.beginEditUserMessage(message.id) },
                onCancelEdit: { viewModel.cancelEditUserMessage() },
                onSubmitEdit: { viewModel.submitEditedUserMessage() },
                timeLabel: messageTimeLabel(message.createdAt)
            )
        } else {
            assistantMessage(
                content: message.content,
                citations: message.citations,
                createdAt: message.createdAt,
                showsActions: true,
                executionTrace: message.executionTrace
            )
        }
    }

    /// 单条助手回答。复制 / 导出放在正文下方，仅悬停显示；流式中关闭动作条。
    @ViewBuilder
    var liveAssistantMessage: some View {
        if let snapshot = viewModel.streamingPresentation {
            RAGStreamingAssistantMessageBlock(
                snapshot: snapshot,
                executionTrace: viewModel.executionSteps,
                activityLabel: liveAssistantActivityLabel()
            )
        } else {
            assistantMessage(
                content: viewModel.streamingAnswer,
                citations: [],
                createdAt: nil,
                showsActions: false,
                executionTrace: viewModel.executionSteps,
                activityLabel: liveAssistantActivityLabel()
            )
        }
    }

    /// 单条助手回答。复制 / 导出放在正文下方，仅悬停显示；流式中关闭动作条。
    func assistantMessage(
        content: String,
        citations: [RAGCitation],
        createdAt: String?,
        showsActions: Bool,
        executionTrace: [RAGExecutionStep] = [],
        activityLabel: String? = nil
    ) -> some View {
        RAGAssistantMessageBlock(
            content: content,
            citations: citations,
            createdAtLabel: createdAt.map(messageTimeLabel),
            showsActions: showsActions,
            executionTrace: executionTrace,
            activityLabel: activityLabel,
            onSelectCitation: { citation in
                // 底部芯片只定位右侧证据，不打开详情窗。
                viewModel.selectCitation(citation)
            },
            onExport: { viewModel.exportAnswer(content) }
        )
    }

    /// 消息气泡时间戳：只显示短时间，避免挤占中栏。
    func messageTimeLabel(_ iso8601: String) -> String {
        let date = ISO8601DateFormatter.shared.date(from: iso8601)
            ?? ISO8601DateFormatter().date(from: iso8601)
        guard let date else { return "" }
        return date.formatted(Date.FormatStyle(time: .shortened).locale(locale))
    }

    /// 只有尚未创建步骤，或最后一步正在生成正文时才显示独立的加载文案。
    /// 思考、检索等操作本身已经由 assistant 消息内部的轨迹行表达，不能再额外生成第二条消息。
    func liveAssistantActivityLabel() -> String? {
        guard viewModel.isAnswering else { return nil }
        guard let runningStep = viewModel.executionSteps.last(where: { $0.state == .running }) else {
            return stateText(viewModel.answerState)
        }
        return runningStep.kind == .generation ? stateText(viewModel.answerState) : nil
    }

    var remoteConfirmation: some View {
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

    var commandComposer: some View {
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

    func contextChip(title: String, icon: String, onRemove: @escaping () -> Void) -> some View {
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

    func githubLinkChip(_ reference: RAGGitHubLinkReference) -> some View {
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
    var mentionPicker: some View {
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

    var modelMenu: some View {
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
                    .lineLimit(1)
            }
            .ragComposerCapsuleChip(font: ragFont(.caption, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("rag.workspace.composer.model")
    }

    var explicitModeMenu: some View {
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
            HStack(spacing: 6) {
                Image(systemName: "scope")
                Text(repoModeKey(viewModel.explicitRepoMode))
                    .lineLimit(1)
            }
            .ragComposerCapsuleChip(font: ragFont(.caption, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("rag.workspace.composer.scope")
    }

    /// 模型的 providerID 是配置 profile 的 ID，不是 AIServiceProvider 的 rawValue；
    /// 必须经 ViewModel 映射，才能在多个同类服务商 profile 共存时展示正确 logo。
    @ViewBuilder
    func modelPickerLabel(_ model: AIModelDescriptor) -> some View {
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
    var composerNSFont: NSFont {
        NSFont.systemFont(ofSize: 13 * interfaceScale.multiplier)
    }

    var composerMinimumHeight: CGFloat {
        let lineHeight = composerNSFont.ascender - composerNSFont.descender + composerNSFont.leading
        return ceil(lineHeight * 2 + RAGComposerTextEditor.verticalInset * 2)
    }

    var composerMaximumHeight: CGFloat {
        118 * interfaceScale.multiplier
    }

    var composerEditorHeight: CGFloat {
        min(max(composerContentHeight, composerMinimumHeight), composerMaximumHeight)
    }

    func handleComposerCommand(_ command: RAGComposerTextEditor.Command) -> Bool {
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

    func localizedTimestamp(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    /// 右侧「证据」列表：按相关度降序，同分再按仓库名稳定排序。
    var allCitations: [RAGCitation] {
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

    func stateText(_ state: RAGAnswerState) -> String {
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

    func repoModeKey(_ mode: RAGExplicitRepoMode) -> LocalizedStringKey {
        switch mode {
        case .only: return "rag.workspace.repoMode.only"
        case .prefer: return "rag.workspace.repoMode.prefer"
        case .exclude: return "rag.workspace.repoMode.exclude"
        }
    }

    func githubLinkTitle(_ reference: RAGGitHubLinkReference) -> String {
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

    func githubLinkIcon(_ reference: RAGGitHubLinkReference) -> String {
        switch reference.relation {
        case .inKnowledge, .knownButNotInKnowledge: return "shippingbox"
        case .external: return "arrow.up.right.square"
        }
    }

    func githubLinkOpenHint(_ reference: RAGGitHubLinkReference) -> String {
        reference.relation == .knownButNotInKnowledge
            ? String.l10n("rag.workspace.inspector.openStarcat")
            : String.l10n("rag.workspace.inspector.openGitHub")
    }

    func remoteResourceName(_ resource: RAGRemoteContextResource) -> String {
        switch resource {
        case .githubIssues: return "GitHub Issues"
        case .githubPullRequests: return "GitHub Pull Requests"
        case .githubReleases: return "GitHub Releases"
        case .githubContributors: return "GitHub Contributors"
        case .githubCommitActivity: return "GitHub Commit Activity"
        case .githubSecurityAdvisories: return "GitHub Security Advisories"
        }
    }

    func attachmentChipTitle(_ attachment: RAGComposerAttachment) -> String {
        let size = ByteCountFormatter.string(fromByteCount: attachment.sizeInBytes, countStyle: .file)
        return "\(attachment.filename) · \(size)"
    }

    func attachmentIcon(_ attachment: RAGComposerAttachment) -> String {
        switch attachment.handling {
        case .textContext: return "doc"
        case .vision: return "photo"
        case .unsupported: return "exclamationmark.triangle"
        }
    }

}
