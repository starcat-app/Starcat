//
//  RepoAIWindowContentView.swift
//  Starcat
//
//  详情页 AI 助手窗口的 SwiftUI 内容（HOM-150）。
//
//  模块职责：
//  - 把"AI 摘要"和"AI 对话"放在同一个浮动窗口里，但状态完全独立：
//    重新生成摘要不会清空对话；发送消息不会丢失摘要。
//  - 单面板模式（HOM-150 dong4j 2026-06-04 15:30 重设计）：
//    任一时刻只展示「摘要」**或**「对话」之一，中间一根 segmented toggle bar 切换。
//  - 摘要部分复用既有的 `RepoAIInsightViewModel`（生成 / 缓存 / 标签推荐三段），
//    对话部分由新的 `RepoAIChatViewModel` 承担。
//
//  关键约束（HOM-150 累计 4 轮 dong4j 反馈整合）：
//  - **单面板互斥**（dong4j 2026-06-04 15:30）：用 `AIPanelMode` 枚举控制当前激活
//    哪一边，另一边折叠到 height = 0；segmented bar 用户可主动切换；初始默认
//    `.summary`（最大化摘要），用户发送任何消息后自动切到 `.chat`（最大化对话）。
//  - **顶部下拉展开摘要**（dong4j 2026-06-04 15:30）：在 `.chat` 模式下，用户把
//    对话滚到顶部后再下拉到 -60pt overscroll → 切回 `.summary`；这是替代旧 32/8pt
//    hysteresis 的新交互——边界更清晰，不再在普通滚动里反复抖动。
//  - 流式生成摘要时摘要内部 ScrollView 必须**实时滚到底部**（ScrollViewReader +
//    底锚 + onChange of streamingSummaryText）。
//  - 复制按钮（摘要 header / 气泡时间戳 / 对话底部"复制全部"）统一走
//    `CopyFeedbackButton`：icon 切 ✓ + 绿色 + tooltip 切「已复制」+ 1.5s 复位。
//  - 对话 ScrollView 与窗口背景统一用 `.windowBackgroundColor`，AI 气泡无背景，
//    明暗主题切换下视觉一体。
//  - 摘要 "重新生成"/"复制" 按钮放在 header 右上角，与对话区互不抢位。
//  - 错误条采用克制橙色样式；两个 VM 各自的 errorMessage 都留位置。
//
//  历史背景：本视图随 HOM-150 累计 4 轮迭代——
//  v1 内嵌 segmented tab，v2 浮窗 + 三段布局 + 旧 hysteresis 折叠，v3 phase 门控
//  修反馈循环，**v4 (本版)** 完全删掉滚动 hysteresis、改单面板互斥 + top overscroll
//  + segmented toggle bar，把"滚动控制布局"这条不直觉的交互彻底剥离。
//

import SwiftUI

/// AI 助手窗口当前激活的面板（互斥）。
///
/// 设计：单面板互斥而非"两边都能 0~1 范围调节"，因为：
/// 1. 任意时刻用户都有一个明确的关注焦点（看摘要 / 跟 AI 聊）；
/// 2. 互斥设计省掉"两边都折叠看到空白"这种边界状态，UI 状态机更简洁；
/// 3. 与 dong4j 2026-06-04 15:30 的明确要求一致：「打开默认最大化摘要，
///    输入后切对话」。
enum AIPanelMode: String, CaseIterable, Identifiable, Hashable {
    /// 摘要面板撑满，对话面板折叠到 0。
    case summary
    /// 对话面板撑满，摘要面板折叠到 0。
    case chat

    var id: String { rawValue }
}

struct RepoAIWindowContentView: View {

    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel
    /// 读取当前登录用户的 GitHub username，供"复制完整对话"导出 Markdown 时
    /// 把角色标头里的 "你" 替换成真实 login（HOM-150 dong4j 2026-06-04 15:48）。
    /// 控制器创建 hosting 时已 `.environment(dependencies.authSession)` 注入。
    @Environment(AuthSession.self) private var authSession

    @State private var insightVM: RepoAIInsightViewModel?
    @State private var chatVM: RepoAIChatViewModel?

    /// 当前激活的面板（摘要 / 对话）。
    ///
    /// 初始 `.summary`——dong4j 2026-06-04 15:30 要求"打开默认最大化摘要面板"。
    /// 用户发送任何消息后 `sendChatMessage` 自动切到 `.chat`；在 `.chat` 状态下
    /// 对话区顶部下拉超过 -60pt（overscroll）会切回 `.summary`，作为"主动看回
    /// 摘要"的快捷手势。两个方向都靠中间的 segmented toggle bar 主动切换兜底。
    @State private var panelMode: AIPanelMode = .summary

    /// 对话区 ScrollView 最近一次的滚动 phase。
    ///
    /// 仅用于 `handleChatOverscroll` 守门：overscroll 必须由用户手势 phase
    /// (`.tracking / .interacting / .decelerating`) 触发，程序化 scrollTo（流式
    /// 自动滚底，phase = `.animating`）和布局抖动（phase = `.idle`）一律忽略。
    @State private var lastChatScrollPhase: ScrollPhase = .idle

    /// Top overscroll 触发摘要展开的阈值（pt）。
    ///
    /// macOS ScrollView 默认 bouncing 行为：滚到顶部后继续下拉，contentOffset.y
    /// 会进入负值区域。-60pt 是经验阈值——比"无意 bounce"幅度大（一次轻拉
    /// 大致在 -10 ~ -25），又比"触控板用力下拉"小（容易做到 -80 以上），不
    /// 误触也不难触发。
    private let overscrollExpandThreshold: CGFloat = -60

    var body: some View {
        VStack(spacing: 0) {
            summarySection
                .frame(maxWidth: .infinity, alignment: .top)
                // 单面板互斥：当前不激活的面板 maxHeight 切到 0。另一面板会撑
                // 满 VStack 的全部剩余空间。clipped 防止 0 高度时内部 padding
                // 溢出顶到下方面板。
                .frame(maxHeight: panelMode == .summary ? .infinity : 0)
                .clipped()
                .allowsHitTesting(panelMode == .summary)
                .animation(.easeInOut(duration: 0.28), value: panelMode)

            panelToggleBar

            chatSection
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(maxHeight: panelMode == .chat ? .infinity : 0)
                .clipped()
                .allowsHitTesting(panelMode == .chat)
                .animation(.easeInOut(duration: 0.28), value: panelMode)

            Divider()

            AIChatInputView(
                text: chatInputBinding,
                isSending: chatVM?.isSending ?? false,
                onSend: sendChatMessage
            )
        }
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
                // 底部锚点（dong4j 优化 1：现在像 ChatGPT 一样实时滚字）。
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

                            Color.clear
                                .frame(height: 1)
                                .id(Self.summaryBottomAnchorID)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: vm.streamingSummaryText ?? "") { _, newValue in
                        guard !newValue.isEmpty else { return }
                        proxy.scrollTo(Self.summaryBottomAnchorID, anchor: .bottom)
                    }
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
    /// 直接复用 `CopyFeedbackButton`，与气泡复制按钮 / 对话底部"复制全部"同源；
    /// 内容只取摘要 Markdown（`summaryMarkdown ?? summary`），不带对话 / 推荐
    /// 标签，与 HOM-150 验收要求一致。
    private func copyButton(insight: RepoAIInsight) -> some View {
        CopyFeedbackButton(
            providesContent: { insight.summaryMarkdown ?? insight.summary },
            tooltip: "复制摘要到剪贴板"
        ) { didCopy in
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .foregroundStyle(didCopy ? Color.green : Color.primary)
                .contentTransition(.symbolEffect(.replace))
        }
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

    // MARK: - 面板切换条（HOM-150 dong4j 2026-06-04 15:30 重设计）

    /// 摘要 / 对话之间的 segmented 切换条。
    ///
    /// 设计要点：
    /// - 用原生 `Picker(.segmented)`：macOS 上渲染为 `NSSegmentedControl` 风格，
    ///   与系统视觉一致，不抢戏；
    /// - icon + 文字双标识："✨ AI 摘要" / "💬 AI 对话"，扫一眼即可分辨；
    /// - selection 绑定 `panelMode` 并带 0.28s easeInOut 动画，与上下两段
    ///   `frame(maxHeight: ...)` 的折叠动画完全同节奏；
    /// - bar 自带细分隔线（`.bar` 材质 + Divider 上下），视觉上是上下两段
    ///   面板的边界，无需额外加 `Divider()`。
    private var panelToggleBar: some View {
        HStack(spacing: 0) {
            Picker("", selection: $panelMode.animation(.easeInOut(duration: 0.28))) {
                Label("AI 摘要", systemImage: "sparkles").tag(AIPanelMode.summary)
                Label("AI 对话", systemImage: "bubble.left.and.bubble.right").tag(AIPanelMode.chat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 限宽避免在大窗口下 segmented 被拉成超长条带；居中通过外层
            // `.frame(maxWidth: .infinity)` + Picker 自身有限宽实现。
            .frame(maxWidth: 280)
            .help("切换 AI 摘要 / AI 对话面板（互斥）")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
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

                            // 对话底部"复制全部"区域：流式中（chat.isSending）暂时
                            // 隐藏，避免用户在 token 还在流时复制到半截 Markdown。
                            if !chat.isSending {
                                conversationCopyRow(chat: chat)
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
                // dong4j 2026-06-04 15:30 重设计：不再用滚动 hysteresis 切折叠，
                // 改为只识别"顶部下拉 overscroll"这一种明确的 scroll-driven 手势。
                .onScrollPhaseChange { _, newPhase in
                    lastChatScrollPhase = newPhase
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, newOffset in
                    handleChatOverscroll(
                        offsetY: newOffset,
                        hasMessages: !chat.messages.isEmpty
                    )
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

    /// 对话区"顶部下拉 overscroll"检测（HOM-150 dong4j 2026-06-04 15:30 新设计）。
    ///
    /// 触发条件（全部成立才切换）：
    /// 1. `panelMode == .chat`：当前在对话模式（在摘要模式下这个 handler 没意义）；
    /// 2. `hasMessages`：对话非空（空状态下 contentOffset 抖动语义不明确）；
    /// 3. 用户手势驱动相位（`.tracking / .interacting / .decelerating`）：排除
    ///    流式 `proxy.scrollTo` 程序化滚动（phase = `.animating`）和布局抖动
    ///    （phase = `.idle`）触发的偏移变化——同 v3 修反馈循环时的门控逻辑；
    /// 4. `offsetY < overscrollExpandThreshold` (默认 -60pt)：macOS bouncing 区
    ///    需要明显下拉幅度，避免误触；
    /// 5. `panelMode == .chat` 守门防止在动画切到 `.summary` 后又被 layout 抖动
    ///    再次触发（虽然 phase 门控基本兜住，多一道守门更稳）。
    ///
    /// 为什么不用 `.refreshable {}`：那个 modifier 会在 ScrollView 顶部加一个
    /// pull-to-refresh ProgressView 圆圈，视觉上像"加载指示"而不是"展开面板"，
    /// 容易引起用户误解。手动监听 contentOffset 的负值区间更纯粹。
    private func handleChatOverscroll(offsetY: CGFloat, hasMessages: Bool) {
        guard panelMode == .chat else { return }
        guard hasMessages else { return }

        switch lastChatScrollPhase {
        case .interacting, .decelerating, .tracking:
            break
        case .idle, .animating:
            return
        @unknown default:
            return
        }

        guard offsetY < overscrollExpandThreshold else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            panelMode = .summary
        }
    }

    /// 对话底部"复制全部对话"区域。
    ///
    /// 复用 `CopyFeedbackButton`，反馈机制与摘要 / 气泡复制按钮完全一致：
    /// icon 切 ✓ + 绿色 + tooltip 切「已复制 ✓」+ 1.5s 复位。
    /// 调用 `chat.markdownExport(repo:)` 拼完整 Markdown 文档（结构见
    /// `RepoAIChatViewModel.markdownExport` 注释）；providesContent 是 closure，
    /// 按下瞬间才拼字符串，避免每次 view 重绘都做 N 条消息的字符串拼接。
    private func conversationCopyRow(chat: RepoAIChatViewModel) -> some View {
        HStack {
            Spacer()
            CopyFeedbackButton(
                providesContent: { chat.markdownExport(repo: repo, userLogin: currentUserLogin) },
                tooltip: "复制全部对话为 Markdown 到剪贴板"
            ) { didCopy in
                HStack(spacing: 6) {
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.caption)
                        .contentTransition(.symbolEffect(.replace))
                    Text(didCopy ? "已复制 ✓" : "复制完整对话")
                        .font(.caption)
                }
                .foregroundStyle(didCopy ? Color.green : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
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
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
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

    /// 当前登录用户的 GitHub username（如 `dong4j`）。
    ///
    /// 用于"复制完整对话"导出的 Markdown 文档里替换角色标头的 "你"。未登录
    /// 或 state 不是 `.authenticated` 时返回 nil，markdownExport 内部会兜底
    /// 回退为 "你"，保留旧行为。
    private var currentUserLogin: String? {
        if case .authenticated(let user) = authSession.state {
            return user.login
        }
        return nil
    }

    /// 发送当前输入。
    ///
    /// dong4j 2026-06-04 15:30 反馈："用户输入对话时折叠 AI 摘要，展开 AI 对话框
    /// 面板"——所以发送时如果当前不在 `.chat` 模式则切过去，并不区分"是不是第
    /// 一条"。若已经在 `.chat`，跳过切换避免无谓动画。
    private func sendChatMessage() {
        guard let chatVM else { return }
        let repoSnapshot = repo
        Task { await chatVM.sendMessage(repo: repoSnapshot) }
        if panelMode != .chat {
            withAnimation(.easeInOut(duration: 0.3)) {
                panelMode = .chat
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
