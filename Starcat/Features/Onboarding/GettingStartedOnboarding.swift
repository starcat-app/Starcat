//
//  GettingStartedOnboarding.swift
//  Starcat
//
//  首次操作引导：负责用户进入主界面后的「下一步该做什么」清单。
//
//  设计边界：
//  - `FirstRunOnboardingView` 继续负责品牌 / 能力介绍；本文件只负责进入主界面后的操作闭环。
//  - 清单状态由真实行为推进（登录、同步、选中仓库、保存标签/笔记、搜索、打开 AI），避免用户只点「下一步」。
//  - TipKit 只用于局部发现提示，不承担任务进度；进度仍由 `GettingStartedProgressStore` 持久化。
//

import SwiftUI
import TipKit

// MARK: - Notification hooks

extension Notification.Name {
    /// 用户成功保存过标签或笔记后发出，驱动「整理一个仓库」清单项。
    static let gettingStartedDidOrganizeRepo = Notification.Name("starcat.gettingStarted.didOrganizeRepo")
    /// 用户主动点击过主界面同步入口后发出，驱动「同步 Stars」等待完成。
    static let gettingStartedDidRequestSync = Notification.Name("starcat.gettingStarted.didRequestSync")
    /// 用户提交过一次列表搜索后发出，驱动「使用搜索」清单项。
    static let gettingStartedDidUseSearch = Notification.Name("starcat.gettingStarted.didUseSearch")
    /// 用户打开过 AI 仓库助手后发出，驱动「试用 AI 摘要」清单项。
    static let gettingStartedDidOpenAI = Notification.Name("starcat.gettingStarted.didOpenAI")
    /// 用户打开过知识库 RAG 工作台后发出，驱动「试用 RAG 工作台」清单项。
    static let gettingStartedDidOpenRAGWorkspace = Notification.Name("starcat.gettingStarted.didOpenRAGWorkspace")
    /// 用户打开过 Agent 工作台后发出，驱动「试用 Agent 工作台」清单项。
    static let gettingStartedDidOpenAgentWorkspace = Notification.Name("starcat.gettingStarted.didOpenAgentWorkspace")
    /// 用户点击过详情页项目 Logo 后发出，驱动「打开项目主页」清单项。
    static let gettingStartedDidOpenRepoHomepage = Notification.Name("starcat.gettingStarted.didOpenRepoHomepage")
    /// 用户把仓库加入知识库后发出，驱动「加入知识库」清单项。
    static let gettingStartedDidAddRepoToLibrary = Notification.Name("starcat.gettingStarted.didAddRepoToLibrary")
    /// 用户成功取消 Star 后发出，驱动「取消 Star 并了解恢复入口」清单项。
    static let gettingStartedDidUnstarRepo = Notification.Name("starcat.gettingStarted.didUnstarRepo")
    /// 用户打开过分享卡片后发出，驱动「分享个人卡片」清单项。
    static let gettingStartedDidShareProfile = Notification.Name("starcat.gettingStarted.didShareProfile")
    /// Getting Started 主按钮请求 Sidebar 打开分享卡片。
    static let gettingStartedOpenShareCardRequested = Notification.Name("starcat.gettingStarted.openShareCardRequested")
}

// MARK: - Progress Store

/// 主界面首次操作清单的持久化状态。
///
/// 使用 `UserDefaults` 而不是数据库：这些状态是本机 UI 教程进度，不属于用户 GitHub 数据，
/// 账号切换也不应强制重播所有教学提示。恢复出厂路径会统一清理 onboarding key。
@MainActor
@Observable
final class GettingStartedProgressStore {

    enum StepID: String, CaseIterable, Identifiable {
        case signIn
        case syncStars
        case selectRepo
        case openRepoHomepage
        case addRepoToLibrary
        case organizeRepo
        case useSearch
        case useAI
        case useRAGWorkspace
        case useAgentWorkspace
        case shareProfile
        case unstarRepo

        var id: String { rawValue }
    }

    private enum Keys {
        static let completed = "onboarding.gettingStarted.completedSteps.v1"
        static let dismissed = "onboarding.gettingStarted.dismissed.v1"
        static let collapsed = "onboarding.gettingStarted.collapsed.v1"
    }

    private let defaults: UserDefaults

    private(set) var completedSteps: Set<StepID>

    var isDismissed: Bool {
        didSet { defaults.set(isDismissed, forKey: Keys.dismissed) }
    }

    var isCollapsed: Bool {
        didSet { defaults.set(isCollapsed, forKey: Keys.collapsed) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let rawValues = defaults.stringArray(forKey: Keys.completed) ?? []
        self.completedSteps = Set(rawValues.compactMap(StepID.init(rawValue:)))
        self.isDismissed = defaults.bool(forKey: Keys.dismissed)
        self.isCollapsed = defaults.bool(forKey: Keys.collapsed)
    }

    nonisolated static func resetPersistedState(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Keys.completed)
        defaults.removeObject(forKey: Keys.dismissed)
        defaults.removeObject(forKey: Keys.collapsed)
    }

    var completedCount: Int {
        completedSteps.count
    }

    var totalCount: Int {
        StepID.allCases.count
    }

    var isComplete: Bool {
        completedCount == totalCount
    }

    func isCompleted(_ step: StepID) -> Bool {
        completedSteps.contains(step)
    }

    func markCompleted(_ step: StepID) {
        guard completedSteps.insert(step).inserted else { return }
        persistCompletedSteps()
    }

    func reset() {
        completedSteps.removeAll()
        isDismissed = false
        isCollapsed = false
        defaults.removeObject(forKey: Keys.completed)
    }

    private func persistCompletedSteps() {
        let values = completedSteps.map(\.rawValue).sorted()
        defaults.set(values, forKey: Keys.completed)
    }
}

// MARK: - TipKit

/// TipKit 的提示定义集中在一处，避免各个 toolbar / section 分散创建匿名 tip。
///
/// TipKit 展示次数与失效状态由系统管理；清单完成状态由 `GettingStartedProgressStore` 管理，
/// 二者故意分离，避免用户关闭 tip 后误判为已经完成任务。
enum GettingStartedTips {
    struct SyncStarsTip: Tip {
        var title: Text { Text("gettingStarted.tip.sync.title") }
        var message: Text? { Text("gettingStarted.tip.sync.message") }
        var image: Image? { Image(systemName: "arrow.triangle.2.circlepath") }
    }

    struct SearchTip: Tip {
        var title: Text { Text("gettingStarted.tip.search.title") }
        var message: Text? { Text("gettingStarted.tip.search.message") }
        var image: Image? { Image(systemName: "magnifyingglass") }
    }

    struct AITip: Tip {
        var title: Text { Text("gettingStarted.tip.ai.title") }
        var message: Text? { Text("gettingStarted.tip.ai.message") }
        var image: Image? { Image(systemName: "sparkles") }
    }

    static let syncStars = SyncStarsTip()
    static let search = SearchTip()
    static let ai = AITip()
}

// MARK: - Checklist View

enum GettingStartedAnchorID: Hashable {
    case signIn
    case syncStars
    case selectRepo
    case organizeRepo
    case search
    case ai
    case ragWorkspace
    case agentWorkspace
    case repoHomepage
    case addToLibrary
    case unstarRepo
    case shareProfile
}

struct GettingStartedAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: [GettingStartedAnchorID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [GettingStartedAnchorID: Anchor<CGRect>], nextValue: () -> [GettingStartedAnchorID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

extension View {
    func gettingStartedAnchor(_ id: GettingStartedAnchorID) -> some View {
        anchorPreference(key: GettingStartedAnchorPreferenceKey.self, value: .bounds) { [id: $0] }
    }

    func gettingStartedPopoverTip<T: Tip>(_ tip: T) -> some View {
        modifier(GettingStartedPopoverTipModifier(tip: tip))
    }
}

private struct GettingStartedPopoverTipModifier<T: Tip>: ViewModifier {
    let tip: T

    @Environment(\.firstRunOnboardingActive) private var firstRunOnboardingActive

    @ViewBuilder
    func body(content: Content) -> some View {
        if firstRunOnboardingActive {
            content
        } else {
            content.popoverTip(tip)
        }
    }
}

struct GettingStartedChecklistView: View {
    let store: GettingStartedProgressStore
    let isSignedIn: Bool
    let hasSyncedStars: Bool
    let hasSelectedRepo: Bool
    let canSelectRepo: Bool
    let canUnstarRepo: Bool
    let canOpenRAGWorkspace: Bool
    let canOpenAgentWorkspace: Bool
    let targetFrame: CGRect?

    let onSignIn: () -> Void
    let onSyncStars: () -> Void
    let onSelectRepo: () -> Void
    let onAddTag: () -> Void
    let onOpenSearch: () -> Void
    let onOpenAI: () -> Void
    let onOpenRAGWorkspace: () -> Void
    let onOpenAgentWorkspace: () -> Void
    let onOpenRepoHomepage: () -> Void
    let onAddRepoToLibrary: () -> Void
    let onShareProfile: () -> Void
    let onUnstarRepo: () -> Void

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.firstRunOnboardingActive) private var firstRunOnboardingActive

    @State private var highlightFloats = false

    private let panelWidth: CGFloat = 320
    private let panelMargin: CGFloat = 18
    private let panelCollapsedHeight: CGFloat = 132
    private let panelExpandedMaxHeight: CGFloat = 620

    private var shouldRender: Bool {
        !firstRunOnboardingActive && !store.isDismissed && !store.isComplete
    }

    private var progressValue: Double {
        guard store.totalCount > 0 else { return 1 }
        return Double(store.completedCount) / Double(store.totalCount)
    }

    private var steps: [GettingStartedStep] {
        [
            GettingStartedStep(
                id: .signIn,
                title: "gettingStarted.step.signIn.title",
                detail: "gettingStarted.step.signIn.detail",
                systemImage: "person.crop.circle.badge.checkmark",
                actionTitle: "gettingStarted.step.signIn.action",
                isAvailable: !isSignedIn,
                anchorID: .signIn,
                action: onSignIn
            ),
            GettingStartedStep(
                id: .syncStars,
                title: "gettingStarted.step.sync.title",
                detail: "gettingStarted.step.sync.detail",
                systemImage: "arrow.triangle.2.circlepath",
                actionTitle: "gettingStarted.step.sync.action",
                isAvailable: isSignedIn && !hasSyncedStars,
                anchorID: .syncStars,
                action: onSyncStars
            ),
            GettingStartedStep(
                id: .selectRepo,
                title: "gettingStarted.step.select.title",
                detail: "gettingStarted.step.select.detail",
                systemImage: "cursorarrow.click.2",
                actionTitle: "gettingStarted.step.select.action",
                isAvailable: canSelectRepo && !hasSelectedRepo,
                anchorID: .selectRepo,
                action: onSelectRepo
            ),
            GettingStartedStep(
                id: .openRepoHomepage,
                title: "gettingStarted.step.repoHomepage.title",
                detail: "gettingStarted.step.repoHomepage.detail",
                systemImage: "arrow.up.forward.app",
                actionTitle: "gettingStarted.step.repoHomepage.action",
                isAvailable: hasSelectedRepo,
                anchorID: .repoHomepage,
                action: onOpenRepoHomepage
            ),
            GettingStartedStep(
                id: .addRepoToLibrary,
                title: "gettingStarted.step.library.title",
                detail: "gettingStarted.step.library.detail",
                systemImage: "heart",
                actionTitle: "gettingStarted.step.library.action",
                isAvailable: isSignedIn && hasSelectedRepo,
                anchorID: .addToLibrary,
                action: onAddRepoToLibrary
            ),
            GettingStartedStep(
                id: .organizeRepo,
                title: "gettingStarted.step.organize.title",
                detail: "gettingStarted.step.organize.detail",
                systemImage: "tag",
                actionTitle: "gettingStarted.step.organize.action",
                isAvailable: true,
                anchorID: .organizeRepo,
                action: onAddTag
            ),
            GettingStartedStep(
                id: .useSearch,
                title: "gettingStarted.step.search.title",
                detail: "gettingStarted.step.search.detail",
                systemImage: "magnifyingglass",
                actionTitle: "gettingStarted.step.search.action",
                isAvailable: true,
                anchorID: .search,
                action: onOpenSearch
            ),
            GettingStartedStep(
                id: .useAI,
                title: "gettingStarted.step.ai.title",
                detail: "gettingStarted.step.ai.detail",
                systemImage: "sparkles",
                actionTitle: "gettingStarted.step.ai.action",
                isAvailable: hasSelectedRepo,
                anchorID: .ai,
                action: onOpenAI
            ),
            GettingStartedStep(
                id: .useRAGWorkspace,
                title: "gettingStarted.step.ragWorkspace.title",
                detail: "gettingStarted.step.ragWorkspace.detail",
                systemImage: "quote.bubble.fill",
                actionTitle: "gettingStarted.step.ragWorkspace.action",
                isAvailable: canOpenRAGWorkspace,
                anchorID: .ragWorkspace,
                action: onOpenRAGWorkspace
            ),
            GettingStartedStep(
                id: .useAgentWorkspace,
                title: "gettingStarted.step.agentWorkspace.title",
                detail: "gettingStarted.step.agentWorkspace.detail",
                systemImage: "wand.and.stars",
                actionTitle: "gettingStarted.step.agentWorkspace.action",
                isAvailable: canOpenAgentWorkspace,
                anchorID: .agentWorkspace,
                action: onOpenAgentWorkspace
            ),
            GettingStartedStep(
                id: .shareProfile,
                title: "gettingStarted.step.shareProfile.title",
                detail: "gettingStarted.step.shareProfile.detail",
                systemImage: "square.and.arrow.up",
                actionTitle: "gettingStarted.step.shareProfile.action",
                isAvailable: isSignedIn,
                anchorID: .shareProfile,
                action: onShareProfile
            ),
            GettingStartedStep(
                id: .unstarRepo,
                title: "gettingStarted.step.unstar.title",
                detail: "gettingStarted.step.unstar.detail",
                systemImage: "star.slash",
                actionTitle: "gettingStarted.step.unstar.action",
                isAvailable: canUnstarRepo,
                anchorID: .unstarRepo,
                action: onUnstarRepo
            )
        ]
    }

    private var activeStep: GettingStartedStep? {
        steps.first { !store.isCompleted($0.id) }
    }

    var body: some View {
        if shouldRender, let activeStep {
            GeometryReader { proxy in
                ZStack {
                    GettingStartedCoachMark(
                        step: activeStep,
                        targetFrame: targetFrame,
                        containerSize: proxy.size,
                        isFloating: highlightFloats,
                        onDismiss: { store.isDismissed = true }
                    )

                    helperPanel(activeStep: activeStep, availableHeight: proxy.size.height - panelMargin * 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, panelMargin)
                        .padding(.bottom, panelMargin)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transition(reduceMotion ? .opacity : .opacity)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true)) {
                    highlightFloats = true
                }
            }
        }
    }

    private func helperPanel(activeStep: GettingStartedStep, availableHeight: CGFloat) -> some View {
        let panelHeight = store.isCollapsed
            ? min(panelCollapsedHeight, availableHeight)
            : min(panelExpandedMaxHeight, availableHeight)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("gettingStarted.title")
                        .font(.headline)
                    Text("gettingStarted.subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    store.isCollapsed.toggle()
                } label: {
                    Image(systemName: store.isCollapsed ? "chevron.up" : "chevron.down")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help(store.isCollapsed ? Text("gettingStarted.expand") : Text("gettingStarted.collapse"))

                Button {
                    store.isDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("gettingStarted.dismiss")
            }

            ProgressView(value: progressValue)
                .controlSize(.small)

            Text(String(format: String.l10n("gettingStarted.progressFormat"), store.completedCount, store.totalCount))
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !store.isCollapsed {
                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(steps) { step in
                            GettingStartedStepRow(
                                step: step,
                                isCompleted: store.isCompleted(step.id)
                            )

                            if step.id != steps.last?.id {
                                Divider().padding(.leading, 34)
                            }
                        }
                    }
                    .padding(.trailing, 22)
                }
                // 文案换行会让 6 步列表变高；列表区滚动，底部 CTA 始终留在面板内。
                .frame(maxHeight: max(180, panelHeight - 178))

                Button(action: activeStep.action) {
                    HStack(spacing: 6) {
                        Text(activeStep.actionTitle)
                            .font(.caption.weight(.semibold))
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!activeStep.isAvailable)
            }
        }
        .padding(14)
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .defaultCursorShield()
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
    }
}

private struct GettingStartedStep: Identifiable {
    let id: GettingStartedProgressStore.StepID
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let systemImage: String
    let actionTitle: LocalizedStringKey
    let isAvailable: Bool
    let anchorID: GettingStartedAnchorID?
    let action: () -> Void
}

private struct GettingStartedCoachMark: View {
    let step: GettingStartedStep
    let targetFrame: CGRect?
    let containerSize: CGSize
    let isFloating: Bool
    let onDismiss: () -> Void

    private let bubbleWidth: CGFloat = 178
    private let bubbleHeight: CGFloat = 30
    private let arrowSize: CGFloat = 20

    private var verticalOffset: CGFloat {
        // 同步入口位于中栏顶区右侧，旁边有时间文案；这里必须严格贴刷新按钮中心线，
        // 否则轻微浮动会被文字基线放大成“没有对齐”的观感。
        step.id == .syncStars ? 0 : (isFloating ? -3 : 0)
    }

    private var additionalBubbleGap: CGFloat {
        // 全局搜索入口下方紧挨着详情页快捷图标，胶囊需要额外下移避免遮挡。
        step.id == .useSearch ? 28 : 0
    }

    private var placement: CoachMarkPlacement {
        switch step.id {
        case .signIn:
            return .right
        case .syncStars:
            return .right
        case .selectRepo:
            return .right
        case .organizeRepo:
            return .right
        case .useSearch:
            return .below
        case .useAI:
            return .above
        case .openRepoHomepage, .unstarRepo:
            return .right
        case .addRepoToLibrary:
            return .below
        case .useRAGWorkspace, .useAgentWorkspace:
            return .below
        case .shareProfile:
            return .right
        }
    }

    private var layout: CoachMarkLayout? {
        guard let frame = targetFrame else { return nil }
        let margin: CGFloat = 18
        let spacing: CGFloat = 12
        let groupGap = spacing + arrowSize + spacing

        let rawBubble: CGPoint
        switch placement {
        case .left:
            rawBubble = CGPoint(
                x: frame.minX - groupGap - bubbleWidth / 2,
                y: frame.midY + verticalOffset
            )
        case .right:
            rawBubble = CGPoint(
                x: frame.maxX + groupGap + bubbleWidth / 2,
                y: frame.midY + verticalOffset
            )
        case .above:
            rawBubble = CGPoint(
                x: frame.midX,
                y: frame.minY - groupGap - bubbleHeight / 2 + verticalOffset
            )
        case .below:
            rawBubble = CGPoint(
                x: frame.midX,
                y: frame.maxY + groupGap + additionalBubbleGap + bubbleHeight / 2 + verticalOffset
            )
        }

        // 同步按钮在顶区，目标中心可能低于通用 18pt 顶部安全边距。
        // 如果继续用通用 margin 钳制，胶囊会被强行下推，导致箭头和胶囊中心错开。
        let verticalMargin = step.id == .syncStars ? CGFloat(0) : margin
        let bubble = CGPoint(
            x: min(max(rawBubble.x, bubbleWidth / 2 + margin), containerSize.width - bubbleWidth / 2 - margin),
            y: min(max(rawBubble.y, bubbleHeight / 2 + verticalMargin), containerSize.height - bubbleHeight / 2 - margin)
        )
        let arrow = arrowPosition(targetFrame: frame, bubblePosition: bubble)
        return CoachMarkLayout(
            targetFrame: frame,
            bubblePosition: bubble,
            arrowPosition: arrow,
            placement: placement
        )
    }

    private func arrowPosition(targetFrame: CGRect, bubblePosition: CGPoint) -> CGPoint {
        switch placement {
        case .left:
            return CGPoint(
                x: (targetFrame.minX + bubblePosition.x + bubbleWidth / 2) / 2,
                y: (targetFrame.midY + bubblePosition.y) / 2
            )
        case .right:
            return CGPoint(
                x: (targetFrame.maxX + bubblePosition.x - bubbleWidth / 2) / 2,
                y: step.id == .syncStars ? targetFrame.midY : (targetFrame.midY + bubblePosition.y) / 2
            )
        case .above:
            return CGPoint(
                x: (targetFrame.midX + bubblePosition.x) / 2,
                y: (targetFrame.minY + bubblePosition.y + bubbleHeight / 2) / 2
            )
        case .below:
            return CGPoint(
                // 搜索和加入知识库都是小图标入口：箭头必须对准图标中心，不能被宽胶囊的
                // clamp 位置拉到相邻按钮上。
                x: locksArrowToTargetCenter ? targetFrame.midX : (targetFrame.midX + bubblePosition.x) / 2,
                y: (targetFrame.maxY + bubblePosition.y - bubbleHeight / 2) / 2
            )
        }
    }

    private var locksArrowToTargetCenter: Bool {
        step.id == .useSearch || step.id == .addRepoToLibrary
    }

    var body: some View {
        if let layout {
            ZStack {
                targetHalo(frame: layout.targetFrame)
                    .allowsHitTesting(false)

                Image(systemName: layout.placement.arrowSystemName)
                    .font(.system(size: arrowSize, weight: .bold))
                    .foregroundStyle(Color.orange)
                    .shadow(color: Color.orange.opacity(0.45), radius: 10, x: 0, y: 0)
                    .position(layout.arrowPosition)
                    .allowsHitTesting(false)

                ctaBubble
                    .position(layout.bubblePosition)
            }
            .frame(width: containerSize.width, height: containerSize.height)
        }
    }

    private var ctaBubble: some View {
        HStack(spacing: 6) {
            Button(action: step.action) {
                Label {
                    Text(step.actionTitle)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: step.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!step.isAvailable)
            .help(step.title)

            Divider()
                .frame(height: 16)
                .overlay(Color.white.opacity(0.30))

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("gettingStarted.dismiss")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(width: bubbleWidth, height: bubbleHeight)
        .background(
            Capsule(style: .continuous)
                .fill(Color.orange)
                .shadow(color: Color.orange.opacity(0.34), radius: 12, x: 0, y: 5)
        )
        .opacity(step.isAvailable ? 1 : 0.58)
    }

    private func targetHalo(frame: CGRect) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.055))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.32), lineWidth: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.orange.opacity(0.34), lineWidth: 1.5)
            }
            .shadow(color: Color.orange.opacity(0.42), radius: 18, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 8)
            .frame(width: frame.width + 20, height: frame.height + 20)
            .position(x: frame.midX, y: frame.midY + verticalOffset)
    }
}

private enum CoachMarkPlacement {
    case left
    case right
    case above
    case below

    var arrowSystemName: String {
        switch self {
        case .left:
            return "arrow.right"
        case .right:
            return "arrow.left"
        case .above:
            return "arrow.down"
        case .below:
            return "arrow.up"
        }
    }
}

private struct CoachMarkLayout {
    let targetFrame: CGRect
    let bubblePosition: CGPoint
    let arrowPosition: CGPoint
    let placement: CoachMarkPlacement
}

private struct GettingStartedStepRow: View {
    let step: GettingStartedStep
    let isCompleted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : step.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isCompleted ? .green : Color.accentColor)
                .frame(width: 22, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(step.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !isCompleted {
                Button(action: step.action) {
                    Text(step.actionTitle)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .disabled(!step.isAvailable)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
