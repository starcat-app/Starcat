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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @State private var composerContentHeight: CGFloat = 0
    @State private var mentionCaretAnchor: CGPoint = .zero
    @State private var messageTail = ScrollTailController()
    /// 直接控制中栏 ScrollView 的边缘位置，避免依赖 LazyVStack 内部锚点的实现细节。
    @State private var messageTimelinePosition = ScrollPosition()
    /// 每个流式可视更新都签发新请求，避免已处于 `.bottom` 的位置状态吞掉后续命令。
    @State private var messageTailRequests = ScrollTailRequestSequencer()
    @State private var isMessageNearBottom = true

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
            if viewModel.isConversationLoading {
                conversationLoading
            } else if showsEmptyConversation {
                emptyConversation
            } else {
                messageTimeline
            }
            if !viewModel.pendingRemoteWorkItems.isEmpty {
                Divider()
                remoteConfirmation
            }
            // 空会话已有大空态 CTA；有消息时再挂一条补救横幅，避免提问后无入口。
            if viewModel.isKnowledgeBaseEmpty && !showsEmptyConversation {
                Divider()
                emptyKnowledgeBanner
            }
            Divider()
            commandComposer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 新会话且尚未开始回答时显示空态提示。
    var showsEmptyConversation: Bool {
        viewModel.messages.isEmpty
            && !viewModel.hasStreamingContent
            && !viewModel.isAnswering
    }

    /// 缓存未命中时立即清掉上一会话正文，只显示轻量加载态；数据库读取完成后一次性安装。
    /// 这比保留 A 的内容并把左栏高亮切到 B 更诚实，也不会让加载态参与复杂布局。
    var conversationLoading: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let outlineTurns = viewModel.conversationOutlineTurns
        let hasTimelineContent = !viewModel.messages.isEmpty
            || viewModel.hasStreamingContent
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
                            || viewModel.hasStreamingContent
                            || viewModel.isAnswering {
                            liveAssistantMessage
                                .id("live-assistant-message")
                        }

                        Color.clear
                            .frame(height: 1)
                            .background(
                                RAGWorkspaceBottomScrollBridge(
                                    requestID: messageTailRequests.requestID,
                                    shouldFollow: messageTail.isFollowing
                                        && messageTailRequests.allowsAutomaticScroll,
                                    animatesScroll: messageTailRequests.animatesScroll
                                )
                            )
                            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                                messageTail.updateBottomVisibility(isVisible)
                            }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition($messageTimelinePosition)
                .onScrollPhaseChange { _, newPhase in
                    messageTail.updatePhase(newPhase)
                    // 对话时间线一旦滚动（含惯性/程序贴底），正文 S1 的 NSPopover 锚点就失效；
                    // popover 内部滚动不会改变本 ScrollView 的 phase，不会误关。
                    if newPhase != .idle {
                        viewModel.dismissCitationChunkPopover()
                    }
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
                    forceMessageTailScroll()
                }
                .onChange(of: viewModel.isAnswering) { _, isAnswering in
                    // 先出现查询规划 / 思考等步骤，再出现正文 token；开始生成时先对齐，
                    // 避免首段执行轨迹已把底部推离视口。
                    guard isAnswering else { return }
                    forceMessageTailScrollIfFollowing()
                }
                .onChange(of: viewModel.executionSteps.count) { _, _ in
                    forceMessageTailScrollIfFollowing()
                }
                .onChange(of: viewModel.streamingPresentation?.revision) { _, revision in
                    // `streamingPresentation` 才是实际驱动消息块重绘的快照；每个 revision
                    // 必须重新发出命令，而不是重复设置同一个 `.bottom` 位置值。
                    guard revision != nil else { return }
                    forceMessageTailScrollIfFollowing()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    // 完整消息只会在发送问题或回答落库时增加，频率远低于 token 快照。
                    // 这里必须立即定位，补偿 5Hz 合并窗口内可能被丢弃的最后一次自动请求。
                    // 但折叠动画仍优先保持视口稳定；用户点击与历史加载不走此自动门禁。
                    guard messageTail.isFollowing,
                          messageTailRequests.allowsAutomaticScroll else { return }
                    forceMessageTailScroll()
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
                        forceMessageTailScroll(animated: true)
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

    /// 直接定位滚动容器的尾部。
    ///
    /// 历史实现依赖 `LazyVStack` 内的 item id，并曾跨 `Task.yield()` 保存 proxy；两者
    /// 都可能在 SwiftUI 更新期间失效。`ScrollPosition` 直接驱动当前 ScrollView 的 edge，
    /// 不依赖惰性子项是否已布局；递增请求再交给底部原生 bridge，在合并后的流式更新
    /// 提交布局后重新贴住底部。流式快照只更新原生请求编号，完整定位保留给
    /// 历史安装、完整消息落库和用户点击。
    func forceMessageTailScroll(animated: Bool = false) {
        // 流式快照约 10Hz 提交；尾部跟随若每次都带动画，会形成彼此追逐的动画事务。
        // 只有用户点击快捷入口时才允许动画；打开历史会话和自动跟随始终即时完成。
        let animatesScroll = animated && !reduceMotion
        messageTailRequests.issue(animatesScroll: animatesScroll)
        var transaction = Transaction()
        transaction.disablesAnimations = !animatesScroll
        withTransaction(transaction) {
            messageTimelinePosition.scrollTo(edge: .bottom)
        }
    }

    /// 流式更新只在用户仍在尾部时请求；手动上滚后不抢走阅读位置。
    func forceMessageTailScrollIfFollowing() {
        guard messageTail.isFollowing else { return }
        // 自动跟随仅签发合并后的原生请求。`ScrollPosition` 的完整定位保留给历史加载
        // 和用户点击，避免每个 Markdown revision 同时驱动两套滚动系统。
        _ = messageTailRequests.issueAutomatic(now: Date.timeIntervalSinceReferenceDate)
    }

    /// 折叠动画期间同时阻止新自动请求，并让 bridge 取消尚未执行的旧请求。
    /// 动画结束只恢复“可自动跟随”资格，不主动滚到底；下一次稳定流式更新再按原策略追尾。
    func handleExecutionDisclosureAnimationActivityChanged(_ isActive: Bool) {
        if isActive {
            messageTailRequests.beginAutomaticSuppression()
        } else {
            messageTailRequests.endAutomaticSuppression()
        }
    }

    /// 新会话空态：放大图标/文案，并在中栏剩余区域上下左右居中。
    /// 知识库为空时换成入库引导，避免用户对着「向知识库提问」却无处可问。
    var emptyConversation: some View {
        Group {
            if viewModel.isKnowledgeBaseEmpty {
                EmptyStateView(
                    systemImage: "books.vertical",
                    title: "rag.workspace.empty.noKnowledge.title",
                    subtitle: "rag.workspace.empty.noKnowledge.subtitle",
                    iconSize: interfaceScale.scaled(52),
                    spacing: 14,
                    subtitleHorizontalPadding: 48,
                    titleFont: interfaceScale.font(.workspaceTitle, weight: .semibold),
                    subtitleFont: ragFont(.callout)
                ) {
                    Button {
                        viewModel.presentAddToLibrary()
                    } label: {
                        Label("rag.workspace.addToLibrary.cta", systemImage: "heart.fill")
                            .font(ragFont(.caption, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                    .help("rag.workspace.addToLibrary.openHelp")
                }
            } else {
                if colorScheme == .light {
                    decoratedEmptyConversation
                } else {
                    // 示意图是浅色视觉稿，深色模式继续用系统语义色空态，避免白底位图破坏窗口层级。
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
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 浅色新会话空态只表达中栏将发生的问答与引用，不重复现有窗口的三栏结构。
    /// 资源图自带的中文标题会在这里被裁出，实际文案仍由 xcstrings 绘制，确保英文界面可本地化。
    private var decoratedEmptyConversation: some View {
        VStack(spacing: interfaceScale.scaled(14)) {
            Image("RAGEmptyConversationArtwork")
                .resizable()
                .scaledToFill()
                // 原图底部是中文视觉稿文案；只取上半部对话示意，避免和本地化文本重复。
                .frame(
                    width: interfaceScale.scaled(520),
                    height: interfaceScale.scaled(282),
                    alignment: .top
                )
                .clipped()
                .accessibilityHidden(true)

            Text("rag.workspace.empty.title")
                .font(interfaceScale.font(.workspaceTitle, weight: .semibold))
                .foregroundStyle(.primary)

            Text("rag.workspace.empty.subtitle")
                .font(ragFont(.callout))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: interfaceScale.scaled(520))
        }
    }

    /// 会话已有内容但知识库仍为空（例如提问后落到 noKnowledgeRepos）时，在 Composer 上方给补救入口。
    var emptyKnowledgeBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "books.vertical")
                .font(iconFont(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("rag.workspace.empty.noKnowledge.banner")
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                viewModel.presentAddToLibrary()
            } label: {
                Text("rag.workspace.addToLibrary.cta")
                    .font(ragFont(.caption, weight: .semibold))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(Color.accentColor)
            .help("rag.workspace.addToLibrary.openHelp")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.08))
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
                executionTrace: message.executionTrace,
                suggestedActions: message.suggestedActions,
                processingDuration: message.processingDuration
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
                activityLabel: liveAssistantActivityLabel(),
                processingDuration: viewModel.answerElapsedDuration,
                onExecutionDisclosureAnimationActivityChanged: handleExecutionDisclosureAnimationActivityChanged
            )
        } else {
            assistantMessage(
                content: viewModel.streamingAnswer,
                citations: [],
                createdAt: nil,
                showsActions: false,
                executionTrace: viewModel.executionSteps,
                activityLabel: liveAssistantActivityLabel(),
                processingDuration: viewModel.answerElapsedDuration
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
        suggestedActions: [RAGSuggestedQuestionAction] = [],
        activityLabel: String? = nil,
        processingDuration: TimeInterval? = nil
    ) -> some View {
        RAGAssistantMessageBlock(
            content: content,
            citations: citations,
            createdAtLabel: createdAt.map(messageTimeLabel),
            showsActions: showsActions,
            executionTrace: executionTrace,
            activityLabel: activityLabel,
            processingDuration: processingDuration,
            suggestedActions: suggestedActions,
            onSelectCitation: { citation in
                // 底部芯片：只定位右侧证据，不弹分片（与改前一致）。
                viewModel.selectCitation(citation)
            },
            onSuggestedAction: { action in viewModel.sendSuggestedQuestion(action) },
            onExport: { viewModel.exportAnswer(content) },
            onExecutionDisclosureAnimationActivityChanged: handleExecutionDisclosureAnimationActivityChanged
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
                    .disabled(viewModel.approvedRemoteWorkItemIDs.isEmpty)
            }
            RAGFlowLayout(spacing: 7) {
                ForEach(viewModel.pendingRemoteWorkItems) { workItem in
                    let enabled = viewModel.approvedRemoteWorkItemIDs.contains(workItem.id)
                    Button {
                        viewModel.toggleRemoteWorkItem(workItem.id)
                    } label: {
                        Label(
                            "\(workItem.candidate.repo.fullName) · \(remoteResourceName(workItem.request.resource))",
                            systemImage: enabled ? "checkmark.circle.fill" : "circle"
                        )
                            .font(ragFont(.caption, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(enabled ? .orange : .gray)
                    .help(workItem.request.reason)
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
                            repoContextChip(repo)
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
                    // Prompt 预算快照：放在底栏最左侧的纯进度环，作为最克制的附属指示器，
                    // 不与右侧的动作按钮（附件 / 联网 / 发送）争视觉权重。
                    RAGContextUsageButton(usage: viewModel.composerContextUsage)

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

                    // Globe 是普通互联网搜索的显式授权。蓝色表示后续问题可访问设置页中
                    // 已启用的 External Search Provider；发送中禁用，避免误解为能改变当前请求。
                    Button {
                        viewModel.webSearchEnabled.toggle()
                    } label: {
                        Image(systemName: "globe")
                            .font(iconFont(size: 13, weight: .medium))
                            .foregroundStyle(viewModel.webSearchEnabled ? Color.accentColor : .secondary)
                            .frame(width: 24, height: 24)
                            .background(
                                viewModel.webSearchEnabled ? Color.accentColor.opacity(0.14) : Color.clear,
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .disabled(viewModel.isAnswering)
                    .help(viewModel.webSearchEnabled
                          ? "rag.workspace.composer.webSearch.on"
                          : "rag.workspace.composer.webSearch.off")

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

    /// 附件等非仓库 chip：左侧 SF Symbol + 文案 + 移除。
    func contextChip(title: String, icon: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(iconFont(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(iconFont(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.remove")
        }
        .font(ragFont(.caption, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .ragContextChipCapsule()
    }

    /// @仓库 chip：左侧项目 logo（RemoteAvatar，14pt 对齐 caption），不用通用 shippingbox。
    /// 关键约束：logo 直径锁死 14，禁止跟随文字字号放大，胶囊高度仍由 caption + 上下 6pt padding 决定。
    func repoContextChip(_ repo: Repo) -> some View {
        HStack(spacing: 6) {
            RemoteAvatar(
                urlString: repo.ownerAvatar ?? RepoAvatarURL.from(owner: repo.owner),
                size: 14,
                showBorder: false
            )
            Text("@\(repo.fullName)")
                .lineLimit(1)
            Button {
                viewModel.removeMention(repoID: repo.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(iconFont(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.remove")
        }
        .font(ragFont(.caption, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .ragContextChipCapsule()
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
                    .font(iconFont(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.remove")
        }
        .font(ragFont(.caption, weight: .semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .ragContextChipCapsule()
    }

    /// `@` 多选弹层：顶部统计 + 当前筛选词 + 已选置顶列表；筛选源仍是输入框 `@token`。
    var mentionPicker: some View {
        let snapshot = viewModel.mentionPickerSnapshot
        let filterText = viewModel.mentionQuery ?? ""

        return VStack(alignment: .leading, spacing: 0) {
            mentionPickerHeader(snapshot: snapshot)
            Divider()
            mentionPickerFilterRow(filterText: filterText)
            Divider()

            if snapshot.suggestions.isEmpty {
                mentionPickerEmptyState(hasKnowledge: snapshot.knowledgeCount > 0, hasFilter: !filterText.isEmpty)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(snapshot.suggestions.enumerated()), id: \.element.id) { index, repo in
                            mentionPickerRow(repo, rowIndex: index)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            if snapshot.isTruncated {
                Divider()
                Text(
                    String(
                        format: String.l10n("rag.workspace.mention.narrowHint"),
                        locale: locale,
                        snapshot.displayedCount,
                        snapshot.matchCount
                    )
                )
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
        .frame(width: 320)
        .padding(.vertical, 4)
        .appLocaleEnvironment()
    }

    func mentionPickerHeader(snapshot: RAGMentionPickerSnapshot) -> some View {
        HStack(spacing: 8) {
            Text(
                String(
                    format: String.l10n("rag.workspace.mention.stats"),
                    locale: locale,
                    snapshot.selectedCount,
                    snapshot.knowledgeCount
                )
            )
            .font(ragFont(.caption, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                viewModel.selectAllVisibleMentions()
            } label: {
                Text("rag.workspace.mention.selectVisible")
                    .font(ragFont(.caption, weight: .semibold))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(Color.accentColor)
            .disabled(snapshot.suggestions.isEmpty)
            .help("rag.workspace.mention.selectVisible")

            Button {
                viewModel.clearSelectedMentions()
            } label: {
                Text("rag.workspace.mention.clearSelected")
                    .font(ragFont(.caption, weight: .semibold))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .foregroundStyle(.secondary)
            .disabled(snapshot.selectedCount == 0)
            .help("rag.workspace.mention.clearSelected")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    func mentionPickerFilterRow(filterText: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(ragFont(.caption))
                .foregroundStyle(.secondary)
            if filterText.isEmpty {
                Text("rag.workspace.mention.filterHint")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(
                    String(
                        format: String.l10n("rag.workspace.mention.filterLabel"),
                        locale: locale,
                        filterText
                    )
                )
                .font(ragFont(.caption))
                .foregroundStyle(.primary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !filterText.isEmpty {
                Button {
                    viewModel.clearMentionFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("rag.workspace.mention.clearFilter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    func mentionPickerEmptyState(hasKnowledge: Bool, hasFilter: Bool) -> some View {
        let key: LocalizedStringKey = {
            if !hasKnowledge {
                return "rag.workspace.mention.emptyKnowledge"
            }
            if hasFilter {
                return "rag.workspace.mention.emptyFilter"
            }
            return "rag.workspace.mention.emptyKnowledge"
        }()
        return VStack(alignment: .leading, spacing: 10) {
            Text(key)
                .font(ragFont(.callout))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !hasKnowledge {
                Button {
                    viewModel.dismissMentionPicker()
                    viewModel.presentAddToLibrary()
                } label: {
                    Text("rag.workspace.addToLibrary.cta")
                        .font(ragFont(.caption, weight: .semibold))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(Color.accentColor)
                .help("rag.workspace.addToLibrary.openHelp")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
    }

    func mentionPickerRow(_ repo: Repo, rowIndex: Int) -> some View {
        let isHighlighted = repo.id == viewModel.highlightedMentionRepoIDValue
        return Button { viewModel.toggleMention(repo) } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(viewModel.isMentionSelected(repo) ? 1 : 0)
                    .frame(width: 12, alignment: .center)
                RemoteAvatar(
                    urlString: repo.ownerAvatar ?? RepoAvatarURL.from(owner: repo.owner),
                    size: 18,
                    showBorder: false
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(repo.fullName)
                        .font(ragFont(.callout))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let language = repo.language?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !language.isEmpty {
                            LanguageBadge(language: language, style: .compact)
                        }
                        StarsBadge(count: repo.starsCount, style: .compact)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isHighlighted
                    ? Color.accentColor.opacity(0.12)
                    : mentionZebraBackground(rowIndex: rowIndex)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(repo.fullName)
    }

    /// 与知识库浏览器分片列表同一套斑马纹：奇数行极淡 primary，不抢高亮色。
    func mentionZebraBackground(rowIndex: Int) -> Color {
        rowIndex.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.045)
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
        case .externalWeb: return "Web Search"
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
