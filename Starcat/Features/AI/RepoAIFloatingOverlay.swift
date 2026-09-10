//
//  RepoAIFloatingOverlay.swift
//  Starcat
//
//  README 详情页内的 AI 对话入口。
//
//  设计约束：
//  - 这是 AI 摘要 / 对话的主承载入口；实际内容放在详情区域上的 child NSPanel 中。
//  - 独立 AI 窗口是本面板的附属展示形态，只能由“在独立窗口中打开”继续进入，
//    不能与底部面板并列成为外部主入口。
//  - child panel 只在右侧详情页区域内展开 / 最大化，避免跨列覆盖 repo 列表或 sidebar。
//  - 展开态宽度按详情区 70% 比例缩放（硬顶 720）。高度从详情 body 底边往上铺；
//    Manage 详情有 README / 洞察切换行时，顶边贴在该行底部分隔线下方，不能盖住 tab。
//    其他场景没有切换行，继续留 16pt 顶距。最大化态再铺满宽度。
//  - 点击外部不自动关闭；AI 流式输出时误关会打断阅读，所以关闭必须是显式动作。
//

import SwiftUI

/// Inline AI 浮层高度：从 README 状态栏上沿往上铺，顶边停在 README / 洞察切换行下方。
///
/// Overlay 挂在整个 body 上（含切换行和 README 状态栏）。Manage 详情通过 PreferenceKey
/// 上报切换行和状态栏高度；没有对应 chrome 的场景继续使用兼容兜底间距。
enum RepoAIOverlayLayout {
    static let panelBottomInset: CGFloat = 34
    static let fallbackTopInset: CGFloat = 16
    static let panelMinHeight: CGFloat = 320
    static let maximizedMinHeight: CGFloat = 360

    static func panelHeight(
        availableHeight: CGFloat,
        topChromeInset: CGFloat,
        bottomChromeInset: CGFloat = panelBottomInset,
        isMaximized: Bool
    ) -> CGFloat {
        let topInset = topChromeInset > 0 ? topChromeInset : fallbackTopInset
        let minHeight = isMaximized ? maximizedMinHeight : panelMinHeight
        return max(minHeight, availableHeight - bottomChromeInset - topInset)
    }
}

/// 右侧详情页内的 AI 悬浮入口和两档面板容器。
struct RepoAIFloatingOverlay: View {
    let repo: Repo
    /// Manage 详情 README / 洞察切换行高度；其它场景保持 0。
    var topChromeInset: CGFloat = 0
    /// README 状态栏高度；为 0 时使用 `RepoAIOverlayLayout.panelBottomInset` 兼容旧场景。
    var bottomChromeInset: CGFloat = 0

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isInlinePanelPresented = false
    @State private var isInlinePanelOpening = false
    @State private var anchorReference = RepoAIInlineWindowAnchorReference()
    @State private var inlineViewportSize: CGSize = .zero
    @State private var autoGenerateSummaryOnOpen = false

    private enum Metrics {
        static let horizontalInset: CGFloat = 24
        static let collapsedBottomInset: CGFloat = 0
        static let collapsedHitHeight: CGFloat = 28
        static let collapsedHitWidth: CGFloat = 112
        static let collapsedHandleHeight: CGFloat = 4
        static let collapsedHandleWidth: CGFloat = 78
    }

    var body: some View {
        GeometryReader { proxy in
            // child window 打开后主窗口这里只保留锚点和空白布局，不再渲染 AI 面板本体；
            // 因此 README / 洞察 tab 仍可在 child window 之外正常接收事件。
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                if !isInlinePanelPresented {
                    collapsedBar
                        .frame(
                            width: min(proxy.size.width - Metrics.horizontalInset * 2, Metrics.collapsedHitWidth),
                            height: Metrics.collapsedHitHeight
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.horizontal, Metrics.horizontalInset)
            .padding(.bottom, Metrics.collapsedBottomInset)
            .onAppear {
                updateInlineViewport(proxy.size)
            }
            .onChange(of: proxy.size) { _, newSize in
                // 旧版面板直接读取 `proxy.size`，README 滚动导致 Hero 折叠时会自然变高。
                // child window 不会自动订阅 SwiftUI 的 layout proposal，必须把同一份
                // viewport 变化显式转发给 AppKit，否则面板会停留在打开时的高度。
                updateInlineViewport(newSize)
            }
        }
        .background {
            // 这个 NSView 只测量详情区域并转换成 screen 坐标，不能参与鼠标命中；
            // AI 内容本体在独立 child window 中渲染，避免与 README 共用 cursor rect。
            RepoAIInlineWindowAnchor(reference: anchorReference)
                .allowsHitTesting(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoAIInlineGenerateSummaryRequested)) { notification in
            handleExternalSummaryRequest(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoAIInlineOpenRequested)) { notification in
            guard let repoID = notification.userInfo?["repoId"] as? Repo.ID,
                  repoID == repo.id else { return }
            openInlinePanel(autoGenerateSummary: false)
        }
        .onAppear {
            consumePendingInlinePresentationIfNeeded()
        }
        .onChange(of: homeViewModel.pendingInlineAIPresentationRepoID) { _, _ in
            consumePendingInlinePresentationIfNeeded()
        }
        .onChange(of: topChromeInset) { _, newInset in
            // tab 行高度可能在 README / Hero 布局完成后才测量出来；不能只在 child
            // window 创建时捕获一次，否则面板顶边会停在旧位置。
            RepoAIInlineWindowController.updateAnchor(
                reference: anchorReference,
                availableSize: inlineViewportSize,
                topChromeInset: newInset,
                bottomChromeInset: bottomChromeInset
            )
        }
        .onChange(of: bottomChromeInset) { _, newInset in
            // 状态栏第一次完成布局或字体发生变化后，立即把 child window 移到状态栏上沿。
            RepoAIInlineWindowController.updateAnchor(
                reference: anchorReference,
                availableSize: inlineViewportSize,
                bottomChromeInset: newInset
            )
        }
        .onExitCommand {
            guard isInlinePanelPresented || isInlinePanelOpening else { return }
            RepoAIInlineWindowController.dismiss()
        }
        .onDisappear {
            RepoAIInlineWindowController.dismiss()
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
        openInlinePanel(autoGenerateSummary: false)
    }

    private var collapsedBar: some View {
        Button {
            NotificationCenter.default.post(name: .gettingStartedDidOpenAI, object: nil)
            openInlinePanel(autoGenerateSummary: false)
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

    /// 保存 SwiftUI 详情区的真实 viewport，并把它作为 child window 的几何源同步过去。
    ///
    /// 锚点 view 只能提供 screen 坐标，不能可靠代表 SwiftUI 的 layout proposal；后者
    /// 才是旧版面板计算高度和 Hero 折叠位置时使用的值。这里还通过控制器内部合并更新，
    /// 避免 README 滚动期间每一轮 layout 都同步调用一次 `setFrame`。
    private func updateInlineViewport(_ size: CGSize) {
        guard size != inlineViewportSize else { return }
        inlineViewportSize = size
        RepoAIInlineWindowController.updateAnchor(
            reference: anchorReference,
            availableSize: size,
            topChromeInset: topChromeInset,
            bottomChromeInset: bottomChromeInset
        )
    }

    /// 在详情锚点准备好后打开 child AI panel；窗口本体不再出现在主窗口 SwiftUI overlay。
    private func openInlinePanel(autoGenerateSummary: Bool) {
        guard !isInlinePanelPresented else { return }
        guard !isInlinePanelOpening else {
            // 外部“生成摘要”请求可能紧跟在打开请求之后到达；保留这份意图，
            // 避免首帧锚点重试期间把自动生成动作静默丢掉。
            autoGenerateSummaryOnOpen = autoGenerateSummaryOnOpen || autoGenerateSummary
            return
        }
        autoGenerateSummaryOnOpen = autoGenerateSummary
        isInlinePanelOpening = true

        DispatchQueue.main.async {
            attemptOpenInlinePanel(remainingRetries: 8)
        }
    }

    /// 等待锚点真正进入主窗口后再创建 child window。
    ///
    /// 详情 repo 切换和首帧布局期间，`NSViewRepresentable` 可能已经创建了 NSView，
    /// 但它暂时还没有 `window`。直接以这个 view 创建 child window 会失败并让用户
    /// 看到“点了没有反应”；这里最多等待 8 个主线程布局周期，确保首帧拿到详情区域
    /// 坐标。等待失败时恢复横条，不使用整主窗口作为错误定位兜底。
    private func attemptOpenInlinePanel(remainingRetries: Int) {
        guard isInlinePanelOpening else { return }

        guard let anchorView = anchorReference.view,
              anchorView.window != nil,
              anchorView.bounds.width > 1,
              anchorView.bounds.height > 1 else {
            guard remainingRetries > 0 else {
                finishInlinePanelOpening(didPresent: false)
                return
            }
            DispatchQueue.main.async {
                attemptOpenInlinePanel(remainingRetries: remainingRetries - 1)
            }
            return
        }

        let didPresent = presentInlinePanel(
            anchorView: anchorView,
            anchorFrame: anchorReference.lastValidScreenFrame
        )
        finishInlinePanelOpening(didPresent: didPresent)
    }

    /// 创建 AI child window；定位和父窗口都必须来自详情锚点，避免不同主窗口几何混用。
    private func presentInlinePanel(anchorView: NSView?, anchorFrame: NSRect?) -> Bool {
        RepoAIInlineWindowController.present(
            repo: repo,
            dependencies: dependencies,
            homeViewModel: homeViewModel,
            anchorView: anchorView,
            anchorFrame: anchorFrame,
            availableSize: inlineViewportSize,
            autoGenerateSummaryOnOpen: autoGenerateSummaryOnOpen,
            topChromeInset: topChromeInset,
            bottomChromeInset: bottomChromeInset,
            reduceMotion: reduceMotion,
            onDismiss: {
                isInlinePanelPresented = false
                isInlinePanelOpening = false
                autoGenerateSummaryOnOpen = false
            }
        )
    }

    /// 将控制器返回值统一映射回 SwiftUI 打开状态，确保所有失败路径都能恢复横条。
    private func finishInlinePanelOpening(didPresent: Bool) {
        if didPresent {
            isInlinePanelPresented = true
            isInlinePanelOpening = false
        } else {
            isInlinePanelOpening = false
            autoGenerateSummaryOnOpen = false
        }
    }

    private func handleExternalSummaryRequest(_ notification: Notification) {
        guard let repoID = notification.userInfo?["repoId"] as? Repo.ID, repoID == repo.id else { return }
        // Browser Plugin 的“生成摘要”必须先落到详情页底部面板；附属独立窗口
        // 只能由用户在面板内主动选择，外部动作不能越级打开。
        // child window 的 root view 直接接收该意图，打开后由其 task 消费生成请求。
        openInlinePanel(autoGenerateSummary: true)
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
