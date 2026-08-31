//
//  RepoAIFloatingOverlay.swift
//  Starcat
//
//  README 详情页内的 AI 对话浮层入口。
//
//  设计约束：
//  - 这是 AI 摘要 / 对话的主承载面板；快捷键、搜索和详情入口都先展开这里。
//  - 独立 AI 窗口是本面板的附属展示形态，只能由“在独立窗口中打开”继续进入，
//    不能与底部面板并列成为外部主入口。
//  - 浮层只在右侧详情页区域内展开 / 最大化，避免跨列覆盖 repo 列表或 sidebar。
//  - 展开态宽度按详情区 70% 比例缩放（硬顶 720）。高度从详情 body 底边往上铺；
//    Manage 详情有 README / 洞察切换行时，顶边贴在该行底部分隔线下方，不能盖住 tab。
//    其他场景没有切换行，继续留 16pt 顶距。最大化态再铺满宽度。
//  - 点击外部不自动关闭；AI 流式输出时误关会打断阅读，所以关闭必须是显式动作。
//

import AppKit
import SwiftUI

/// Inline AI 浮层高度：从详情 body 底边往上铺，顶边停在 README / 洞察切换行下方。
///
/// Overlay 挂在整个 body 上（含切换行）。Manage 详情通过 PreferenceKey 上报切换行高度；
/// Trending / Weekly / Activity 没有这条切换行，`topChromeInset == 0`，继续留 16pt 顶距。
enum RepoAIOverlayLayout {
    static let panelBottomInset: CGFloat = 34
    static let fallbackTopInset: CGFloat = 16
    static let panelMinHeight: CGFloat = 320
    static let maximizedMinHeight: CGFloat = 360

    static func panelHeight(
        availableHeight: CGFloat,
        topChromeInset: CGFloat,
        isMaximized: Bool
    ) -> CGFloat {
        let topInset = topChromeInset > 0 ? topChromeInset : fallbackTopInset
        let minHeight = isMaximized ? maximizedMinHeight : panelMinHeight
        return max(minHeight, availableHeight - panelBottomInset - topInset)
    }
}

/// 右侧详情页内的 AI 悬浮入口和两档面板容器。
struct RepoAIFloatingOverlay: View {
    let repo: Repo
    /// Manage 详情 README / 洞察切换行高度；其它场景保持 0。
    var topChromeInset: CGFloat = 0

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var presentation: Presentation = .collapsed
    @State private var escapeKeyMonitor: Any?
    @State private var autoGenerateSummaryOnOpen = false

    private enum Presentation: Equatable {
        case collapsed
        case expanded
        case maximized

        var isPanelVisible: Bool {
            self != .collapsed
        }
    }

    private enum Metrics {
        static let horizontalInset: CGFloat = 24
        static let collapsedBottomInset: CGFloat = 0
        static let panelBottomInset = RepoAIOverlayLayout.panelBottomInset
        static let collapsedHitHeight: CGFloat = 28
        static let collapsedHitWidth: CGFloat = 112
        static let collapsedHandleHeight: CGFloat = 4
        static let collapsedHandleWidth: CGFloat = 78
        /// 展开态相对详情区可用宽的比例；主窗口放大时浮层跟着变宽。
        static let expandedWidthRatio: CGFloat = 0.70
        /// 展开态宽度硬顶，避免超宽详情区把对话面板拉得过散。
        static let expandedMaxWidth: CGFloat = 720
        /// 最大化态左右额外内缩；无 tab 行时高度也复用这个值作顶距。
        static let maximizedInset = RepoAIOverlayLayout.fallbackTopInset
        static let cornerRadius: CGFloat = 18
        static let panelMinWidth: CGFloat = 320
        static let panelMinHeight = RepoAIOverlayLayout.panelMinHeight
        static let maximizedMinHeight = RepoAIOverlayLayout.maximizedMinHeight
    }

    var body: some View {
        GeometryReader { proxy in
            // VStack + Spacer：面板上方的空白不参与 hit testing，
            // README / 洞察 tab 才能点到。ZStack 铺满时 GeometryReader 会把点击吃掉。
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if presentation.isPanelVisible {
                    panel(in: proxy.size)
                        .transition(panelTransition)
                } else {
                    collapsedBar
                        .frame(
                            width: min(proxy.size.width - Metrics.horizontalInset * 2, Metrics.collapsedHitWidth),
                            height: Metrics.collapsedHitHeight
                        )
                        .transition(collapsedTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.bottom, bottomInset)
            .animation(overlayAnimation, value: presentation)
        }
        .allowsHitTesting(true)
        .onReceive(NotificationCenter.default.publisher(for: .repoAIInlineGenerateSummaryRequested)) { notification in
            handleExternalSummaryRequest(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoAIInlineOpenRequested)) { notification in
            guard let repoID = notification.userInfo?["repoId"] as? Repo.ID,
                  repoID == repo.id else { return }
            presentation = .expanded
        }
        .onAppear {
            consumePendingInlinePresentationIfNeeded()
        }
        .onChange(of: homeViewModel.pendingInlineAIPresentationRepoID) { _, _ in
            consumePendingInlinePresentationIfNeeded()
        }
        .onExitCommand {
            guard presentation.isPanelVisible else { return }
            presentation = .collapsed
        }
        .onChange(of: presentation.isPanelVisible) { _, isVisible in
            isVisible ? installEscapeKeyMonitor() : removeEscapeKeyMonitor()
        }
        .onDisappear {
            removeEscapeKeyMonitor()
        }
        // repo 切换时直接清空临时会话与展示状态，确保新问题只绑定当前 repo。
        .id(repo.id)
    }

    /// 消费 HomeViewModel 上的「展开 AI 面板」挂起请求。
    ///
    /// 侧栏后台任务跳转会先换仓再请求展开；若只靠 Notification，可能在
    /// `.id(repo.id)` 重建前发出而被旧 overlay 丢掉。pending 状态由目标
    /// overlay 在挂载后自行认领，避免竞态。
    private func consumePendingInlinePresentationIfNeeded() {
        guard homeViewModel.pendingInlineAIPresentationRepoID == repo.id else { return }
        homeViewModel.pendingInlineAIPresentationRepoID = nil
        presentation = .expanded
    }

    private var collapsedBar: some View {
        Button {
            NotificationCenter.default.post(name: .gettingStartedDidOpenAI, object: nil)
            presentation = .expanded
        } label: {
            Capsule(style: .continuous)
                // 用 primary 语义色适配明暗主题：浅色下是深色横条，深色下自动反转为浅色横条。
                .fill(Color.primary.opacity(0.72))
                .frame(width: Metrics.collapsedHandleWidth, height: Metrics.collapsedHandleHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .gettingStartedAnchor(.ai)
        .help("ai.assistant.inline.collapsed.help")
    }

    private func panel(in availableSize: CGSize) -> some View {
        let isMaximized = presentation == .maximized
        let width = panelWidth(in: availableSize, isMaximized: isMaximized)
        let height = panelHeight(in: availableSize, isMaximized: isMaximized)

        return RepoAIWindowContentView(
            repo: repo,
            autoGenerateSummaryOnOpen: autoGenerateSummaryOnOpen,
            respondsToInlineGenerateRequests: true,
            onClose: {
                autoGenerateSummaryOnOpen = false
                presentation = .collapsed
            },
            onInlineResizeTapped: togglePanelSize,
            onOpenDetachedWindow: openDetachedWindow,
            isInlineMaximized: isMaximized
        )
        .frame(width: width, height: height)
        // 深色不用 `.regularMaterial` 采样 README：暗底 vibrancy 会把整块面板染成近黑紫。
        // 与内容层共用 `StarcatSurface.panel`，浮层是实色工具面板而不是玻璃黑洞。
        .background(
            StarcatSurface.panel(colorScheme: colorScheme),
            in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
        )
        .defaultCursorShield()
        .shadow(color: .black.opacity(0.18), radius: 22, x: 0, y: 12)
        .accessibilityElement(children: .contain)
    }

    private func panelWidth(in availableSize: CGSize, isMaximized: Bool) -> CGFloat {
        let usableWidth = max(Metrics.panelMinWidth, availableSize.width - Metrics.horizontalInset * 2)
        if isMaximized {
            return max(Metrics.panelMinWidth, usableWidth - Metrics.maximizedInset * 2)
        }
        // 展开态随详情区变宽：比例取宽，再夹在 [min, min(usable, hardMax)] 之间。
        let proportionalWidth = usableWidth * Metrics.expandedWidthRatio
        return min(usableWidth, Metrics.expandedMaxWidth, max(Metrics.panelMinWidth, proportionalWidth))
    }

    private func panelHeight(in availableSize: CGSize, isMaximized: Bool) -> CGFloat {
        // hero 折叠时 GeometryReader 变高，浮层跟着长高；有 tab 行时扣掉实测高度。
        RepoAIOverlayLayout.panelHeight(
            availableHeight: availableSize.height,
            topChromeInset: topChromeInset,
            isMaximized: isMaximized
        )
    }

    private var bottomInset: CGFloat {
        presentation.isPanelVisible ? Metrics.panelBottomInset : Metrics.collapsedBottomInset
    }

    private func togglePanelSize() {
        presentation = presentation == .maximized ? .expanded : .maximized
    }

    private func openDetachedWindow() {
        let detachedRepo = repo
        autoGenerateSummaryOnOpen = false
        presentation = .collapsed
        DispatchQueue.main.async {
            // 独立窗口只从底部面板内部派生；它与 inline panel 共享内容 View，
            // 但保留独立窗口生命周期，便于用户脱离详情布局持续对话或并排比较。
            RepoAIWindowController.show(
                repo: detachedRepo,
                dependencies: dependencies,
                homeViewModel: homeViewModel
            )
        }
    }

    private func handleExternalSummaryRequest(_ notification: Notification) {
        guard let repoID = notification.userInfo?["repoId"] as? Repo.ID, repoID == repo.id else { return }
        // Browser Plugin 的“生成摘要”必须先落到详情页底部面板；附属独立窗口
        // 只能由用户在面板内主动选择，外部动作不能越级打开。
        // 若面板尚未创建，先记录 auto-generate 意图，展开后由 RepoAIWindowContentView 的 task 消费。
        autoGenerateSummaryOnOpen = true
        if presentation == .collapsed {
            presentation = .expanded
        }
    }

    private func installEscapeKeyMonitor() {
        guard escapeKeyMonitor == nil else { return }
        // `onExitCommand` 依赖 SwiftUI 焦点；AI 输入框底层是 AppKit NSTextView，
        // 焦点进入输入框后 Esc 可能不会回到 SwiftUI。展开期间用本地 keyDown 监听兜底。
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            presentation = .collapsed
            return nil
        }
    }

    private func removeEscapeKeyMonitor() {
        guard let escapeKeyMonitor else { return }
        NSEvent.removeMonitor(escapeKeyMonitor)
        self.escapeKeyMonitor = nil
    }

    private var overlayAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)
    }

    private var panelTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .bottom)),
            removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.98, anchor: .bottom))
        )
    }

    private var collapsedTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom))
    }
}

extension Notification.Name {
    /// 外部入口请求详情页底部 AI 横条展开并生成指定 repo 的摘要。
    ///
    /// 这个通知只面向 inline overlay。附属独立窗口不消费外部生成请求；
    /// Browser Plugin 的 generate-summary 动作必须先落到当前详情页入口。
    static let repoAIInlineGenerateSummaryRequested = Notification.Name("StarcatRepoAIInlineGenerateSummaryRequested")
    /// 外部入口只展开对应 repo 的详情页底部面板，不重复发起生成。
    static let repoAIInlineOpenRequested = Notification.Name("StarcatRepoAIInlineOpenRequested")
}

private extension View {
    /// 详情页浮层的玻璃态容器。单独收口，避免后续调阴影 / 边框时改散在多处。
    func glassPanel(cornerRadius: CGFloat, shadowOpacity: Double) -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(shadowOpacity), radius: 18, x: 0, y: 10)
    }
}
