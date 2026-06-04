//
//  RepoAIWindowContentView.swift
//  Starcat
//
//  详情页 AI 助手窗口的 SwiftUI 内容（HOM-150）。
//
//  模块职责：
//  - 把"AI 摘要"和"AI 对话"放在同一个浮动窗口里，但状态完全独立：
//    重新生成摘要不会清空对话；发送消息不会丢失摘要。
//  - 三段布局：顶部摘要（可折叠 / 限高 + 内部滚动）→ 可点击折叠条 → 中部对话列表
//    （撑满剩余高度）→ 分隔线 → 底部输入条。
//  - 摘要部分复用既有的 `RepoAIInsightViewModel`（生成 / 缓存 / 标签推荐三段），
//    对话部分由新的 `RepoAIChatViewModel` 承担。
//
//  关键约束（HOM-150 + 2026-06-04 14:30 dong4j 5 项优化反馈）：
//  - 摘要"重新生成"和"复制"按钮复用 `RepoAIInsightViewModel`（VM 不动），UI 把
//    两个动作单独拎到顶部 header 右上角，让对话区域不被它们盖住。
//  - 流式生成摘要时摘要内部 ScrollView 必须**实时滚到底部**（ScrollViewReader +
//    底锚 + onChange of streamingSummaryText）。否则用户看不到正在生成的内容，
//    必须等生成结束再拖滚动条。
//  - 复制按钮点击后给即时反馈：icon 切 `checkmark.circle.fill`、tooltip 切"已复制"，
//    1.5s 自动复位；用 Task 而不是 DispatchQueue 让 @MainActor 链路稳定。
//  - 对话 ScrollView 背景不再是 `underPageBackgroundColor`（明亮主题下会显灰），
//    改用窗口主题色 `.windowBackgroundColor`；AI 气泡也去掉自身背景色，让明暗
//    主题切换时整片对话区颜色一致。
//  - 顶部摘要面板与对话之间是 **可点击的折叠条**（chevron + 文字胶囊）：
//    ① 用户主动点击折叠 / 展开；② 对话向下滚到一定阈值时（>32pt）自动折叠摘要，
//    回滚到 8pt 内自动展开——与 `RepoDetailView.metadataPanel` 同款 hysteresis；
//    ③ 用户发送第一条消息时也自动折叠，把对话区让到最大。
//  - 错误条采用克制橙色样式；两个 VM 各自的 errorMessage 都留位置（chat 失败不应
//    隐藏摘要错误，反之亦然）。
//
//  历史背景：本视图是 HOM-150 引入的新交互；旧的"详情页内嵌 AI tab"
//  （RepoAIInsightPanel.swift）已被替换并随该迭代删除。
//

import SwiftUI

struct RepoAIWindowContentView: View {

    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel

    @State private var insightVM: RepoAIInsightViewModel?
    @State private var chatVM: RepoAIChatViewModel?

    /// 顶部摘要面板是否折叠（高度 → 0）。
    ///
    /// 与 `RepoDetailView.isMetadataPanelHidden` 相同的设计动机：
    /// 用 Bool 而不是把 scroll offset 存成状态，避免 SwiftUI 每像素重新布局。
    @State private var isSummaryCollapsed: Bool = false

    /// 复制按钮"已复制"反馈态。1.5s 后自动复位。
    @State private var didCopySummary: Bool = false

    /// 复位 didCopySummary 的延迟任务句柄。
    ///
    /// 用 `Task` 而不是 `DispatchQueue.main.asyncAfter`：
    /// ① 用户可能快速连点复制按钮，需要把上一次延迟任务 cancel 掉再起新的，
    ///    Task 自带 cancel 比 dispatch 简单干净；
    /// ② 整个 View 是 SwiftUI，Task 完成回到 MainActor 不需要额外 Dispatch hop。
    @State private var copyResetTask: Task<Void, Never>?

    /// 摘要展开时的最大高度。
    ///
    /// 与 dong4j 优化 5 的诉求一致：有摘要时优先展示摘要 → 给 360pt 而不是原先的
    /// 280pt（够 4~5 行 + 标签推荐头）；内部 ScrollView 兜底超长内容。发送第一条
    /// 消息后自动折叠（不靠这个值控制，靠 isSummaryCollapsed）。
    private let summaryExpandedMaxHeight: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            summarySection
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(maxHeight: isSummaryCollapsed ? 0 : summaryExpandedMaxHeight)
                .clipped()
                .allowsHitTesting(!isSummaryCollapsed)
                // easeInOut 0.25s：跟 RepoDetailView.metadataPanelAnimation 同节奏
                // （0.32s spring）相近但稍快，因为这里只折叠一段 UI，不像详情页
                // 还要 WebView 跟着重新分配高度。
                .animation(.easeInOut(duration: 0.25), value: isSummaryCollapsed)

            summaryCollapseDivider

            chatSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            AIChatInputView(
                text: chatInputBinding,
                isSending: chatVM?.isSending ?? false,
                onSend: sendChatMessage
            )
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: repo.id) {
            await initializeViewModelsIfNeeded()
            await insightVM?.load(repo: repo)
        }
    }

    // MARK: - 初始化

    /// 首次进入窗口时构造两个 VM。
    ///
    /// 用 `@State` 包一层而不是在 init 里直接创建，是因为 SwiftUI struct init 不能
    /// 安全地访问 @Environment（环境在 body 求值时才注入）；放进 `.task` 拿到环境
    /// 后再创建可靠得多。
    private func initializeViewModelsIfNeeded() async {
        if insightVM == nil {
            let ivm = RepoAIInsightViewModel(
                service: dependencies.repoAIInsightService,
                tagRepository: dependencies.tagRepository,
                repoTagRepository: dependencies.repoTagRepository
            )
            // 与旧详情页 AI Tab 行为一致：应用标签后刷新主窗 Sidebar + 列表。
            // 窗口可能独立于主窗存在，但 HomeViewModel 是同一实例，刷新调用安全。
            ivm.onTagsChanged = { [weak homeViewModel] in
                Task {
                    await homeViewModel?.refreshSidebar()
                    await homeViewModel?.reloadItems()
                }
            }
            insightVM = ivm
        }
        if chatVM == nil {
            chatVM = RepoAIChatViewModel(service: dependencies.repoAIInsightService)
        }
    }

    // MARK: - 摘要段

    @ViewBuilder
    private var summarySection: some View {
        if let vm = insightVM {
            VStack(alignment: .leading, spacing: 0) {
                summaryHeader(vm: vm)

                // ScrollViewReader 内嵌 ScrollView，让流式 token 进来时能 `scrollTo`
                // 底部锚点——核心修复 dong4j 反馈 1：之前 ScrollView 无 reader，
                // 生成时内容长出 280pt 后 SwiftUI 不会自动跟随，用户只能等结束再手滚。
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let error = vm.errorMessage {
                                errorBanner(message: error)
                            }

                            if vm.isLoading {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在读取本地 AI 缓存…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else if let draft = vm.streamingSummaryText, !draft.isEmpty {
                                streamingSummary(draft)
                            } else if let insight = vm.insight {
                                insightContent(insight, vm: vm)
                            } else {
                                emptySummaryState(vm: vm)
                            }

                            // 摘要底部锚点：流式 / 完成两种状态都用同一个，scrollTo 时只
                            // 改 anchor 参考点不改 id。`.frame(height: 1)` 透明占位
                            // 是为了在 SwiftUI diff 上稳定存在，不会被空内容优化掉。
                            Color.clear
                                .frame(height: 1)
                                .id(Self.summaryBottomAnchorID)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // 流式增量：每个 token 进来都把摘要滚到底，让用户看到"打字机"效果。
                    .onChange(of: vm.streamingSummaryText ?? "") { _, newValue in
                        guard !newValue.isEmpty else { return }
                        proxy.scrollTo(Self.summaryBottomAnchorID, anchor: .bottom)
                    }
                    // 生成完成切到 insight 渲染：再补一次滚动，避免最后一行卡在折叠处。
                    .onChange(of: vm.insight?.summaryMarkdown ?? "") { _, _ in
                        proxy.scrollTo(Self.summaryBottomAnchorID, anchor: .bottom)
                    }
                }
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("初始化中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static let summaryBottomAnchorID = "summary-bottom-anchor"

    private func summaryHeader(vm: RepoAIInsightViewModel) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Label("AI 摘要", systemImage: "sparkles")
                .font(.headline)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)

            Spacer()

            // "重新生成"/"复制"按钮只在已有 insight 且非加载中时显示，避免重复触发。
            if let insight = vm.insight, !vm.isGenerating {
                copyButton(insight: insight)

                Button {
                    Task { await vm.generate(repo: repo) }
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .help("重新生成摘要（不影响对话）")
            } else if vm.isGenerating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 复制按钮（含点击反馈，HOM-150 dong4j 优化 2）。
    ///
    /// 状态机：
    /// - 默认：icon = `doc.on.doc`，tooltip = "复制摘要到剪贴板"
    /// - 点击后：icon 切 `checkmark.circle.fill`、tooltip 切"已复制 ✓"，1.5s 自动复位
    /// - 复位用 `Task.sleep` + cancel 旧任务，连点不会出现"刚切完又被旧任务复位"
    private func copyButton(insight: RepoAIInsight) -> some View {
        Button {
            copySummaryToClipboard(insight)
            // 切到反馈态并起 1.5s 复位任务；旧任务先 cancel 掉。
            copyResetTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) {
                didCopySummary = true
            }
            copyResetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) {
                    didCopySummary = false
                }
            }
        } label: {
            Image(systemName: didCopySummary ? "checkmark.circle.fill" : "doc.on.doc")
                .foregroundStyle(didCopySummary ? Color.green : Color.primary)
                // contentTransition 让 SF Symbol 在两个 icon 之间柔性过渡，
                // 不是硬切，反馈感更明显。
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .focusEffectDisabled()
        .help(didCopySummary ? "已复制 ✓" : "复制摘要到剪贴板")
    }

    /// 只复制摘要 markdown，不带对话 / 推荐标签，与 HOM-150 验收要求一致。
    private func copySummaryToClipboard(_ insight: RepoAIInsight) {
        let content = (insight.summaryMarkdown ?? insight.summary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    @ViewBuilder
    private func emptySummaryState(vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("尚未生成 AI 摘要")
                .font(.subheadline.weight(.semibold))
            Text("可以直接在下方对话区追问；如需结构化摘要，点击右侧「生成摘要」。摘要会读取本仓库的元数据、README、topics 并以 Markdown 输出。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                Task { await vm.generate(repo: repo) }
            } label: {
                if vm.isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("生成摘要", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .focusEffectDisabled()
            .disabled(vm.isGenerating)
        }
    }

    private func streamingSummary(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在生成 AI 摘要…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            RepoAISummaryMarkdownView(markdown: text)
        }
    }

    @ViewBuilder
    private func insightContent(_ insight: RepoAIInsight, vm: RepoAIInsightViewModel) -> some View {
        RepoAISummaryMarkdownView(markdown: insight.summaryMarkdown ?? insight.summary)

        if !insight.suggestedTags.isEmpty {
            Divider()
            tagSuggestionsBlock(insight.suggestedTags, vm: vm)
        }

        if let tagError = vm.tagErrorMessage {
            errorBanner(message: "推荐标签解析失败：\(tagError)")
        }

        footer(insight)
    }

    /// 推荐标签块。视觉上比对话气泡克制：
    /// "tag name + reason + 置信度 + 应用按钮"，与旧详情页 AI Tab 的样式对齐。
    private func tagSuggestionsBlock(_ tags: [AITagSuggestion], vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("推荐标签")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("全部应用") {
                    Task { await vm.applyAllTags(repo: repo) }
                }
                .controlSize(.small)
                .disabled(tags.allSatisfy { vm.appliedTagNames.contains($0.name.trimmingNormalized) })
            }

            ForEach(tags) { tag in
                let isApplied = vm.appliedTagNames.contains(tag.name.trimmingNormalized)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tag.name)
                            .font(.body.weight(.medium))
                        Text(tag.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int((max(0, min(tag.confidence, 1)) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button(isApplied ? "已应用" : "应用") {
                        Task { await vm.applyTag(tag, repo: repo) }
                    }
                    .controlSize(.small)
                    .disabled(isApplied)
                }
            }
        }
    }

    private func footer(_ insight: RepoAIInsight) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
            Text("由 \(insight.model) 生成 · \(formattedDate(insight.generatedAt))")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func formattedDate(_ value: String) -> String {
        guard let date = ISO8601DateFormatter.shared.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - 折叠分隔条（HOM-150 dong4j 优化 4）

    /// 摘要 / 对话之间的可点击折叠条。
    ///
    /// 设计要点：
    /// - 横向贯穿（与 `Divider()` 视觉一致），中间露一个**圆角胶囊 chevron + 文字**，
    ///   足够显眼又不抢戏；
    /// - 鼠标 hover 给胶囊加 `.pressableHover()` 的同款变暗 + 微放大反馈，
    ///   让"这是一个可点击的控件"立刻被感知；
    /// - 文字会随状态切换：展开时显示"折叠 AI 摘要"、折叠时显示"展开 AI 摘要"，
    ///   完全不依赖用户去猜 chevron 方向语义；
    /// - 整条都是 button hit area（`contentShape(Rectangle())`），用户瞄不准胶囊
    ///   也能点中。
    private var summaryCollapseDivider: some View {
        Button {
            toggleSummaryCollapseManually()
        } label: {
            ZStack {
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 1)

                HStack(spacing: 6) {
                    Image(systemName: isSummaryCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                    Text(isSummaryCollapsed ? "展开 AI 摘要" : "折叠 AI 摘要")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                )
                .pressableHover(opacity: 0.75, scale: 1.04)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(isSummaryCollapsed ? "展开 AI 摘要面板" : "折叠 AI 摘要面板")
    }

    /// 手动折叠 / 展开切换。
    ///
    /// 与"对话滚动驱动的自动折叠"互不冲突：本函数只翻 `isSummaryCollapsed`，
    /// 下一次 scroll geometry 进来时滚动 hysteresis 仍会按当前真实 offsetY 计算
    /// 并相应覆盖。用户在 chat 中段位置手动展开后再继续向下滚，会再次被折叠——
    /// 这是有意的"动作连续"，避免维护"用户最近一次手动状态"这种隐藏 state。
    private func toggleSummaryCollapseManually() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isSummaryCollapsed.toggle()
        }
    }

    // MARK: - 对话段

    @ViewBuilder
    private var chatSection: some View {
        if let chat = chatVM {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if chat.messages.isEmpty {
                            chatEmptyState
                                .padding(.top, 60)
                        } else {
                            ForEach(chat.messages) { message in
                                AIChatBubble(message: message)
                                    .id(message.id)
                            }
                            // 锚点：scrollTo 用，让"新消息追加后自动滚到最底部"。
                            // 单独留一个 0 高度 anchor 比 scrollTo 最后一条 message.id
                            // 更稳：流式中助手 message 不断改 content，scrollTo 同一个
                            // id 在某些版本 SwiftUI 下不重新触发滚动，0 高度 anchor 不会。
                            Color.clear
                                .frame(height: 1)
                                .id(Self.chatBottomAnchorID)
                        }
                    }
                    .padding(.vertical, 16)
                }
                // 优化 3：换用窗口主题色（`.windowBackgroundColor`），明暗主题下都跟
                // 窗口背景统一，不再像 `.underPageBackgroundColor` 那样在浅色主题下
                // 偏灰显得"AI 对话区是另一块卡片"。
                // 当前 body 的最外层已经挂了同色 background，这里再显式声明一遍是为了
                // 让 LazyVStack 内部任何透明边界都不会露出窗口陈年默认色。
                .background(Color(nsColor: .windowBackgroundColor))
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.chatBottomAnchorID, anchor: .bottom)
                    }
                }
                .onChange(of: chat.messages.last?.content ?? "") { _, _ in
                    // 流式 token 进来时也滚一下，否则长回答会被滚动条卡在中间。
                    proxy.scrollTo(Self.chatBottomAnchorID, anchor: .bottom)
                }
                // 优化 4：监听对话区滚动偏移，hysteresis 折叠摘要面板。
                // `onScrollGeometryChange` 是 macOS 15+ 新 API；本工程 deploymentTarget
                // 15.0，可以直接用。把 contentOffset.y 截下来交给 hysteresis 逻辑。
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, newOffset in
                    handleChatScroll(offsetY: newOffset, hasMessages: !chat.messages.isEmpty)
                }

                if let err = chat.errorMessage {
                    chatErrorBanner(message: err) {
                        chat.dismissError()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
        } else {
            Color.clear
        }
    }

    private static let chatBottomAnchorID = "chat-bottom-anchor"

    /// 对话区滚动偏移 → 摘要折叠状态（HOM-150 优化 4）。
    ///
    /// 复用 `RepoDetailView.updateMetadataPanelVisibility` 同款 hysteresis 阈值：
    /// - 滚下越过 32pt 才触发折叠：避免触控板"轻点"就把摘要藏掉；
    /// - 回到 8pt 内再恢复展开：避免顶部附近来回弹动反复闪动。
    ///
    /// `hasMessages` 守门：空对话不参与自动折叠——空状态下 chat 区的 offset 通常是
    /// 0，但 LazyVStack 偶尔布局抖动会越过阈值，没有内容时折叠摘要是反直觉的。
    private func handleChatScroll(offsetY: CGFloat, hasMessages: Bool) {
        guard hasMessages else { return }
        let shouldCollapse = isSummaryCollapsed ? offsetY > 8 : offsetY > 32
        guard shouldCollapse != isSummaryCollapsed else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            isSummaryCollapsed = shouldCollapse
        }
    }

    private var chatEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("开始与 AI 聊聊这个仓库")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("AI 已带上仓库元数据与 README 上下文；你可以追问适用场景、对比方案、读源码线索等。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }

    private var chatInputBinding: Binding<String> {
        Binding(
            get: { chatVM?.inputText ?? "" },
            set: { chatVM?.inputText = $0 }
        )
    }

    /// 发送当前输入。
    ///
    /// 优化 5：发送**第一条**消息时自动折叠摘要面板，把对话区让到最大——
    /// 实现上判断"发送前 messages 是否为空"，是则在动画里翻 isSummaryCollapsed。
    /// 之后的消息不会再触发折叠（用户可能手动展开过摘要，不应被覆盖）。
    private func sendChatMessage() {
        guard let chatVM else { return }
        let wasFirstMessage = chatVM.messages.isEmpty
        let repoSnapshot = repo
        Task { await chatVM.sendMessage(repo: repoSnapshot) }
        if wasFirstMessage, !isSummaryCollapsed {
            withAnimation(.easeInOut(duration: 0.3)) {
                isSummaryCollapsed = true
            }
        }
    }

    // MARK: - 错误条

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.caption)
        }
        .foregroundStyle(.orange)
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func chatErrorBanner(message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - String helpers

private extension String {
    /// 与 RepoAIInsightViewModel.normalizedTagName 行为一致——
    /// 那个 extension 是 private，本文件需要同等规则匹配 `appliedTagNames`
    /// 集合时复制一份逻辑，避免破开既有 VM 的访问控制。
    var trimmingNormalized: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
