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
//    任一时刻只创建并展示「摘要」**或**「对话」之一，中间 segmented toggle 切换。
//  - 摘要部分复用既有的 `RepoAIInsightViewModel`（生成 / 缓存 / 标签推荐三段），
//    对话部分由新的 `RepoAIChatViewModel` 承担。
//
//  关键约束（HOM-150 累计 4 轮 dong4j 反馈整合）：
//  - **单面板互斥**（dong4j 2026-06-04 15:30）：用 `AIPanelMode` 枚举控制当前激活
//    哪一边，非活动面板不进入视图树；segmented bar 用户可主动切换；初始默认
//    `.summary`（最大化摘要），用户发送任何消息后自动切到 `.chat`（最大化对话）。
//  - **顶部下拉展开摘要**（dong4j 2026-06-04 15:30）：在 `.chat` 模式下，用户把
//    对话滚到顶部后再下拉到 -60pt overscroll → 切回 `.summary`；这是替代旧 32/8pt
//    hysteresis 的新交互——边界更清晰，不再在普通滚动里反复抖动。
//  - 流式生成摘要时摘要内部 ScrollView 必须**实时滚到底部**（ScrollViewReader +
//    底锚 + onChange of streamingSummaryText）。
//  - 复制按钮（摘要 header / 气泡时间戳 / 对话底部"复制全部"）统一走
//    `CopyFeedbackButton`：icon 切 ✓ + 绿色 + tooltip 切「已复制」+ 1.5s 复位。
//  - 对话 ScrollView 与根视图保持透明，背景统一由 AppKit `NSVisualEffectView`
//    提供；AI 气泡无背景，明暗主题切换下视觉一体。
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
    /// 只创建摘要面板。
    case summary
    /// 只创建对话面板。
    case chat

    var id: String { rawValue }
}

struct RepoAIWindowContentView: View {

    let repo: Repo
    let onClose: () -> Void

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel
    /// 读取当前登录用户的 GitHub username，供"复制完整对话"导出 Markdown 时
    /// 把角色标头里的 "你" 替换成真实 login（HOM-150 dong4j 2026-06-04 15:48）。
    /// 控制器创建 hosting 时已 `.environment(dependencies.authSession)` 注入。
    @Environment(AuthSession.self) private var authSession

    /// Y9（2026-06-14）：响应快捷菜单 / Settings 页面对开关字段的修改，让
    /// `chatContextStatusRow` 能即时刷新；与 `AIChatInputView` 共用同一份注入。
    @Environment(AppSettings.self) private var settings

    /// 2026-06-15:摘要 / chat panel 切换、tail follow toggle 等多处
    /// 0.2-0.3s 隐式动画在「关闭应用内动画」时全部跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    @State private var insightVM: RepoAIInsightViewModel?
    @State private var chatVM: RepoAIChatViewModel?
    /// 历史消息的“修改”操作通过一次性请求回填输入组件。正常键入只改输入组件
    /// 内部 `@State`，不会让本窗口根视图跟着每个字符失效。
    @State private var pendingChatDraftReplacement: String?
    @FocusState private var isChatInputFocused: Bool

    /// AI 窗口打开瞬间冻结的 star 状态（R-01 §3.2.7 Step 8）。
    ///
    /// 设计动机：用户打开 AI 窗口后，可能在主窗 / 详情页 star/unstar 同一 repo。
    /// 如果 AI 窗口的标签段（"AI 推荐标签 + 应用按钮"）跟随 `StarredRegistry.ids`
    /// 实时变化，会出现「窗口打开后标签段突然消失 / 突然冒出」的诡异交互。
    ///
    /// 决策：窗口打开时**捕获一次**当前 star 状态，本轮窗口生命周期内**不响应**
    /// `registry.ids` 的后续变化。关闭窗口再重新打开时按新状态重新决定。
    /// `nil` = 还未捕获（首次 .task 时初始化）；其后只读不写。
    @State private var starredAtOpen: Bool?

    /// 当前激活的面板（摘要 / 对话）。
    ///
    /// 初始 `.summary`——dong4j 2026-06-04 15:30 要求"打开默认最大化摘要面板"。
    /// 用户发送任何消息后 `sendChatMessage` 自动切到 `.chat`；在 `.chat` 状态下
    /// 对话区顶部下拉超过 -60pt（overscroll）会切回 `.summary`，作为"主动看回
    /// 摘要"的快捷手势。两个方向都靠中间的 segmented toggle bar 主动切换兜底。
    @State private var panelMode: AIPanelMode = .summary

    /// 摘要 / 对话各自的"跟随尾部"状态机（2026-06-15 dong4j 反馈）。
    ///
    /// 用户痛点：流式生成 AI 摘要 / 对话时，UI 强制 scrollTo(.bottom) 会把
    /// 用户主动上滚到的位置又拽回底部，无法回看已经吐出来的内容。
    ///
    /// 解决：把"跟随尾部 + 滚回底部自动恢复"抽到 `ScrollTailController`
    /// （见 `Starcat/Shared/Components/ScrollFollowTail.swift`），摘要段
    /// 与对话段各持一个独立 controller——两边逻辑同源、状态隔离。
    ///
    /// `chatTail.lastPhase` 同时承担旧 `lastChatScrollPhase` 的职责
    /// （overscroll 切回摘要面板时的 phase 门控），不再单独维护一份 state。
    @State private var summaryTail = ScrollTailController()
    @State private var chatTail = ScrollTailController()
    /// 合并同一 run-loop 内的多个流式更新，避免连续向 ScrollViewReader 排队 scrollTo。
    @State private var isChatTailScrollScheduled: Bool = false

    /// HOM-70：session 列表 popover 显示状态。
    @State private var isSessionListPresented: Bool = false

    /// HOM-70 v2：「承接自上一对话」banner 的 view-端 dismiss 跟踪。
    ///
    /// **关键解耦**：dismiss 仅翻 view 端状态隐藏 banner UI，**不动**
    /// `chat.currentCarriedOverSummary` —— AI 仍能从 system prompt 的
    /// `{previousSessionCarryOver}` section 看到承接段，让"AI 知道" vs "用户视觉"
    /// 完全独立。用户点 ✕ 表达"我不需要继续看到这个提醒"而不是"清除上文承接"。
    ///
    /// 用 `Set<UUID>` 按 session id 跟踪：切回已 dismiss 的 session 不再弹 banner；
    /// 切到其它带承接的 session 仍正常显示。@State 仅生命周期内有效，重启窗口
    /// 后所有 dismiss 清零（行为可接受，用户重新打开 = 给一次提醒机会）。
    @State private var carryOverDismissedSessions: Set<UUID> = []
    /// HOM-70 v2：「承接自上一对话」banner 的展开/收起跟踪（按 session 独立）。
    /// 承接摘要末 6 条对话拼的 markdown 可能比较长，默认 3 行预览 + 用户点击展开看全文。
    @State private var carryOverExpandedSessions: Set<UUID> = []

    /// HOM-70：清除当前 repo 对话历史的确认弹窗状态。
    @State private var pendingClearCurrentRepoConfirm: Bool = false

    /// Top overscroll 触发摘要展开的阈值（pt）。
    ///
    /// macOS ScrollView 默认 bouncing 行为：滚到顶部后继续下拉，contentOffset.y
    /// 会进入负值区域。-60pt 是经验阈值——比"无意 bounce"幅度大（一次轻拉
    /// 大致在 -10 ~ -25），又比"触控板用力下拉"小（容易做到 -80 以上），不
    /// 误触也不难触发。
    private let overscrollExpandThreshold: CGFloat = -60

    var body: some View {
        VStack(spacing: 0) {
            panelHeader

            Divider()

            activePanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            panelToggleBar

            Divider()

            AIChatInputView(
                pendingReplacement: $pendingChatDraftReplacement,
                focus: $isChatInputFocused,
                isSending: chatVM?.isSending ?? false,
                onSend: sendChatMessage,
                onCancel: cancelChatStreaming
            )

            // 对话上下文状态提示（Y8，2026-06-14；2026-06-15 13:05 dong4j 反馈把它
            // 移到输入框**下方**）：原设计放在 chat 输入框上方，与 macOS 习惯不符——
            // macOS 常见模式是「输入主体在上 / 状态条在下」（Xcode 编辑器底栏、Mail
            // 写信底栏都是这个布局）。把 caption 紧贴底部，让上下文标签作为输入框的
            // 辅助状态信息，而不是 banner-style 横在头顶。
            //
            // 关键设计：
            //   - **数据源复用摘要 vm**：`insight.contextMetadata` / `vm.contextDegradationReason`
            //     在摘要 generate 路径已被填充，chat 路径与摘要共用同一份 makeSource 结果，
            //     不需要在 RepoAIChatViewModel 里再持一份；
            //   - **只在 .chat 面板显示**：摘要面板已有 banner / footer 双重提示，无需重复；
            //   - **3 态不显**（用户主动关总开关 / 摘要还没生成过 / 网络在跑）：不打扰，
            //     让"轻量"原则真的轻量——只在有明确信号时给反馈。
            if panelMode == .chat {
                chatContextStatusRow
                    .transition(.opacity)
            }
        }
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .task(id: repo.id) {
            // R-01 §3.2.7 Step 8：第一次 task 触发时冻结 star 状态。
            // 窗口可能在 task 期间被切换 repo（id 变化触发 task 重跑），那种情况
            // 我们也重新捕获一次（视为"等价于关闭再打开"）——通过 nil-check 之后
            // 直接覆盖式赋值实现，每次 task 重跑都重新读取当前 registry。
            starredAtOpen = dependencies.starredRegistry.contains(ghRepoId: repo.id)
            await initializeInsightViewModelIfNeeded()
            await insightVM?.load(repo: repo)
        }
        .task(id: panelMode) {
            guard panelMode == .chat else { return }
            await prepareChatIfNeeded()
        }
    }

    /// 任一时刻只让当前面板进入 SwiftUI 视图树。旧实现把另一面板压到高度 0，
    /// 但隐藏的 Markdown 仍会解析、布局并响应状态变化，是输入和切换卡顿的主因。
    @ViewBuilder
    private var activePanel: some View {
        switch panelMode {
        case .summary:
            summarySection
        case .chat:
            chatSection
        }
    }

    /// 自定义面板标题栏。系统标题栏被隐藏后，主动关闭入口必须留在内容树中；
    /// `isMovableByWindowBackground` 仍让标题空白区域承担拖动窗口的职责。
    private var panelHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.purple)

            Text(
                verbatim: String(
                    format: String(localized: "ai.assistant.window.titleFormat"),
                    repo.fullName
                )
            )
            .font(.headline)
            .lineLimit(1)

            Spacer(minLength: 12)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("ai.assistant.window.close.help")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 初始化

    /// 首次进入窗口时只构造摘要 VM；聊天 VM 延迟到首次使用。
    ///
    /// 用 `@State` 包一层而不是在 init 里直接创建，是因为 SwiftUI struct init 不能
    /// 安全地访问 @Environment（环境在 body 求值时才注入）；放进 `.task` 拿到环境
    /// 后再创建可靠得多。
    private func initializeInsightViewModelIfNeeded() async {
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
                    await homeViewModel?.reloadItems(forceRefresh: true)
                }
            }
            insightVM = ivm
        }
    }

    /// 聊天历史只在用户首次进入聊天面板或首次发送时加载。窗口默认展示摘要，
    /// 首帧不应该为不可见的聊天 Markdown 支付解析和布局成本。
    private func prepareChatIfNeeded() async {
        let vm: RepoAIChatViewModel
        if let chatVM {
            vm = chatVM
        } else {
            let newVM = RepoAIChatViewModel(service: dependencies.repoAIInsightService)
            chatVM = newVM
            vm = newVM
        }
        await vm.bootstrap(repo: repo)
    }

    // MARK: - 摘要段

    @ViewBuilder
    private var summarySection: some View {
        if let vm = insightVM {
            VStack(alignment: .leading, spacing: 0) {
                summaryHeader(vm: vm)

                // ScrollViewReader 内嵌 ScrollView，让流式 token 进来时能 `scrollTo`
                // 底部锚点（dong4j 优化 1：现在像 ChatGPT 一样实时滚字）。
                //
                // 2026-06-15 dong4j 优化：加入「跟随尾部」机制——用户主动上滚后
                // 自动停止跟随，滚回底部后自动恢复。具体见
                // `Starcat/Shared/Components/ScrollFollowTail.swift` 的设计注释。
                //
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                if let error = vm.errorMessage {
                                    errorBanner(message: error)
                                }

                                // Y4：代码上下文降级 banner——只在 generate 路径（非 load 缓存路径）显示。
                                // 与 errorBanner 风格区分：errorBanner 是错误红色，本 banner 是
                                // 信息黄色（系统 .yellow 圆点 + 提示文案），让用户知道"虽然摘要生成了，
                                // 但这次没用上代码内容"。
                                if let reason = vm.contextDegradationReason {
                                    contextDegradationBanner(reason)
                                }

                                // Y9.3（2026-06-14 dong4j 反馈）：AnySearch 外部上下文降级 banner。
                                // 与代码上下文降级 banner 并行存在但相互正交，两路可同时显示。
                                // 用户开了 AnySearch + AI 子开关后，若上游 502 / 网络异常 / Key 失效 /
                                // 配额用完 / 限流 / 能力未启用，本 banner 给出对应分类的提示文案，避免
                                // 静默降级让用户疑惑"我都开了为什么没注入"。
                                if let reason = vm.externalContextDegradationReason {
                                    externalContextDegradationBanner(reason)
                                }

                                if vm.isLoading {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        Text("ai.assistant.summary.loadingCache")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } else if vm.isGenerating, vm.phase == .preparingContext {
                                    // Y1：摘要生成首阶段 -- RepoContextPacker 正在打包代码上下文。
                                    // 此时 streamingSummaryText 还是空字符串（service 还没收到 LLM
                                    // 的第一个 delta），需要单独 UI 提示用户"在做事，别关窗口"。
                                    preparingContextPlaceholder()
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
                                    .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                                        summaryTail.updateBottomVisibility(isVisible)
                                    }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .onScrollPhaseChange { _, newPhase in
                            summaryTail.updatePhase(newPhase)
                        }
                        .onChange(of: vm.streamingSummaryText ?? "") { _, newValue in
                            guard !newValue.isEmpty, summaryTail.isFollowing else { return }
                            proxy.scrollTo(Self.summaryBottomAnchorID, anchor: .bottom)
                        }
                        .onChange(of: vm.insight?.summaryMarkdown ?? "") { _, _ in
                            guard summaryTail.isFollowing else { return }
                            proxy.scrollTo(Self.summaryBottomAnchorID, anchor: .bottom)
                        }

                    }
                }
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("ai.assistant.summary.initializing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static let summaryBottomAnchorID = "summary-bottom-anchor"

    private func summaryHeader(vm: RepoAIInsightViewModel) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Label("ai.assistant.summary.title", systemImage: "sparkles")
                .font(.headline)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.primary)

            Spacer()

            if let insight = vm.insight, !vm.isGenerating {
                copyButton(insight: insight)

                // Y6（2026-06-13）：右上角原"重新生成"单按钮改为 ellipsis.circle Menu，
                // 让"在 Finder 中显示代码上下文"找得到地方挂。
                //
                // Menu 项：
                //   1. 重新生成：与历史按钮等价；
                //   2. 在 Finder 中显示上下文：当 insight.contextMetadata 非 nil 才出现
                //      （README-only 路径下没意义）；点击调 RepoContextStorage.shared.revealProject。
                Menu {
                    Button {
                        Task { await vm.generate(repo: repo, includeTags: starredAtOpen == true) }
                    } label: {
                        Label("ai.assistant.summary.regenerate", systemImage: "arrow.clockwise")
                    }

                    if insight.contextMetadata != nil {
                        Divider()
                        Button {
                            revealContextInFinder()
                        } label: {
                            Label("ai.assistant.summary.menu.revealContext", systemImage: "folder")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .focusEffectDisabled()
                .help("ai.assistant.summary.menu.help")
            } else if vm.isGenerating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// Y6：从右上角 Menu 触发，在 Finder 选中本仓库的 `context.xml`。
    ///
    /// 走 `RepoContextStorage.shared`（与 StorageSettingsTab 同款 security scope 模式）。
    /// 找不到 stored project（被外部删了 / bookmark 失效）时静默吞错——这只是个"便捷
    /// 跳转"，失败不应该弹 alert 打扰用户。
    private func revealContextInFinder() {
        let storage = RepoContextStorage.shared
        guard let project = try? storage.existingProject(owner: repo.owner, repo: repo.name) else {
            return
        }
        try? storage.revealProject(project)
    }

    /// 复制按钮（含点击反馈，HOM-150 dong4j 优化 2）。
    ///
    /// 直接复用 `CopyFeedbackButton`，与气泡复制按钮 / 对话底部"复制全部"同源；
    /// 内容只取摘要 Markdown（`summaryMarkdown ?? summary`），不带对话 / 推荐
    /// 标签，与 HOM-150 验收要求一致。
    private func copyButton(insight: RepoAIInsight) -> some View {
        CopyFeedbackButton(
            providesContent: { insight.summaryMarkdown ?? insight.summary },
            tooltip: "ai.assistant.summary.copy.tooltip"
        ) { didCopy in
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .foregroundStyle(didCopy ? Color.green : Color.primary)
                .contentTransition(.symbolEffect(.replace))
        }
    }

    @ViewBuilder
    private func emptySummaryState(vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ai.assistant.summary.empty.title")
                .font(.subheadline.weight(.semibold))
            Text("ai.assistant.summary.empty.description")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                // R-01 §3.2.7 Step 8：includeTags 由窗口打开瞬间冻结的 star 状态决定。
                Task { await vm.generate(repo: repo, includeTags: starredAtOpen == true) }
            } label: {
                if vm.isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Label("ai.assistant.summary.generate", systemImage: "sparkles")
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
                Text("ai.assistant.summary.streaming")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            RepoAISummaryMarkdownView(markdown: text)
        }
    }

    /// Y1：RepoContextPacker 打包阶段的"准备中"占位。
    ///
    /// 与 `streamingSummary` 视觉上一致（同款 spinner + caption），但文案区分：
    ///   - streaming：用户已经看到 LLM 在吐字了 → caption 提示"摘要正在生成"
    ///   - preparingContext：没有任何文字输出，但后台 packer 正在工作 → caption 提示
    ///     "正在分析仓库代码结构"，避免用户以为 App 卡死
    private func preparingContextPlaceholder() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("ai.assistant.summary.preparingContext")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("ai.assistant.summary.preparingContext.caption")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func insightContent(_ insight: RepoAIInsight, vm: RepoAIInsightViewModel) -> some View {
        // Y9（2026-06-14，决议 D=d2）：用户翻完快捷菜单 / Settings 开关后，已展示的
        // insight 用的可能不是当前 settings 的物料；显示克制提示让用户自行决定是否
        // 重新生成（不自动作废 / 不自动 regenerate，遵循"AI 保守"原则）。
        if isInsightStaleAgainstCurrentSettings(insight: insight, hasDegradation: vm.contextDegradationReason != nil) {
            staleSettingsBanner(vm: vm)
        }

        RepoAISummaryMarkdownView(markdown: insight.summaryMarkdown ?? insight.summary)

        // R-01 §3.2.7 Step 8：未 star 时**不渲染**标签段（即便 insight.suggestedTags
        // 来自历史缓存有内容，也按窗口打开瞬间冻结的 star 状态决定，避免奇怪的"未
        // star 却能应用标签"逻辑漏洞）。已 star 才渲染，保持对历史摘要缓存兼容。
        if starredAtOpen == true, !insight.suggestedTags.isEmpty {
            Divider()
            tagSuggestionsBlock(insight.suggestedTags, vm: vm)
        }

        if starredAtOpen == true, let tagError = vm.tagErrorMessage {
            errorBanner(
                message: String(
                    format: String(localized: "ai.assistant.tags.parseErrorFormat"),
                    tagError
                )
            )
        }

        footer(insight)
    }

    /// Y9.1（2026-06-14）：判定当前展示的 insight 是否与"用户当前 settings 想要的物料"
    /// 不一致——基于 insight 持久化的 `generationContextSettings` 快照精准判定。
    ///
    /// **演进背景**：Y9 初版用 `contextMetadata != nil` / `externalContextMarkdown != nil`
    /// 反推"生成时配置"，但这种间接推断不可靠——`contextMetadata == nil` 既可能是
    /// 用户当时关了开关，也可能是当时下载失败降级。用户反馈"什么都没动每次都提示设置
    /// 已变更"（dong4j 2026-06-14）即由此引发。
    ///
    /// **当前算法（Y9.1）**：
    ///   1. **缺快照（老 insight）**：`generationContextSettings == nil` → 直接返回 false
    ///      不报 stale。这让所有 Y9.1 之前生成的 insight 自动豁免本次新加的判定。
    ///   2. **代码维度**：`snap.codeContextEnabled != settings.aiRepoContextEnabled`
    ///      - 用户翻了代码上下文开关 → 报 stale；
    ///   3. **外网维度**：`snap.externalContextAllowed != currentExternalAllowed`
    ///      - 用户翻了 anysearch / external context / 私仓允许 任一开关 → 报 stale；
    ///
    /// `hasDegradation` 参数保留但**不再使用**（快照机制下，降级路径会让快照如实记录
    /// 当时的"用户意图 = 想要代码"，但 insight.contextMetadata 仍为 nil；这是预期行为，
    /// 不参与 stale 判定。降级 banner 由 `vm.contextDegradationReason` 单独负责显示）。
    private func isInsightStaleAgainstCurrentSettings(
        insight: RepoAIInsight,
        hasDegradation _: Bool
    ) -> Bool {
        guard let snap = insight.generationContextSettings else {
            // 老 insight 没快照：保守不报，避免误报。下次用户主动 regenerate 后会写入快照。
            return false
        }

        if snap.codeContextEnabled != settings.aiRepoContextEnabled {
            return true
        }

        let currentExternalAllowed = AnySearchContextProvider.allowsExternalContext(
            repoIsPrivate: repo.isPrivate,
            enabled: settings.anySearchEnabled && settings.aiExternalContextEnabled,
            allowPrivate: settings.aiExternalContextAllowPrivateRepos
        )
        if snap.externalContextAllowed != currentExternalAllowed {
            return true
        }

        return false
    }

    /// Y9：「设置已变更」提示行 + [重新生成] 按钮。
    ///
    /// 视觉风格（Y9.2 dong4j 2026-06-14 反馈玻璃态适配）：
    ///   - icon 用 `.yellow` 标识"信息提示"色彩；
    ///   - 文字 `.primary` 跟随主题黑/白，避免浅色主题下黄字对比度不足；
    ///   - 背景从 `yellow.opacity(0.10)` 提到 `0.18` —— 在 NSVisualEffectView popover 玻璃态
    ///     下 0.10 几乎被材质吃掉看不出黄色块；
    ///   - 加 `strokeBorder(yellow.opacity(0.35))` 让 banner 在玻璃态下有清晰轮廓。
    ///
    /// 按钮调用与摘要面板右上角 Menu 同款 generate(includeTags:)，include flags 由当前
    /// starredAtOpen 决定，与既有路径保持一致。
    private func staleSettingsBanner(vm: RepoAIInsightViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.yellow)
            Text("ai.assistant.summary.staleSettings.message")
                .font(.caption)
            Spacer(minLength: 8)
            Button {
                Task { await vm.generate(repo: repo, includeTags: starredAtOpen == true) }
            } label: {
                Text("ai.assistant.summary.staleSettings.regenerate")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .disabled(vm.isGenerating)
        }
        .foregroundStyle(.primary)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
                )
        )
    }

    /// 推荐标签块。视觉上比对话气泡克制：
    /// "tag name + reason + 置信度 + 应用按钮"，与旧详情页 AI Tab 的样式对齐。
    ///
    /// Y9.2（2026-06-14 dong4j 反馈玻璃态主题适配）：
    ///   - 整体加 `.regularMaterial` 卡片容器 + 细描边，让标签块从 NSVisualEffectView popover
    ///     玻璃态背景里"浮起来"，原方案直接堆在 ScrollView 内容区里文字飘在材质上看着空；
    ///   - 单条 tag 行之间加 `Divider().opacity(0.35)`，弱化但保留分隔感；
    ///   - `tag.reason` 字号改 `.caption2`，跟"tag name"层级拉开但仍维持 `.secondary`；
    ///   - 应用按钮统一用 `.bordered` controlSize=`.small`，让 macOS 自动跟随主题渲染
    ///     （原默认风格在玻璃态下会渲染成纯白底/纯黑字与背景脱节，与"复制完整对话"按钮
    ///     是同款 bug，一并修掉）。
    private func tagSuggestionsBlock(_ tags: [AITagSuggestion], vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("ai.assistant.tags.title")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("ai.assistant.tags.applyAll") {
                    Task { await vm.applyAllTags(repo: repo) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(tags.allSatisfy { vm.appliedTagNames.contains($0.name.trimmingNormalized) })
            }

            ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                if index > 0 {
                    Divider().opacity(0.35)
                }
                let isApplied = vm.appliedTagNames.contains(tag.name.trimmingNormalized)
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tag.name)
                            .font(.body.weight(.medium))
                        Text(tag.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(Int((max(0, min(tag.confidence, 1)) * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    // tag.name / tag.reason 是后端 / 模型返回的原始字符串，无需本地化
                    // （内容本身就是 i18n-中立的、给当前用户语言生成的）。
                    Button(isApplied ? "ai.assistant.tags.applied" : "ai.assistant.tags.apply") {
                        Task { await vm.applyTag(tag, repo: repo) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isApplied)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    /// Y2（2026-06-13）：footer 两行结构。
    ///   - 第一行：由 X 模型生成 · 时间（旧版独占）
    ///   - 第二行：基于 commit abc1234 (4280 tokens · 38 files)
    ///     仅当 insight.contextMetadata 非 nil 时出现；不存在的旧缓存 insight 上行兼容。
    ///
    /// **2026-06-14 D-31 follow-up**：颜色从 `.tertiary` 升到 `.secondary`。
    /// `.tertiary` 在浅色主题下对比度只有 ~1.5:1，肉眼几乎"灰糊"在白底上；
    /// 与 D-31 空状态组件统一对齐到 `.secondary`（4.5:1+ 满足 WCAG AA）。
    private func footer(_ insight: RepoAIInsight) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                // "由 X 生成 · 时间" 含两个动态占位，走 String(format:) + 本地化模板，
                // 比直接 `Text("由 \(...) 生成")` 让 Xcode 自动抽 key 更可控、key 名也
                // 不会被改文案时连带破坏（key 名是稳定 identifier）。
                Text(
                    String(
                        format: String(localized: "ai.assistant.summary.footer.generatedByFormat"),
                        insight.model,
                        formattedDate(insight.generatedAt)
                    )
                )
            }

            if let meta = insight.contextMetadata {
                contextMetaFooterRow(meta)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// Y2：代码上下文元信息行。展示 "基于 <commit-7位> (N tokens · M files)"。
    ///
    /// **2026-06-15 dong4j**：commit short sha 改为可点击链接，点击跳转 GitHub commit 详情页。
    ///
    /// 设计选择：
    /// - **i18n 拆三段** 而非 `String(format:)` 整段拼接 —— 因为中间要嵌入交互式 view（不是文本），
    ///   无法走 `%@` 占位符。拆成 prefix（"基于"）+ `CommitHashLink`（short sha）+ statsFormat
    ///   （"(N tokens · M files)"）三个 SwiftUI 元素，HStack 拼装。这种拆法在多语言里仍然成立：
    ///   英文 "Based on <link> (N tokens · M files)" 与中文 "基于 <link>（N tokens · M files）"
    ///   语法结构相同（前缀 + 链接 + 括号统计段），翻译方不会出现"语序错位 → 词组拆碎"问题。
    /// - **抽出 `CommitHashLink` 子 view** —— SwiftUI `Link(destination:label:)` closure 形式
    ///   **绕过了** macOS 内置 `_LinkLabel` 私有装饰链（hover 下划线 / 手型指针 cursor），只剩
    ///   tint 着色和点击行为。10:53 dong4j 反馈"hover 没下划线 / 没手型 / 没 tooltip"就是这个
    ///   坑。修复路线 = 保留 `Link`（让点击 + VoiceOver + 键盘导航免费）+ 子 view 持有 `@State
    ///   isHovered` 手动加 `.underline(isHovered)` + `.pointerStyle(.link)` (macOS 15+) 显式手型，
    ///   tooltip 通过 `.help(...)` 自然继承 hover 状态。
    /// - **URL 用 full sha 而非 commitShaShort** —— `RepoAIInsightContextMeta.commitSha` 是 40 字符
    ///   full sha，传给 GitHub 不会有碰撞风险也不会触发 302 重定向。展示层用 short（commitShaShort）
    ///   只是为了视觉简洁。
    private func contextMetaFooterRow(_ meta: RepoAIInsightContextMeta) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text.magnifyingglass")
            Text("ai.assistant.summary.footer.contextMeta.prefix")
            CommitHashLink(
                shortSha: meta.commitShaShort,
                destination: GitHubURLs.repoCommit(
                    owner: repo.owner,
                    repo: repo.name,
                    sha: meta.commitSha
                )
            )
            Text(
                String(
                    format: String(localized: "ai.assistant.summary.footer.contextMeta.statsFormat"),
                    meta.actualTokens,
                    meta.totalFiles
                )
            )
        }
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
    /// - selection 只做 0.12s opacity 过渡，不再插值两棵 Markdown 树的高度；
    /// - bar 自带细分隔线（`.bar` 材质 + Divider 上下），视觉上是上下两段
    ///   面板的边界，无需额外加 `Divider()`。
    private var panelToggleBar: some View {
        HStack(spacing: 0) {
            Picker("", selection: panelModeBinding) {
                Label("ai.assistant.toggle.summary", systemImage: "sparkles").tag(AIPanelMode.summary)
                Label("ai.assistant.toggle.chat", systemImage: "bubble.left.and.bubble.right").tag(AIPanelMode.chat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 限宽避免在大窗口下 segmented 被拉成超长条带；居中通过外层
            // `.frame(maxWidth: .infinity)` + Picker 自身有限宽实现。
            .frame(maxWidth: 280)
            .help("ai.assistant.toggle.help")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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
            VStack(spacing: 0) {
                chatSessionToolbar(chat: chat)
                Divider().opacity(0.5)
                chatScrollArea(chat: chat)
            }
        } else {
            Color.clear
        }
    }

    /// HOM-70：对话面板右上角 session 控制栏。
    ///
    /// 左侧：当前 session 标题（空 session 显示「新对话」），溢出截断。
    /// 右侧：「+ 新建」、「session 列表」（popover）、「⋯ 菜单」（清当前 repo / 删本 session）。
    /// 全部按钮严格遵守 `.buttonStyle(.plain) + .focusEffectDisabled()` 规则。
    private func chatSessionToolbar(chat: RepoAIChatViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(verbatim: displayTitle(for: chat))
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Button {
                chat.startNewSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("ai.assistant.chat.session.new.help")
            .disabled(chat.isSending)

            Button {
                isSessionListPresented = true
                Task { await chat.refreshSessions(repo: repo) }
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("ai.assistant.chat.session.list.help")
            .popover(isPresented: $isSessionListPresented, arrowEdge: .top) {
                sessionListPopover(chat: chat)
            }

            Menu {
                Button(role: .destructive) {
                    pendingClearCurrentRepoConfirm = true
                } label: {
                    Label("ai.assistant.chat.session.clearCurrentRepo", systemImage: "trash")
                }
                .disabled(chat.sessions.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22, height: 22)
            .focusEffectDisabled()
            .help("ai.assistant.chat.session.menu.help")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .confirmationDialog(
            String(localized: "ai.assistant.chat.session.clearCurrentRepo.confirm"),
            isPresented: $pendingClearCurrentRepoConfirm,
            titleVisibility: .visible
        ) {
            Button("general.clear", role: .destructive) {
                Task { await chat.deleteAllForCurrentRepo(repo: repo) }
            }
            Button("general.cancel", role: .cancel) { }
        } message: {
            Text("ai.assistant.chat.session.clearCurrentRepo.message")
        }
    }

    /// session 列表 popover。
    ///
    /// 极简列表：title + 时间 + 消息数；当前 session 用蓝色 chevron 标记。
    /// 点击一项 → 切换；尾部 swipe / 单项删除按钮 → 删 session。
    private func sessionListPopover(chat: RepoAIChatViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ai.assistant.chat.session.list.title")
                    .font(.headline)
                Spacer()
                Button {
                    chat.startNewSession()
                    isSessionListPresented = false
                } label: {
                    Label("ai.assistant.chat.session.new", systemImage: "plus")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
                .disabled(chat.isSending)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)
            Divider()
            if chat.sessions.isEmpty {
                Text("ai.assistant.chat.session.list.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(chat.sessions) { summary in
                            sessionListRow(summary: summary, chat: chat)
                            if summary.id != chat.sessions.last?.id {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }

    private func sessionListRow(summary: ChatSessionSummary, chat: RepoAIChatViewModel) -> some View {
        let isCurrent = summary.id == chat.currentSessionId
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: summary.title.isEmpty
                     ? String(localized: "ai.assistant.chat.session.untitled")
                     : summary.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: formattedSessionMeta(summary))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                Task { await chat.deleteSession(sessionId: summary.id, repo: repo) }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("ai.assistant.chat.session.delete.help")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await chat.switchSession(to: summary.id, repo: repo)
                isSessionListPresented = false
            }
        }
        .background(isCurrent ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    /// 把切换动画限制在 `panelMode` 赋值事务内，避免根视图上的隐式 animation
    /// 把同一帧其它状态变化也纳入动画计算。
    private var panelModeBinding: Binding<AIPanelMode> {
        Binding(
            get: { panelMode },
            set: { newMode in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                    panelMode = newMode
                }
            }
        )
    }

    private func displayTitle(for chat: RepoAIChatViewModel) -> String {
        if let current = chat.sessions.first(where: { $0.id == chat.currentSessionId }), !current.title.isEmpty {
            return current.title
        }
        return String(localized: "ai.assistant.chat.session.untitled")
    }

    private func formattedSessionMeta(_ summary: ChatSessionSummary) -> String {
        let relative = summary.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return String(
            format: String(localized: "ai.assistant.chat.session.list.metaFormat"),
            summary.messageCount,
            relative
        )
    }

    @ViewBuilder
    private func chatScrollArea(chat: RepoAIChatViewModel) -> some View {
        ScrollViewReader { proxy in
                // 2026-06-15 dong4j 优化：与摘要段同源接入 ScrollTailController。
                //
                // 对话段比摘要段多一件事：还要监听顶部下拉 overscroll（≤ -60pt）
                // 来切回摘要面板。两个滚动驱动行为共享同一份 phase / geometry：
                //   - `chatTail.lastPhase` 同时给"跟随"判定 + "overscroll"门控用；
                //   - `onScrollGeometryChange` 只读取顶部 overscroll 所需的 offsetY；
                //   - 是否到底由底部 sentinel 可见性独立判断，不再读 content geometry。
                ScrollView {
                        // 2026-06-15 dong4j 反馈：历史对话滚动像按消息分块跳跃。
                        // AI 回复是高度差异很大的 Markdown；LazyVStack 会在长消息进入
                        // 可视区时才实例化并重新测量 cell，随后修正此前估算的 content
                        // offset，表现为跨消息边界时整块跳动。对话受模型上下文限制，
                        // 单 session 消息规模可控，因此这里主动换取一次性准确布局，
                        // 使用 VStack 保证连续滚动，不做惰性高度估算。
                        VStack(alignment: .leading, spacing: 14) {
                            // HOM-70 v2：「承接自上一对话」banner —— 放在 ScrollView 内部最顶部，
                            // 跟随滚动（聊久了自动滚出视野不占屏）；空 session（刚承接还没消息）
                            // 也显示，让用户立刻知道"这是承接自上一对话的新 session"。
                            if shouldShowCarryOverBanner(chat: chat) {
                                carriedOverSummaryBanner(chat: chat)
                                    .padding(.horizontal, 16)
                            }

                            if chat.messages.isEmpty {
                                chatEmptyState
                                    .padding(.top, 60)
                            } else {
                                if chat.hasEarlierMessages {
                                    loadEarlierMessagesButton(chat: chat)
                                        .padding(.horizontal, 16)
                                }

                                ForEach(chat.messages) { message in
                                    AIChatBubble(
                                        message: message,
                                        onEditUserMessage: editUserMessage
                                    )
                                    .equatable()
                                }

                                if let streaming = chat.streamingMessage {
                                    AIChatBubble(
                                        message: streaming,
                                        onEditUserMessage: editUserMessage
                                    )
                                    .equatable()
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
                                    .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                                        chatTail.updateBottomVisibility(isVisible)
                                    }
                            }
                        }
                        .padding(.vertical, 16)
                    }
                    .background(Color.clear)
                    .onChange(of: chat.messages.count) { _, _ in
                        scheduleChatTailScroll(proxy: proxy)
                    }
                    .onChange(of: chat.streamingMessage?.content ?? "") { _, _ in
                        scheduleChatTailScroll(proxy: proxy)
                    }
                    .onChange(of: chat.isSending) { _, isSending in
                        // 流式结束后会插入“复制完整对话”行，它位于 sentinel 之前；
                        // 高度变化也要补一次尾部对齐，否则视觉上会停在按钮上方。
                        guard !isSending else { return }
                        scheduleChatTailScroll(proxy: proxy)
                    }
                    // dong4j 2026-06-04 15:30 重设计：识别"顶部下拉 overscroll"切回摘要面板。
                    // dong4j 2026-06-15 复用：同一份 phase / geometry 同时给"跟随尾部"用。
                    .onScrollPhaseChange { _, newPhase in
                        chatTail.updatePhase(newPhase)
                    }
                    .onScrollGeometryChange(for: ScrollFollowTailMetrics.self) { geo in
                        ScrollFollowTailMetrics(offsetY: geo.contentOffset.y)
                    } action: { _, new in
                        handleChatOverscroll(
                            offsetY: new.offsetY,
                            hasMessages: !chat.messages.isEmpty || chat.streamingMessage != nil
                        )
                    }

            if chat.isContextOverflow {
                contextOverflowBanner(chat: chat)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            } else if let err = chat.errorMessage {
                chatErrorBanner(message: err) {
                    chat.dismissError()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    /// HOM-70 v2：是否应该在 chatScrollArea 顶部展示「承接自上一对话」banner。
    ///
    /// 三个条件全满足：① 当前 session 有非空 `carriedOverSummary` 字段；
    /// ② 当前 session id 存在；③ 用户没在本 session 主动 dismiss 过 banner。
    /// 切到无承接的 session / 用户已 dismiss 的 session → 不显示。
    private func shouldShowCarryOverBanner(chat: RepoAIChatViewModel) -> Bool {
        guard let summary = chat.currentCarriedOverSummary, !summary.isEmpty,
              let sid = chat.currentSessionId else {
            return false
        }
        return !carryOverDismissedSessions.contains(sid)
    }

    /// 分页加载更早历史。
    ///
    /// 首屏只渲染最近 2 条消息，避免大量 Markdown 气泡拖慢 AI 窗口和输入框。用户确实
    /// 要回看历史时再按 20 条一个 chunk 向前加载；按钮放在滚动内容顶部，语义上等价于
    /// 常见聊天 App 的“加载更早消息”。
    private func loadEarlierMessagesButton(chat: RepoAIChatViewModel) -> some View {
        HStack {
            Spacer()
            Button {
                Task { await chat.loadEarlierMessages(repo: repo) }
            } label: {
                HStack(spacing: 6) {
                    if chat.isLoadingEarlierMessages {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.up.circle")
                    }
                    Text(chat.isLoadingEarlierMessages
                         ? "ai.assistant.chat.history.loadingEarlier"
                         : "ai.assistant.chat.history.loadEarlier")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(chat.isLoadingEarlierMessages)
            .help("ai.assistant.chat.history.loadEarlier.help")
            Spacer()
        }
    }

    /// HOM-70 v2：「承接自上一对话」banner —— 用户点上下文溢出 banner 的「新建并承接」
    /// 后，新 session 的 `currentCarriedOverSummary` 拿到上一对话末 6 条 turn 的 markdown
    /// 摘要。本 banner 让用户**看到**承接段（视觉），与 AI 通过 system prompt 的
    /// `{previousSessionCarryOver}` section **读到**承接段（prompt）相互独立。
    ///
    /// 视觉：紫色 `arrow.uturn.backward.circle.fill` icon + 标题"承接自上一对话" +
    /// 默认 3 行 markdown 预览（lineLimit:3 + .textSelection 让用户能复制）+
    /// 展开/收起按钮（按 session 跟踪独立状态）+ 右上 ✕ dismiss（仅翻 view 端 @State
    /// 不动 VM 数据，AI 仍能从 prompt 看到承接段）。
    ///
    /// 紫色与 sparkles AI icon 同色系，与 contextOverflowBanner 黄色（系统警告色）/
    /// chatErrorBanner 红色（错误色）形成语义区分：紫色 = "AI 元信息"。
    private func carriedOverSummaryBanner(chat: RepoAIChatViewModel) -> some View {
        let summaryText = chat.currentCarriedOverSummary ?? ""
        let sid = chat.currentSessionId
        let isExpanded = sid.map { carryOverExpandedSessions.contains($0) } ?? false

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.title3)
                .foregroundStyle(.purple)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("ai.assistant.chat.carryOver.title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    guard let sid else { return }
                    if isExpanded {
                        carryOverExpandedSessions.remove(sid)
                    } else {
                        carryOverExpandedSessions.insert(sid)
                    }
                } label: {
                    Text(isExpanded
                         ? "ai.assistant.chat.carryOver.collapse"
                         : "ai.assistant.chat.carryOver.expand")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.borderless)
                .focusEffectDisabled()
            }

            Spacer(minLength: 4)

            Button {
                if let sid {
                    carryOverDismissedSessions.insert(sid)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("ai.assistant.chat.carryOver.dismiss.help")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.purple.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.purple.opacity(0.30), lineWidth: 0.5)
        )
    }

    /// HOM-70：上下文溢出 banner。
    ///
    /// 触发条件：`chat.isContextOverflow == true`（chatStream 错误描述命中
    /// `RepoAIChatViewModel.looksLikeContextOverflow` 的关键字集）。
    /// 行为：左侧文案解释"上下文已满"，右侧两个按钮：
    ///   - "新建并承接"：调 `chat.startNewSessionAfterOverflow(repo:)`，把末尾 6 条
    ///     摘要塞进新 session 的 carriedOverSummary；
    ///   - 关闭：仅 dismiss banner，不创建新 session。
    /// 视觉沿用 staleSettingsBanner / contextDegradationBanner 同款黄色 info 系。
    private func contextOverflowBanner(chat: RepoAIChatViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("ai.assistant.chat.contextOverflow.message")
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Button {
                Task { await chat.startNewSessionAfterOverflow(repo: repo) }
            } label: {
                Text("ai.assistant.chat.contextOverflow.newWithCarry")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            .focusEffectDisabled()
            .disabled(chat.isSending)
            Button {
                chat.dismissContextOverflow()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
                )
        )
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

        // 2026-06-15：phase 来源从原 `lastChatScrollPhase` 切到 `chatTail.lastPhase`，
        // 跟「跟随尾部」状态机共享同一份 phase tracking，避免一个 view 上挂两个
        // onScrollPhaseChange + 两份独立 state 漂移。门控语义不变。
        switch chatTail.lastPhase {
        case .interacting, .decelerating, .tracking:
            break
        case .idle, .animating:
            return
        @unknown default:
            return
        }

        guard offsetY < overscrollExpandThreshold else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
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
    ///
    /// 2026-06-15 13:12 dong4j 反馈"不要圆形边框了,简单点即可"：去掉 capsule fill
    /// 和 strokeBorder,只保留 icon + 文字 + hover 反馈。原方案的 `.thinMaterial`
    /// capsule + 0.18 描边在玻璃态背景上虽然可读,但视觉权重偏重,与"次级操作"
    /// 定位不符。简化为"裸 icon + 文字"是 ChatGPT / Claude 等 AI 对话框底部
    /// 工具行的主流做法。
    /// - icon 与 user/assistant 气泡复制按钮同款（13pt medium + 14×14 frame）,杜绝
    ///   切换抖动；
    /// - 文字保持 `.caption`,与"次级辅助操作"层级一致；
    /// - `pressableHover` 保留作为唯一的"我可点击"暗示,鼠标悬停 + 按下时有微动反馈。
    private func conversationCopyRow(chat: RepoAIChatViewModel) -> some View {
        HStack {
            Spacer()
            CopyFeedbackButton(
                providesContent: { chat.markdownExport(repo: repo, userLogin: currentUserLogin) },
                tooltip: "ai.assistant.chat.copyAll.tooltip"
            ) { didCopy in
                HStack(spacing: 6) {
                    // 13:46 dong4j 反馈"复制图标要和字体大小匹配"：原 `system(size: 13)`
                    // 让 icon 比文字 `.caption`(~12pt) 大一档。统一用 `.font(.caption)`
                    // 让 SwiftUI 系统级保证 icon 与文字字号一致；frame 14×14 保留作为
                    // 防抖容器(SF Symbol 内在尺寸约 ~14pt,容器紧贴不留多余白)。
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.caption)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 14, height: 14)
                    Text(didCopy ? "ai.assistant.copy.copied" : "ai.assistant.chat.copyAll.label")
                        .font(.caption)
                }
                .foregroundStyle(didCopy ? Color.green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .pressableHover(opacity: 0.65, scale: 1.03)
            }
            Spacer()
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var chatEmptyState: some View {
        EmptyStateView(
            systemImage: "bubble.left.and.bubble.right",
            title: "ai.assistant.chat.empty.title",
            subtitle: "ai.assistant.chat.empty.description",
            subtitleHorizontalPadding: 40
        )
        .frame(maxWidth: .infinity)
    }

    /// 把历史用户问题回填到底部输入框并聚焦，用户确认后再发送。
    private func editUserMessage(_ content: String) {
        pendingChatDraftReplacement = content
        Task { @MainActor in
            // 等 binding 先把文本提交给 TextField，再请求焦点，避免焦点切换抢在内容更新前。
            await Task.yield()
            isChatInputFocused = true
        }
    }

    /// 合并同一主线程周期内的尾部滚动请求。
    ///
    /// 流式 Markdown 每次提交会同时改变文本高度和 sentinel 位置；直接在每个
    /// onChange 中 scrollTo 会堆积程序化滚动。这里最多保留一个待执行请求，且自动
    /// 跟随不使用动画，用户一旦开始滚动，执行前的二次 guard 会立即取消拉底。
    private func scheduleChatTailScroll(proxy: ScrollViewProxy) {
        guard chatTail.isFollowing, !isChatTailScrollScheduled else { return }
        isChatTailScrollScheduled = true

        Task { @MainActor in
            await Task.yield()
            defer { isChatTailScrollScheduled = false }
            guard chatTail.isFollowing else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.chatBottomAnchorID, anchor: .bottom)
            }
        }
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
    private func sendChatMessage(_ text: String) {
        let repoSnapshot = repo
        Task {
            await prepareChatIfNeeded()
            await chatVM?.sendMessage(text, repo: repoSnapshot)
        }
        if panelMode != .chat {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                panelMode = .chat
            }
        }
    }

    /// 2026-06-15 13:12 dong4j 反馈"AI 输出时发送按钮变成终止按钮"：用户在流式
    /// 期间点击 stop,vm 内 sendTask cancel → 已累积的 partial 被当作正常完成的
    /// 助手消息保存（ChatGPT / Claude 同款）。
    ///
    /// 本函数只做透传,不做任何"是否真的在流式"判定 —— AIChatInputView 自身根据
    /// `isSending` 切换图标与点击语义,只有处于流式态时按钮才会触发这条路径,
    /// 重复防护交给 vm 的 `cancelStreaming()`（sendTask 为 nil 时调 cancel 安全）。
    private func cancelChatStreaming() {
        chatVM?.cancelStreaming()
    }

    // MARK: - 错误条

    /// Y9.2 玻璃态主题适配：icon 保持 `.orange` 当色彩标识，文字 `.primary` 跟随主题；
    /// 背景 0.12 → 0.18 + strokeBorder 让 banner 在 popover 玻璃态背景下有清晰轮廓。
    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
    }

    /// Y4：代码上下文降级 banner。
    ///
    /// 视觉上比 errorBanner 克制——这不是错误（摘要照常生成了），只是告诉用户"这次
    /// 没用上代码内容"。
    ///
    /// Y9.2（2026-06-14 dong4j 反馈玻璃态主题适配）：
    ///   - 原方案整段 `foregroundStyle(.yellow)` 让文字在浅色 / 玻璃态下都成淡黄看不清；
    ///   - 改为 icon 留 `.yellow` 当色彩标识，文字用 `.primary` 跟随主题；
    ///   - 背景 0.10 → 0.18 + strokeBorder 让 banner 在玻璃态下有清晰轮廓
    ///     （与 staleSettingsBanner 保持同款风格）。
    /// 文案 5 case 全部走 i18n key（在 Y4 一并补 Localizable.xcstrings）。
    private func contextDegradationBanner(_ reason: ContextDegradationReason) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.yellow)
            Text(LocalizedStringKey(reason.bannerMessageKey))
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
                )
        )
    }

    /// Y9.3（2026-06-14 dong4j 反馈）：AnySearch 外部上下文降级 banner。
    ///
    /// 与 contextDegradationBanner 共享 Y9.2 玻璃态适配同款视觉（黄色 info 系），
    /// 与 errorBanner 区分（红色错误 ≠ 黄色信息）。两路 banner 可同时显示，给用户
    /// "代码上下文 + 外部网页材料"两个独立维度的反馈。
    ///
    /// 文案策略：7 case 都走 i18n key，UI 层零硬编码（i18n 在 Y9.3 一并补齐）。
    /// 不在 banner 显示具体 statusCode 值（如 502）—— bannerMessageKey 已在中文文案里
    /// 把"上游临时不可用"的语义讲清楚，附加数字反而干扰 glance 阅读。需要细节排查的
    /// 用户可以去 Console.app 看 OSLog（已有诊断 log 链路）。
    private func externalContextDegradationBanner(_ reason: ExternalContextDegradationReason) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.yellow)
            Text(LocalizedStringKey(reason.bannerMessageKey))
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 1)
                )
        )
    }

    /// Y9（2026-06-14，决议 E=e3+）：对话输入框上方的"上下文汇总"状态行。
    ///
    /// 优先级（从高到低，命中即停）：
    ///   1. **降级 banner**：摘要生成时 RepoContextPacker 报错（`vm.contextDegradationReason`
    ///      非 nil）→ 黄色 ⚠ + degradation 文案。这是异常路径的强信号，盖过其他显示。
    ///   2. **3 维汇总**：按当前 settings + cachedInsight 动态拼接「摘要 · 代码 · 外网」
    ///      - 摘要：`vm.insight?.summaryMarkdown` 非空（说明用户至少生成过一次）；
    ///      - 代码：`settings.aiRepoContextEnabled == true` 且 contextMetadata 实际有
    ///        （上次确实 pack 成功 / 还在缓存里）；
    ///      - 外网：settings 当前允许 AnySearch（双开关 AND + 私仓门控）且
    ///        `vm.insight?.externalContextMarkdown` 有缓存。
    ///   3. **三者都为 false**：完全不显示（README-only 是默认状态，无需占位）。
    ///
    /// 为什么混用「settings 当前值」+「cachedInsight 实际有否」：
    ///   - settings 反映"用户当前意图"（即将翻译成 system prompt 的开关）；
    ///   - cachedInsight 反映"对话路径实际能拿到的物料"（决议 B=b2，对话不重新拉
    ///     AnySearch HTTP，只读缓存）。
    ///   - 仅看 settings 会误报（关了 anySearch 但缓存里还有 markdown：实际不会用，
    ///     状态行不该说带）；仅看缓存会漏报（用户开了代码开关但还没生成新摘要：
    ///     下条对话就会带 Code XML，状态行该说带）。
    ///
    /// 当用户在快捷菜单翻完开关 → settings.didSet → @Observable 触发 view 刷新 →
    /// 本行立即更新（无需等 chatVM 异步重算）。
    @ViewBuilder
    private var chatContextStatusRow: some View {
        if let vm = insightVM {
            if let reason = vm.contextDegradationReason {
                degradationStatusRow(reason: reason)
            } else {
                summarizedStatusRow(vm: vm)
            }
        }
    }

    /// 降级 banner（沿用 Y4 / Y8 风格）。
    ///
    /// 2026-06-15 13:31 dong4j 反馈"和上方输入框间距太大"：把 `.vertical 6` 拆成
    /// 不对称的 `top 2 / bottom 6`,与输入框底部 4pt 合计 6pt 紧凑视觉；
    /// 底部 6pt 保留作为窗口底边的呼吸距。`summarizedStatusRow` 同步。
    private func degradationStatusRow(reason: ContextDegradationReason) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(LocalizedStringKey(reason.bannerMessageKey))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 3 维汇总状态行。
    ///
    /// 2026-06-14 视觉对齐 repo 卡片：3 维由"text 拼字串 · 分隔符"改成 3 个独立 pill
    /// （capsule + 图标 + 文字），样式与 `UnifiedRepoRow.RepoCardInlineMetadataBadge`
    /// 完全一致（9pt semibold icon + 10pt semibold monospaced text + 5/2 padding +
    /// `secondary.opacity(0.10)` capsule + secondary 灰色），让"对话窗口下方的状态条"
    /// 与"列表卡片的元数据 pill"风格统一，用户对"灰色小胶囊 = 状态信号"的认知能直接
    /// 迁移。"📎 上下文："prefix 保留——单看 pill 行可能不知道这是干嘛，prefix 给一个
    /// 一秒能读懂的语义锚点。
    @ViewBuilder
    private func summarizedStatusRow(vm: RepoAIInsightViewModel) -> some View {
        let hasSummary = (vm.insight?.summaryMarkdown?.isEmpty == false)
        let hasCode = settings.aiRepoContextEnabled && vm.insight?.contextMetadata != nil
        let externalAllowed = AnySearchContextProvider.allowsExternalContext(
            repoIsPrivate: repo.isPrivate,
            enabled: settings.anySearchEnabled && settings.aiExternalContextEnabled,
            allowPrivate: settings.aiExternalContextAllowPrivateRepos
        )
        let hasExternal = externalAllowed && (vm.insight?.externalContextMarkdown?.isEmpty == false)

        if hasSummary || hasCode || hasExternal {
            HStack(spacing: 6) {
                Image(systemName: "paperclip")
                    .foregroundStyle(.secondary)
                Text("ai.assistant.chat.contextStatus.prefix")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // pill 行——3 个维度按命中条件渲染，缺失维度不占位。pill 之间用 spacing 4
                // （与 RepoCardInlineMetadataBadge 在 repo 卡片底排连排时的间距一致）。
                //
                // 3 色语义化分布（2026-06-14 dong4j 反馈"统一灰底太单调"）：
                //   - 摘要 → 紫色（与 summaryHeader 的 sparkles 同色，项目内 AI 主色）
                //   - 代码 → 蓝色（代码语义经典色 + macOS accent 默认色）
                //   - 外网 → 绿色（globe / 互联网语义）
                // 三色都是 SwiftUI 系统色，在浅 / 深主题下都自适应不需要手写双套色。
                HStack(spacing: 4) {
                    if hasSummary {
                        contextStatusPill(
                            icon: "sparkles",
                            label: "ai.assistant.chat.contextStatus.summary",
                            tint: .purple
                        )
                    }
                    if hasCode {
                        contextStatusPill(
                            icon: "doc.text.magnifyingglass",
                            label: "ai.assistant.chat.contextStatus.code",
                            tint: .blue
                        )
                    }
                    if hasExternal {
                        contextStatusPill(
                            icon: "globe",
                            label: "ai.assistant.chat.contextStatus.external",
                            tint: .green
                        )
                    }
                }
            }
            // 2026-06-15 13:31 dong4j 反馈"和上方输入框间距太大"：拆成不对称的
            // top 2 / bottom 6,与输入框底部 4pt 合计 6pt 紧凑间距；底部 6 保留作为
            // 窗口底边的呼吸距。详见 degradationStatusRow 同款注释。
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 三者都为 false：返回隐含 EmptyView，配合外层 frame(maxHeight: 0) 完全不占位。
    }

    /// 单个 context 维度 pill（沿用 repo 卡片 `RepoCardInlineMetadataBadge` 的尺寸 /
    /// 字号 / padding / capsule 几何，但底色 + 前景从单色灰升级为 `tint` 驱动的彩色
    /// 语义标签）。
    ///
    /// 视觉规格：
    ///   - 9pt semibold icon + 10pt semibold monospaced text；
    ///   - 5pt horizontal / 2pt vertical padding（与 RepoCardInlineMetadataBadge 一致）；
    ///   - 前景（icon + text）= `tint`；
    ///   - 背景 capsule = `tint.opacity(0.15)`（比 banner 的 0.18 略轻，因 pill 面积小、
    ///     高 opacity 会让小 chip 过于刺眼）；
    ///   - `fixedSize(horizontal: true)` 防内容自适应引起布局抖动。
    ///
    /// 2026-06-14 演进：dong4j 反馈"3 个 pill 统一灰底太单调"，从原本的
    /// `Color.secondary.opacity(0.10)` + `.secondary` 前景升级为 tint 驱动的彩色方案。
    /// 不再与 `RepoCardInlineMetadataBadge` 视觉完全一致——repo 卡片底排 pill 是元数据
    /// 列表（语言 / star / fork），用一种灰色避免抢戏；本 chat 状态条 3 项是不同语义维度
    /// （AI 摘要 / 代码上下文 / 外部材料），彩色区分让用户一眼分辨"当前对话带了哪几路
    /// 上下文"。
    ///
    /// 不抽到 `Shared/Components` 共享：本视图局部用 3 次，复制 ~15 行实现成本低于打开
    /// API 边界的维护成本；如果未来还有第 4 个调用方再做一次 surgical 抽提到共享层。
    private func contextStatusPill(
        icon: String,
        label: LocalizedStringKey,
        tint: Color
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background {
            Capsule(style: .continuous)
                .fill(tint.opacity(0.15))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Y9.2 玻璃态主题适配：与 errorBanner 同款风格——背景 0.12 → 0.18 + strokeBorder。
    private func chatErrorBanner(message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.primary)
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
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
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
