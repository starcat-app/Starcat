//
//  RAGWorkspaceAnswerSurface.swift
//  Starcat
//
//  知识库 RAG 工作台的回答时间线、远程确认与输入 Composer。
//

import AppKit
import SwiftUI

/// RAG 中栏所有程序化滚动共用同一类 identity，避免消息、大纲与底部入口使用不兼容的 ID。
private enum RAGMessageScrollTarget: Hashable, Sendable {
    case message(UUID)
    case liveAssistant
    case bottom
}

struct RAGWorkspaceAnswerSurface: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @Environment(\.ragSettingsNavigation) private var settingsNavigation
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession

    @Bindable var viewModel: KnowledgeRAGWorkspaceViewModel
    @State private var composerContentHeight: CGFloat = 0
    @FocusState private var isContextPickerSearchFocused: Bool
    @State private var messageTail = ScrollTailController()
    @State private var historyWindow = RAGConversationHistoryWindow()
    @State private var isMessageNearBottom = true
    @State private var isComposerContextExpanded = false
    @State private var isConversationSkeletonHandoffVisible = false
    @State private var deepThinkingToastMessage: String?

    private static let messageNearBottomThreshold: CGFloat = 64
    private static let conversationSkeletonFadeDuration: TimeInterval = 0.16

    private func ragFont(_ role: RAGFontRole, weight: Font.Weight? = nil, design: Font.Design = .default) -> Font {
        interfaceScale.font(role.typography, weight: weight, design: design)
    }

    private func iconFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        interfaceScale.font(size: size, weight: weight)
    }

    /// 上下文选择面板固定高度；与定位偏移共用同一常量，避免盖住 Composer。
    private static let contextPickerPanelHeight: CGFloat = 480
    private static let contextPickerPanelGap: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            answerHeader
            Divider()
            // 面板放在「消息区」ZStack 底边，Composer 是下方独立兄弟视图。
            // 这样面板永远停在 chip/输入框之上，既不参与 Composer 布局，也不可能盖住它。
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    conversationContent
                    if !viewModel.pendingRemoteWorkItems.isEmpty {
                        Divider()
                        remoteConfirmation
                    }
                    // 空会话已有大空态 CTA；有消息时再挂一条补救横幅，避免提问后无入口。
                    if viewModel.isKnowledgeBaseEmpty && !showsEmptyConversation {
                        Divider()
                        emptyKnowledgeBanner
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.isContextPickerPresented {
                    contextPickerPanel
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.bottom, Self.contextPickerPanelGap)
                        .zIndex(1)
                }
            }
            .toast(
                message: $deepThinkingToastMessage,
                icon: "info.circle.fill",
                duration: 3.0,
                iconColor: Color.secondary
            )
            Divider()
            commandComposer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 新会话且尚未开始回答时显示空态提示。
    var showsEmptyConversation: Bool {
        viewModel.messages.isEmpty
            && !viewModel.isAnswering
            && viewModel.streamingAnswer.isEmpty
    }

    /// 会话正文与骨架采用两阶段交接：正文先在不透明骨架下完成首次布局，再淡出骨架。
    /// 如果直接用 `if/else` 替换，Markdown 首次解析会占用主线程并冻住 shimmer，随后才硬切到正文。
    var conversationContent: some View {
        let isLoading = viewModel.isConversationLoading
        return ZStack {
            // 加载期间不保留上一会话，避免左栏已经选中 B、中栏却仍显示 A 的误导状态。
            // 安装完成后先挂载正文；此时 handoff 骨架仍在最上层，遮住首轮解析和布局。
            if !isLoading {
                // 空态放在 ScrollView 外，才能占满中栏剩余高度并真正上下居中。
                if showsEmptyConversation {
                    emptyConversation
                } else {
                    messageTimeline
                }
            }

            if isLoading || isConversationSkeletonHandoffVisible {
                conversationLoading
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // `task(id:)` 会在加载状态再次变化或 View 消失时自动取消旧任务，连续切换会话时
        // 上一会话的延迟淡出因此不能误删当前会话的骨架。
        .task(id: isLoading) {
            await updateConversationSkeletonHandoff(isLoading: isLoading)
        }
    }

    /// 正文完成首次挂载后再淡出骨架。shimmer 已由 Core Animation 驱动，因此 Markdown
    /// 首帧布局期间不会停住；Reduce Motion 下仍保留两阶段挂载，但不播放淡出。
    @MainActor
    private func updateConversationSkeletonHandoff(isLoading: Bool) async {
        if isLoading {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isConversationSkeletonHandoffVisible = true
            }
            return
        }

        guard isConversationSkeletonHandoffVisible else { return }
        await Task.yield()
        guard !Task.isCancelled, !viewModel.isConversationLoading else { return }

        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isConversationSkeletonHandoffVisible = false
            }
        } else {
            withAnimation(.easeOut(duration: Self.conversationSkeletonFadeDuration)) {
                isConversationSkeletonHandoffVisible = false
            }
        }
    }

    /// 缓存未命中时立即清掉上一会话正文，用对话骨架占位；数据库读取完成后一次性安装。
    /// 这比保留 A 的内容并把左栏高亮切到 B 更诚实，也不会让加载态参与复杂布局。
    var conversationLoading: some View {
        RAGConversationSkeletonView()
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
            // 会话标题右侧：创建时间 / 复制 / 导出全部对话（右对齐）。
            if !viewModel.messages.isEmpty {
                // 创建时间精确到分，放在复制按钮左侧；解析失败时静默省略，不阻塞 header。
                if let createdAt = viewModel.conversations
                    .first(where: { $0.id == viewModel.selectedConversationID })?.createdAt,
                   let createdDate = ISO8601DateFormatter.shared.date(from: createdAt) {
                    Text(localizedTimestamp(createdDate))
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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
        let conversationID = viewModel.selectedConversationID
        let outlineTurns = viewModel.conversationOutlineTurns
        let historyPresentation = historyWindow.visiblePresentation(
            conversationID: conversationID,
            messages: viewModel.messages
        )
        let visibleMessages = historyPresentation.messages
        let hasEarlierMessages = historyPresentation.hasEarlierMessages
        let hasTimelineContent = !viewModel.messages.isEmpty
            || viewModel.isAnswering
            || !viewModel.streamingAnswer.isEmpty
        // 显隐只看几何「是否离底」：不要读 messageTail.isFollowing，否则滚动 phase
        // 每次变化都会整页刷新，鼠标划过按钮时更容易闪没并卡顿。
        let showsScrollToBottom = hasTimelineContent && !isMessageNearBottom
        return ScrollViewReader { proxy in
            ZStack(alignment: .leading) {
                ScrollView {
                    // 继续使用准确高度的 VStack，避免 LazyVStack 的估算高度校正；但历史
                    // 会话只把当前窗口内的轮次交给 SwiftUI，长会话不再一次布局全部 Markdown。
                    VStack(alignment: .leading, spacing: 18) {
                        if hasEarlierMessages {
                            RAGLoadEarlierHistoryButton {
                                loadEarlierHistory(using: proxy)
                            }
                        }

                        ForEach(visibleMessages) { message in
                            messageView(message)
                                .id(RAGMessageScrollTarget.message(message.id))
                        }
                        // 高频 snapshot/Think 读取必须停在独立子 View；父时间线不订阅
                        // revision，正文每次发布时不会重算全部历史消息和输入区。
                        RAGLiveAssistantPresentationView(viewModel: viewModel)
                            .id(RAGMessageScrollTarget.liveAssistant)

                        // 永久 sentinel 是所有“到底”动作的唯一目标。它不会随流式块完成、
                        // 折叠或落库而更换 identity，ScrollViewReader 因此不会命中旧节点。
                        Color.clear
                            .frame(height: 1)
                            .id(RAGMessageScrollTarget.bottom)
                            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                                messageTail.updateBottomVisibility(isVisible)
                            }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // 内容增长与 Think 折叠都交给 ScrollView 的尺寸变化锚点校正 offset。
                // 用户离开底部时传 nil，后续流式布局不会抢回滚动控制权。
                .defaultScrollAnchor(
                    messageTail.isFollowing ? .bottom : nil,
                    for: .sizeChanges
                )
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
                .onChange(of: viewModel.selectedConversationID) { _, selectedConversationID in
                    // 先立即清掉上一会话的窗口身份；缓存未命中时，历史安装序列会在
                    // SQLite 返回后用真实消息再次 reset。
                    historyWindow.reset(
                        conversationID: selectedConversationID,
                        messages: viewModel.messages
                    )
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    historyWindow.reconcileCurrentConversation(
                        conversationID: viewModel.selectedConversationID,
                        messages: viewModel.messages
                    )
                }
                .onChange(of: viewModel.conversationHistoryInstallSequence) { _, _ in
                    // 点开历史会话固定回到最新 2 轮；回答落库不会触发这个序列。
                    historyWindow.reset(
                        conversationID: viewModel.selectedConversationID,
                        messages: viewModel.messages
                    )
                }
                .onChange(of: viewModel.loadedMessageSequence) { _, _ in
                    // ViewModel 已经安装完历史 messages；下一次主线程调度时布局才完整。
                    messageTail.resumeFollowing()
                    scheduleMessageTailScroll(using: proxy)
                }

                // 左侧大纲轨叠在时间线之上，但宽度仅覆盖横线/预览卡，不挡住正文点击。
                if !outlineTurns.isEmpty {
                    RAGConversationOutlineRail(
                        turns: outlineTurns,
                        onSelect: { turn in
                            messageTail.pauseFollowing()
                            isMessageNearBottom = false
                            revealAndScrollMessageIntoView(turn.userMessageID, using: proxy)
                        },
                        timeLabel: outlineTimeLabel
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
                        // 手动入口仍要等待本轮布局提交后再定位永久 sentinel。
                        scheduleMessageTailScroll(using: proxy, animated: true)
                    }
                    .padding(.bottom, 16)
                }
            }
        }
    }

    /// 手动向前扩 10 轮。扩窗前先暂停尾随，随后把原首条消息放回顶部，新增内容只出现在
    /// 它上方，不会因为 `VStack` 高度突然增加而把用户当前阅读位置向下推走。
    func loadEarlierHistory(using proxy: ScrollViewProxy) {
        messageTail.pauseFollowing()
        isMessageNearBottom = false
        guard let previousFirstMessageID = historyWindow.loadEarlier(
            conversationID: viewModel.selectedConversationID,
            messages: viewModel.messages
        ) else { return }

        Task { @MainActor in
            await Task.yield()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(
                    RAGMessageScrollTarget.message(previousFirstMessageID),
                    anchor: .top
                )
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

    /// 下一次主线程调度时，通过当前 ScrollViewReader 定位永久 bottom sentinel。
    ///
    /// 这里只处理按钮和历史安装等低频动作；流式尺寸变化由 `sizeChanges` anchor 负责。
    /// 同步 scrollTo 仍可能读取旧 contentSize，因此先 `Task.yield()`；调度标记放在
    /// `ScrollTailController` 的 ObservationIgnored 字段中，不再触发回答面重算。
    func scheduleMessageTailScroll(using proxy: ScrollViewProxy, animated: Bool = false) {
        guard messageTail.beginScrollRequest(animated: animated) else { return }

        Task { @MainActor in
            await Task.yield()
            defer { messageTail.finishScrollRequest() }
            guard messageTail.isFollowing else { return }

            if messageTail.scheduledScrollRequestShouldAnimate(), !reduceMotion {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(RAGMessageScrollTarget.bottom, anchor: .bottom)
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(RAGMessageScrollTarget.bottom, anchor: .bottom)
                }
            }
        }
    }

    /// 大纲可指向窗口外的旧轮次。先扩窗再等待布局提交，避免 reader 对尚不存在的 ID
    /// 静默无效；已在窗口内的目标仍可同步定位。
    func revealAndScrollMessageIntoView(_ messageID: UUID, using proxy: ScrollViewProxy) {
        let didExpand = historyWindow.revealMessage(
            messageID,
            conversationID: viewModel.selectedConversationID,
            messages: viewModel.messages
        )
        let scroll = {
            let target = RAGMessageScrollTarget.message(messageID)
            if reduceMotion {
                proxy.scrollTo(target, anchor: .top)
            } else {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .top)
                }
            }
        }

        guard didExpand else {
            scroll()
            return
        }
        Task { @MainActor in
            await Task.yield()
            scroll()
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
                decoratedEmptyConversation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 3D 透明插画表达知识检索、问答与引用，明暗主题共用同一份素材。
    /// 图片不含文字，标题与说明仍由 xcstrings 绘制，避免固定语言和裁切文案的旧路径。
    private var decoratedEmptyConversation: some View {
        VStack(spacing: interfaceScale.scaled(14)) {
            Image(decorative: "RAGEmptyConversationArtwork")
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                // 完整保留书本和引用标签；窄中栏按可用宽度缩小，不再裁取图片上半部。
                .frame(maxWidth: interfaceScale.scaled(520))
                .frame(height: interfaceScale.scaled(282))

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
            processingStartedAt: nil,
            suggestedActions: suggestedActions,
            onSelectCitation: { citation in
                // 底部芯片：只定位右侧证据，不弹分片（与改前一致）。
                viewModel.selectCitation(citation)
            },
            onSuggestedAction: { action in viewModel.sendSuggestedQuestion(action) },
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

    /// 快速跳转卡片需要精确到日期；沿用系统 Locale，避免硬编码中英文年月日顺序。
    func outlineTimeLabel(_ iso8601: String) -> String {
        let date = ISO8601DateFormatter.shared.date(from: iso8601)
            ?? ISO8601DateFormatter().date(from: iso8601)
        guard let date else { return "" }
        return localizedTimestamp(date)
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
            // 上下文放在输入框外（对齐 Agent）。单行直接展示；超过一行时默认收进
            // 折叠面板，避免大量仓库和附件持续挤占消息阅读区。
            if hasContextChips {
                composerContextSection
                    .padding(.horizontal, 16)
            }

            if viewModel.embeddingConfigurationIssue != nil {
                keywordOnlyModeNotice
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            if let reason = viewModel.composerBlockingReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(ragFont(.caption))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
            }

            // 输入主体：文本区 + 底栏；与上方 chip 分离。
            AICommandComposerView {
                AICommandTextEditor(
                    text: $viewModel.draftQuestion,
                    placeholder: String.l10n(
                        settings.aiChatRequiresCommandReturn
                            ? "rag.workspace.composer.placeholder.commandSend"
                            : "rag.workspace.composer.placeholder.returnSend"
                    ),
                    font: composerNSFont,
                    maximumHeight: composerMaximumHeight,
                    onHeightChange: { composerContentHeight = $0 },
                    // 仍回传 @ 的位置供编辑器内部保持布局计算；上下文面板不再依赖它定位。
                    onMentionAnchorChange: { _ in },
                    onCommand: handleComposerCommand
                )
                // AppKit scroll view 在弹性 VStack 中会忽略子视图的最大高度；由外层显式
                // 约束，首帧严格保持两行，文本变多时再增长到既有上限。
                .frame(height: composerEditorHeight)
                .onChange(of: viewModel.draftQuestion) { _, _ in
                    viewModel.handleDraftQuestionChanged()
                }

                HStack(alignment: .center, spacing: 8) {
                    // 添加上下文是 Composer 的首要入口，固定放在左下角；不能挤进右侧
                    // 附件 / 联网 / 发送的执行操作组。
                    Button { viewModel.presentContextPicker() } label: {
                        Image(systemName: "plus")
                            .font(iconFont(size: 14, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .foregroundStyle(.secondary)
                    .help("rag.workspace.mention.title")

                    // Prompt 预算快照：放在底栏最左侧的纯进度环，作为最克制的附属指示器，
                    // 不与右侧的动作按钮（附件 / 联网 / 发送）争视觉权重。
                    RAGContextUsageButton(usage: viewModel.composerContextUsage)

                    RAGWorkspaceModelMenu(viewModel: viewModel)

                    if !viewModel.selectedRepoContexts.isEmpty {
                        RAGWorkspaceRepoModeMenu(viewModel: viewModel)
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

                    // 深度思考严格位于联网之后、发送之前。它只读取唯一显式项目的
                    // RepoContext；附件数量不参与门禁，避免把材料数量误当成项目范围。
                    Button {
                        guard viewModel.canEnableDeepThinking else {
                            deepThinkingToastMessage = "rag.workspace.composer.deepThinking.singleRepoRequired"
                            return
                        }
                        viewModel.deepThinkingEnabled.toggle()
                    } label: {
                        Image(systemName: "brain.head.profile")
                            .font(iconFont(size: 13, weight: .medium))
                            .foregroundStyle(viewModel.deepThinkingEnabled ? Color.accentColor : .secondary)
                            .frame(width: 24, height: 24)
                            .background(
                                viewModel.deepThinkingEnabled ? Color.accentColor.opacity(0.14) : Color.clear,
                                in: Circle()
                            )
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    // 范围不满足时只保留置灰视觉，不能使用 `.disabled` 拦截点击，
                    // 否则首次使用者无法通过 Toast 理解“仅支持单仓库”的约束。
                    .opacity(viewModel.canEnableDeepThinking ? 1 : 0.45)
                    .disabled(viewModel.isAnswering)
                    .help(!viewModel.canEnableDeepThinking
                          ? "rag.workspace.composer.deepThinking.singleRepoRequired"
                          : (viewModel.deepThinkingEnabled
                             ? "rag.workspace.composer.deepThinking.on"
                             : "rag.workspace.composer.deepThinking.off"))
                    .accessibilityLabel(Text(!viewModel.canEnableDeepThinking
                                             ? "rag.workspace.composer.deepThinking.singleRepoRequired"
                                             : (viewModel.deepThinkingEnabled
                                                ? "rag.workspace.composer.deepThinking.on"
                                                : "rag.workspace.composer.deepThinking.off")))

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
                        let canSend = composerCanSend
                        Button { submitComposerQuestion() } label: {
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
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: viewModel.embeddingConfigurationIssue != nil
        )
        .onChange(of: composerContextItemCount) { _, itemCount in
            // 清空上下文后恢复默认折叠态；下次重新选择大量仓库时不会继承旧展开状态。
            if itemCount == 0 {
                isComposerContextExpanded = false
            }
        }
    }

    /// 未配置可用 Embedding 时只提示当前为关键词模式，不阻塞提问。
    ///
    /// 关键词 FTS、元数据、笔记及仓库特殊 XML 上下文仍可正常参与回答；这里保留配置入口，
    /// 让用户按需开启语义召回，而不是把向量模型误做成 RAG 的硬前置条件。
    var keywordOnlyModeNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(iconFont(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)

            Text("rag.browser.status.keywordOnly")
                .font(ragFont(.caption, weight: .semibold))
                .foregroundStyle(.primary)

            if let issue = viewModel.embeddingConfigurationIssue {
                Text(issue.localizedDescription)
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("rag.workspace.index.embeddingModel.configure") {
                settingsNavigation("ai.embedding")
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .font(ragFont(.caption, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .help("rag.workspace.index.embeddingModel.configure")
        }
        .padding(.horizontal, 16)
    }

    /// 单行 chip 的可用高度上限。留出少量字体缩放余量，但仍显著小于两行 chip
    /// （两行至少包含 2×chip 高度 + 7pt 行距），供 `ViewThatFits` 准确判断折行。
    var composerContextCollapsedHeight: CGFloat {
        interfaceScale.scaled(32)
    }

    var composerContextItemCount: Int {
        viewModel.selectedRepoContexts.count
            + viewModel.attachments.count
            + viewModel.githubLinkContexts.count
    }

    /// 上下文展示区：折叠态用 `ViewThatFits` 先尝试完整 FlowLayout。
    /// 能在一行高度内放下就原样显示；放不下才退化为整行可点击的折叠标题。
    var composerContextSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isComposerContextExpanded {
                HStack(alignment: .center, spacing: 8) {
                    composerContextDisclosureButton(isExpanded: true)
                    clearComposerContextButton
                }
                composerContextFlow
            } else {
                HStack(alignment: .center, spacing: 8) {
                    ViewThatFits(in: .vertical) {
                        composerContextFlow
                            .fixedSize(horizontal: false, vertical: true)
                        composerContextDisclosureButton(isExpanded: false)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: composerContextCollapsedHeight,
                        maxHeight: composerContextCollapsedHeight,
                        alignment: .topLeading
                    )

                    clearComposerContextButton
                }
            }
        }
    }

    var composerContextFlow: some View {
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
    }

    /// 折叠标题遵守“整行点击”规范；chevron 只表达状态，清空操作留在外层独立按钮。
    func composerContextDisclosureButton(isExpanded: Bool) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isComposerContextExpanded.toggle()
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(iconFont(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("rag.workspace.composer.contextDisclosure")
                    .font(ragFont(.caption, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                composerContextCount(systemImage: "shippingbox", count: viewModel.selectedRepoContexts.count)
                composerContextCount(systemImage: "paperclip", count: viewModel.attachments.count)
                composerContextCount(systemImage: "link", count: viewModel.githubLinkContexts.count)
            }
            .frame(maxWidth: .infinity, minHeight: composerContextCollapsedHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    @ViewBuilder
    func composerContextCount(systemImage: String, count: Int) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                Text(count.formatted())
                    .monospacedDigit()
            }
            .font(ragFont(.caption))
            .foregroundStyle(.secondary)
        }
    }

    var clearComposerContextButton: some View {
        Button {
            isComposerContextExpanded = false
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

    var composerCanSend: Bool {
        !viewModel.isAnswering
            && !viewModel.draftQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.composerBlockingReason == nil
    }

    /// 按钮、Return 与 ⌘Return 共用同一发送入口；只有真实发送才收起上下文相关面板。
    /// 已选仓库保存在 ViewModel 中，关闭项目列表只移除浮层，不会丢失本轮 RAG 上下文。
    func submitComposerQuestion() {
        guard composerCanSend else { return }
        if isComposerContextExpanded {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                isComposerContextExpanded = false
            }
        }
        viewModel.dismissMentionPicker()
        viewModel.send()
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

    /// 全宽悬浮上下文选择面板：停在消息区底边、Composer 上方，已选仓库始终置顶。
    var contextPickerPanel: some View {
        let snapshot = viewModel.mentionPickerSnapshot

        return VStack(alignment: .leading, spacing: 0) {
            contextPickerHeader(snapshot: snapshot)
            Divider()
            HStack(spacing: 8) {
                RAGContextPickerFilterControls(viewModel: viewModel)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(ragFont(.caption))
                        .foregroundStyle(.secondary)
                    TextField("rag.workspace.mention.searchPlaceholder", text: $viewModel.contextPickerQuery)
                        .textFieldStyle(.plain)
                        .font(ragFont(.callout))
                        .focused($isContextPickerSearchFocused)
                        .onChange(of: viewModel.contextPickerQuery) { _, _ in
                            viewModel.handleContextPickerQueryChanged()
                        }
                        .onSubmit {
                            viewModel.selectHighlightedMention()
                        }
                        .onExitCommand {
                            viewModel.handleContextPickerEscape()
                        }
                    if !viewModel.contextPickerQuery.isEmpty {
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
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)

            // 无结果时仍占满列表区全宽全高，只在顶部给提示；避免空态 ideal size 把整块面板挤窄居中。
            if snapshot.suggestions.isEmpty {
                mentionPickerEmptyState(
                    hasKnowledge: snapshot.knowledgeCount > 0,
                    hasFilter: !viewModel.contextPickerQuery.isEmpty || viewModel.mentionFilters.isActive
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(snapshot.suggestions) { repo in
                            mentionPickerRow(repo)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.16), radius: 12, y: 5)
        .frame(height: Self.contextPickerPanelHeight)
        .onAppear { isContextPickerSearchFocused = true }
        .onChange(of: viewModel.isContextPickerPresented) { _, presented in
            if presented { isContextPickerSearchFocused = true }
        }
        .appLocaleEnvironment()
    }

    func contextPickerHeader(snapshot: RAGMentionPickerSnapshot) -> some View {
        HStack(spacing: 8) {
            Text(
                String(
                    format: String.l10n("rag.workspace.mention.stats"),
                    locale: locale,
                    snapshot.selectedCount,
                    KnowledgeRAGWorkspaceViewModel.maxSelectedRepoContexts,
                    snapshot.knowledgeCount
                )
            )
            .font(ragFont(.caption, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

            Spacer(minLength: 4)

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

            Button {
                viewModel.dismissMentionPicker()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(ragFont(.caption))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("common.close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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

    func mentionPickerRow(_ candidate: RAGMentionCandidate) -> some View {
        let isHighlighted = candidate.id == viewModel.highlightedMentionRepoIDValue
        let isSelected = viewModel.isMentionSelected(candidate)
        // 已达上限时仍允许取消已选项；未选中的行禁用，避免一次塞进上千仓库。
        let selectionFull = viewModel.selectedRepoContexts.count
            >= KnowledgeRAGWorkspaceViewModel.maxSelectedRepoContexts
        let canToggle = isSelected || !selectionFull
        return Button { viewModel.toggleMention(candidate) } label: {
            UnifiedCompactRepoRow(
                fullName: candidate.fullName,
                owner: candidate.owner,
                ownerAvatarURL: candidate.ownerAvatar,
                language: candidate.language,
                starsCount: candidate.starsCount,
                isChecked: isSelected,
                isHighlighted: isHighlighted,
                isEnabled: canToggle
            ) {
                // 索引侧元数据属于 RAG，不下沉进共享 Row 的仓库身份模型。
                if candidate.chunkCount > 0 {
                    MetaBadge(
                        systemImage: "square.stack.3d.up",
                        text: candidate.chunkCount.formattedShort,
                        tint: .secondary
                    )
                    .help(
                        Text(
                            String(
                                format: String.l10n("rag.workspace.mention.badge.chunks"),
                                locale: locale,
                                candidate.chunkCount
                            )
                        )
                    )
                }
                if candidate.hasAISummary {
                    MetaBadge(
                        systemImage: "sparkles",
                        text: "",
                        tint: .accentColor,
                        iconOnly: true,
                        accessibilityLabel: "rag.workspace.mention.badge.aiSummary"
                    )
                    .help("rag.workspace.mention.badge.aiSummary")
                }
                if candidate.hasPrivateNote {
                    MetaBadge(
                        systemImage: "note.text",
                        text: "",
                        tint: .orange,
                        iconOnly: true,
                        accessibilityLabel: "rag.workspace.mention.badge.privateNote"
                    )
                    .help("rag.workspace.mention.badge.privateNote")
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!canToggle)
        .help(
            canToggle
                ? Text(candidate.fullName)
                : Text(
                    String(
                        format: String.l10n("rag.workspace.mention.selectionLimit"),
                        locale: locale,
                        KnowledgeRAGWorkspaceViewModel.maxSelectedRepoContexts
                    )
                )
        )
    }

    var composerNSFont: NSFont {
        NSFont.systemFont(
            ofSize: interfaceScale.scaled(RAGConversationTypography.text.pointSize)
        )
    }

    var composerMinimumHeight: CGFloat {
        let lineHeight = composerNSFont.ascender - composerNSFont.descender + composerNSFont.leading
        return ceil(lineHeight * 2 + AICommandTextEditor.verticalInset * 2)
    }

    var composerMaximumHeight: CGFloat {
        118 * interfaceScale.multiplier
    }

    var composerEditorHeight: CGFloat {
        min(max(composerContentHeight, composerMinimumHeight), composerMaximumHeight)
    }

    func handleComposerCommand(_ command: AICommandTextEditor.Command) -> Bool {
        switch command {
        case .mentionTrigger:
            // RAG 仍通过 draftQuestion 解析 @ 查询，返回 false 让 NSTextView 正常插入字符。
            return false
        case .returnKey(let modifiers):
            let flags = modifiers.intersection(.deviceIndependentFlagsMask)
            // 事件来自主 Composer，就必须遵循发送偏好，不能因为项目面板仍打开而改成
            // 勾选/取消项目。面板搜索框自己的 onSubmit 仍负责键盘选择高亮候选。
            switch AIComposerKeyboardPolicy.action(
                for: flags,
                requiresCommandReturn: settings.aiChatRequiresCommandReturn
            ) {
            case .send:
                submitComposerQuestion()
                return true
            case .insertNewline:
                return false
            }
        case .upArrow:
            guard viewModel.isContextPickerPresented else { return false }
            viewModel.moveMentionSelection(by: -1)
            return true
        case .downArrow:
            guard viewModel.isContextPickerPresented else { return false }
            viewModel.moveMentionSelection(by: 1)
            return true
        case .escape:
            return viewModel.handleContextPickerEscape()
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
