//
//  RepoAIFloatingOverlay.swift
//  Starcat
//
//  README 详情页内的 AI 对话浮层入口。
//
//  设计约束：
//  - 不替换旧的独立 AI 窗口入口；这是详情页里的新增入口，用于验证“贴着 README 问 AI”
//    的交互是否更自然。
//  - 浮层只在右侧详情页区域内展开 / 最大化，避免跨列覆盖 repo 列表或 sidebar。
//  - 展开态宽度按详情区 70% 比例缩放（硬顶 720），高度铺满 README 可用区：hero 折叠 /
//    主窗口变高时浮层跟着长高，避免顶部留白。最大化态再铺满宽度。
//  - 点击外部不自动关闭；AI 流式输出时误关会打断阅读，所以关闭必须是显式动作。
//

import AppKit
import SwiftUI

/// 右侧详情页内的 AI 悬浮入口和两档面板容器。
struct RepoAIFloatingOverlay: View {
    let repo: Repo

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.starcatReduceMotion) private var reduceMotion
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
        static let panelBottomInset: CGFloat = 34
        static let collapsedHitHeight: CGFloat = 28
        static let collapsedHitWidth: CGFloat = 112
        static let collapsedHandleHeight: CGFloat = 4
        static let collapsedHandleWidth: CGFloat = 78
        /// 展开态相对详情区可用宽的比例；主窗口放大时浮层跟着变宽。
        static let expandedWidthRatio: CGFloat = 0.70
        /// 展开态宽度硬顶，避免超宽详情区把对话面板拉得过散。
        static let expandedMaxWidth: CGFloat = 720
        static let maximizedInset: CGFloat = 16
        static let cornerRadius: CGFloat = 18
        static let panelMinWidth: CGFloat = 320
        static let panelMinHeight: CGFloat = 320
        static let maximizedMinHeight: CGFloat = 360
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                if presentation.isPanelVisible {
                    panel(in: proxy.size)
                        .transition(panelTransition)
                        .zIndex(2)
                } else {
                    collapsedBar
                        .frame(
                            width: min(proxy.size.width - Metrics.horizontalInset * 2, Metrics.collapsedHitWidth),
                            height: Metrics.collapsedHitHeight
                        )
                        .transition(collapsedTransition)
                        .zIndex(1)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
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
        // Overlay 挂在 README body 上：可用高 = 详情区减去 hero / metadata 后的剩余高度。
        // hero 随滚动折叠时 GeometryReader 变高，浮层必须跟着铺满，不能再乘比例留顶空白。
        // 展开 vs 最大化的差异主要在宽度；高度两侧都吃满可用区。
        let usableHeight = max(
            Metrics.panelMinHeight,
            availableSize.height - Metrics.panelBottomInset - Metrics.maximizedInset
        )
        if isMaximized {
            return max(Metrics.maximizedMinHeight, usableHeight)
        }
        return max(Metrics.panelMinHeight, usableHeight)
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
            RepoAIWindowController.show(
                repo: detachedRepo,
                dependencies: dependencies,
                homeViewModel: homeViewModel,
                openSettings: openSettings
            )
        }
    }

    private func handleExternalSummaryRequest(_ notification: Notification) {
        guard let repoID = notification.userInfo?["repoId"] as? Repo.ID, repoID == repo.id else { return }
        // Browser Plugin 的“生成摘要”必须复用详情页底部横条入口，而不是旧的独立 AI window。
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
    /// 这个通知只面向 inline overlay。旧的独立 AI window 仍可被历史入口打开，
    /// 但 Browser Plugin 的 generate-summary 动作必须落到当前详情页入口。
    static let repoAIInlineGenerateSummaryRequested = Notification.Name("StarcatRepoAIInlineGenerateSummaryRequested")
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
