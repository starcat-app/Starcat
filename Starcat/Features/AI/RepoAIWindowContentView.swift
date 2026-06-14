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
    /// 摘要面板撑满，对话面板折叠到 0。
    case summary
    /// 对话面板撑满，摘要面板折叠到 0。
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

    @State private var insightVM: RepoAIInsightViewModel?
    @State private var chatVM: RepoAIChatViewModel?

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
            panelHeader

            Divider()

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

            // 对话上下文状态提示（Y8，2026-06-14）：在 chat 输入框上方显示一行
            // 轻量 caption，让用户随时知道本次对话是不是带上了代码上下文。
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
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .animation(.easeInOut(duration: 0.28), value: panelMode)
            }

            Divider()

            AIChatInputView(
                text: chatInputBinding,
                isSending: chatVM?.isSending ?? false,
                onSend: sendChatMessage
            )
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
            await initializeViewModelsIfNeeded()
            await insightVM?.load(repo: repo)
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
                    await homeViewModel?.reloadItems(forceRefresh: true)
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

                            // Y4：代码上下文降级 banner——只在 generate 路径（非 load 缓存路径）显示。
                            // 与 errorBanner 风格区分：errorBanner 是错误红色，本 banner 是
                            // 信息黄色（系统 .yellow 圆点 + 提示文案），让用户知道"虽然摘要生成了，
                            // 但这次没用上代码内容"。
                            if let reason = vm.contextDegradationReason {
                                contextDegradationBanner(reason)
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
                .foregroundStyle(.tertiary)
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

    /// Y9：判定当前展示的 insight 是否与"用户当前 settings 想要的物料"不一致。
    ///
    /// 两个独立维度——任一失配即视为 stale：
    ///   1. **代码上下文**：`settings.aiRepoContextEnabled` ≠ `insight.contextMetadata != nil`
    ///      - 例：用户关了代码开关但 insight 是带 commitSha 生成的 → stale；
    ///      - 例外：vm 已有 contextDegradationReason → 降级路径已经在 banner 里解释，
    ///        本判定排除该路径避免双重提示（`hasDegradation == true` 时跳过代码维度）。
    ///   2. **AnySearch 外部材料**：当前 settings 允许（双开关 AND + 私仓门控）
    ///      ≠ `insight.externalContextMarkdown != nil`
    ///      - 例：用户开了 AnySearch 但 insight 是关时生成的 → stale；
    ///
    /// 用户调整 settings 后下次手动点 "重新生成" 即可消除提示——这条路径与摘要面板
    /// 右上角 ellipsis Menu 的"重新生成"是同一个 action。
    private func isInsightStaleAgainstCurrentSettings(
        insight: RepoAIInsight,
        hasDegradation: Bool
    ) -> Bool {
        if !hasDegradation {
            let userWantsCode = settings.aiRepoContextEnabled
            let insightHasCode = insight.contextMetadata != nil
            if userWantsCode != insightHasCode { return true }
        }

        let externalAllowed = AnySearchContextProvider.allowsExternalContext(
            repoIsPrivate: repo.isPrivate,
            enabled: settings.anySearchEnabled && settings.aiExternalContextEnabled,
            allowPrivate: settings.aiExternalContextAllowPrivateRepos
        )
        let insightHasExternal = insight.externalContextMarkdown?.isEmpty == false
        if externalAllowed != insightHasExternal { return true }

        return false
    }

    /// Y9：「设置已变更」提示行 + [重新生成] 按钮。
    ///
    /// 视觉风格选择 `.yellow.opacity(0.10)` + `info.circle` —— 比 errorBanner 的红色
    /// 克制，与 contextDegradationBanner 同色系，让用户立刻识别为"信息提示"而非
    /// "错误"。按钮调用与摘要面板右上角 Menu 同款 generate(includeTags:)，include
    /// flags 由当前 starredAtOpen 决定，与既有路径保持一致。
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
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 推荐标签块。视觉上比对话气泡克制：
    /// "tag name + reason + 置信度 + 应用按钮"，与旧详情页 AI Tab 的样式对齐。
    private func tagSuggestionsBlock(_ tags: [AITagSuggestion], vm: RepoAIInsightViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ai.assistant.tags.title")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("ai.assistant.tags.applyAll") {
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
                    // tag.name / tag.reason 是后端 / 模型返回的原始字符串，无需本地化
                    // （内容本身就是 i18n-中立的、给当前用户语言生成的）。
                    Button(isApplied ? "ai.assistant.tags.applied" : "ai.assistant.tags.apply") {
                        Task { await vm.applyTag(tag, repo: repo) }
                    }
                    .controlSize(.small)
                    .disabled(isApplied)
                }
            }
        }
    }

    /// Y2（2026-06-13）：footer 两行结构。
    ///   - 第一行：由 X 模型生成 · 时间（旧版独占）
    ///   - 第二行：基于 commit abc1234 (4280 tokens · 38 files)
    ///     仅当 insight.contextMetadata 非 nil 时出现；不存在的旧缓存 insight 上行兼容。
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
        .foregroundStyle(.tertiary)
    }

    /// Y2：代码上下文元信息行。展示 "<commit-7位> · N tokens · M files"。
    ///
    /// 文案格式化用 `String(format:)` + i18n 模板，与上面的 generatedBy 行同款手法
    /// （避免 SwiftUI Text 拼接造成 key 名漂移）。
    private func contextMetaFooterRow(_ meta: RepoAIInsightContextMeta) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text.magnifyingglass")
            Text(
                String(
                    format: String(localized: "ai.assistant.summary.footer.contextMetaFormat"),
                    meta.commitShaShort,
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
    /// - selection 绑定 `panelMode` 并带 0.28s easeInOut 动画，与上下两段
    ///   `frame(maxHeight: ...)` 的折叠动画完全同节奏；
    /// - bar 自带细分隔线（`.bar` 材质 + Divider 上下），视觉上是上下两段
    ///   面板的边界，无需额外加 `Divider()`。
    private var panelToggleBar: some View {
        HStack(spacing: 0) {
            Picker("", selection: $panelMode.animation(.easeInOut(duration: 0.28))) {
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
                .background(Color.clear)
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
                tooltip: "ai.assistant.chat.copyAll.tooltip"
            ) { didCopy in
                HStack(spacing: 6) {
                    Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.caption)
                        .contentTransition(.symbolEffect(.replace))
                    Text(didCopy ? "ai.assistant.copy.copied" : "ai.assistant.chat.copyAll.label")
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
            Text("ai.assistant.chat.empty.title")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("ai.assistant.chat.empty.description")
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

    /// Y4：代码上下文降级 banner。
    ///
    /// 视觉上比 errorBanner 克制——这不是错误（摘要照常生成了），只是告诉用户"这次
    /// 没用上代码内容"。用 `.yellow.opacity(0.10)` 背景 + `info.circle` icon。
    /// 文案 5 case 全部走 i18n key（在 Y4 一并补 Localizable.xcstrings）。
    private func contextDegradationBanner(_ reason: ContextDegradationReason) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
            Text(LocalizedStringKey(reason.bannerMessageKey))
                .font(.caption)
        }
        .foregroundStyle(.yellow)
        .padding(10)
        .background(Color.yellow.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    private func degradationStatusRow(reason: ContextDegradationReason) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(LocalizedStringKey(reason.bannerMessageKey))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 3 维汇总状态行。
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
                Text(verbatim: makeContextStatusText(
                    hasSummary: hasSummary,
                    hasCode: hasCode,
                    hasExternal: hasExternal
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 三者都为 false：返回隐含 EmptyView，配合外层 frame(maxHeight: 0) 完全不占位。
    }

    /// 按命中维度拼出形如「上下文：摘要 · 代码 · 外网」的本地化文本。
    ///
    /// 用 `String(localized:)` + 普通字符串拼接而非 SwiftUI `Text` 组合，是因为
    /// 这里要做"按 bool 选择性插入"，Text 的 `+` 操作语法对条件插入不友好。
    /// 文案前缀和三个维度词都各自独立 i18n（en/zh-Hans 都需要补 key）。
    private func makeContextStatusText(hasSummary: Bool, hasCode: Bool, hasExternal: Bool) -> String {
        var parts: [String] = []
        if hasSummary { parts.append(String(localized: "ai.assistant.chat.contextStatus.summary")) }
        if hasCode { parts.append(String(localized: "ai.assistant.chat.contextStatus.code")) }
        if hasExternal { parts.append(String(localized: "ai.assistant.chat.contextStatus.external")) }
        let prefix = String(localized: "ai.assistant.chat.contextStatus.prefix")
        return prefix + parts.joined(separator: " · ")
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
