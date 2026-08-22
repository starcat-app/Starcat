//
//  FirstRunWelcomeSheet.swift
//  Starcat
//
//  首次安装分步引导（4 步）：splash 淡出后占满整个主窗口，逐步讲清 Starcat
//  的核心能力（发现 → 理解 → 找回 → 沉淀），不高亮主界面控件。
//
//  步骤：发现项目 → AI 理解仓库 → 搜索找回 → 登录后沉淀知识库 →「浏览 / 登录」分流。
//
//  - 「浏览 / 登录 / 跳过」统一走欢迎退出动画后再露出主窗口（含欢迎收束短音效）
//
//  关键约束：
//  - overlay 根挂 `.appLocaleEnvironment()`（i18n 军规 #3）
//  - `.buttonStyle(.plain)` 必须 `.focusEffectDisabled()`
//  - 必须读 `\.starcatReduceMotion` 关闭步骤切换与入场动画
//

import SwiftUI
import AppKit

// MARK: - Preferences

/// 首次安装引导完成标记（UserDefaults，仅首次安装展示一次）。
///
/// 2026-06-19：key 从 `…FirstRunWelcome` 换为 `…StepGuide`，避免旧版单页 sheet
/// 测试时写入的标记阻止新版 4 步引导出现。Clean Build 不会清 UserDefaults。
enum FirstRunOnboardingPreferences {
    private static let hasCompletedKey = "onboarding.hasCompletedStepGuide"
    /// 只记录当前进程内 overlay 是否已经在展示或退出动画中。
    /// 不持久化到 UserDefaults，避免 App 在引导期间异常退出后把手动重播入口永久锁死。
    @MainActor private static var presentationActive = false

    static var shouldShow: Bool {
        !TestEnvironment.isRunning && !UserDefaults.standard.bool(forKey: hasCompletedKey)
    }

    @MainActor
    static var canReplayManually: Bool {
        !presentationActive
    }

    @MainActor
    static func beginPresentation() {
        presentationActive = true
    }

    @MainActor
    static func endPresentation() {
        presentationActive = false
    }

    /// 手动重播入口的统一保护。设置页和 Debug 菜单都走这里，避免 overlay 还没退出完
    /// 又叠加一次首次引导。
    @MainActor
    static func requestManualReplay() {
        guard canReplayManually else { return }
        resetForDebugReplay()
        NotificationCenter.default.post(
            name: debugReplayNotification,
            object: nil
        )
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: hasCompletedKey)
    }

    /// 重看首次引导：清标记并重置展示状态（Debug 菜单 / 设置页均可触发）。
    @MainActor
    static func resetForDebugReplay() {
        UserDefaults.standard.removeObject(forKey: hasCompletedKey)
        GettingStartedProgressStore.resetPersistedState()
    }

    /// 重看首次引导时广播；`LaunchSplashContainer` 监听并 present overlay。
    static let debugReplayNotification = Notification.Name("starcat.debug.replayFirstRunOnboarding")

    /// 首次引导选择「先逛 Trending」后广播给 `HomeView`，让已登录用户也能明确进入 Trending。
    static let browseTrendingNotification = Notification.Name("starcat.onboarding.browseTrending")
}

// MARK: - Environment

/// 主窗口是否处于 splash / 首次引导沉浸式覆盖态（用于隐藏 window toolbar）。
private struct FirstRunOnboardingActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// `LaunchSplashContainer` 注入；ContentView 读此值隐藏 `.windowToolbar`。
    var firstRunOnboardingActive: Bool {
        get { self[FirstRunOnboardingActiveKey.self] }
        set { self[FirstRunOnboardingActiveKey.self] = newValue }
    }
}

// MARK: - Exit Timing

/// 「开始使用 / 跳过」欢迎退出动画时序（集中调参）。
private enum FirstRunOnboardingExitTiming {
    /// 顶栏 / 底栏 / 步骤内容淡出。
    static let chromeFade: Duration = .milliseconds(520)
    /// 步骤内容收起后再切欢迎画面。
    static let stepCollapseHold: Duration = .milliseconds(220)
    /// 欢迎 Icon spring 入场后再显文案。
    static let welcomeTextDelay: Duration = .milliseconds(380)
    /// 欢迎画面停留（含脉冲光环）。
    static let welcomeHold: Duration = .milliseconds(1_900)
    /// 整层 overlay 淡出 + 放大 + 模糊。
    static let overlayFade: Duration = .milliseconds(2_100)
    /// reduceMotion 短路总时长。
    static let reduceMotionTotal: Duration = .milliseconds(420)
}

/// 退出动画阶段。
private enum FirstRunOnboardingExitPhase: Equatable {
    case none
    case welcome
    case fading
}

// MARK: - Step Model

private struct FirstRunOnboardingStep: Identifiable {
    let id: Int
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let highlights: [LocalizedStringKey]
    /// 用户后续提供的真实截图资源名。资源缺失时渲染同风格 fallback，避免发布包出现空白。
    let screenshotAssetName: String
    /// 真实截图未就位时的抽象预览类型；不展示「占位」字样，避免最终包看起来像未完成。
    let screenshotFallback: OnboardingScreenshotFallback
    /// 每步 hero 区强调色（与 About / splash 金色体系一致，逐步微调色相）。
    let tint: Color
}

/// 首次引导截图未就位时的抽象预览类型。
///
/// 后续 dong4j 提供截图后，只需要在 Assets.xcassets 放入同名 imageset；
/// 运行时会自动从 fallback 切换到真实截图。
private enum OnboardingScreenshotFallback {
    case discover
    case intelligence
    case search
    case library
    case rag
}

/// 首次引导完成后的用户意图，由 `LaunchSplashContainer` 统一映射到现有 App 入口。
///
/// 不把登录逻辑塞进 Onboarding View，是为了让引导层只负责表达和收束动画；
/// 真正的业务动作仍复用 App 根部已经装好的 `AuthSession` / `HomeView` 路由。
enum FirstRunOnboardingCompletion {
    case browseTrending
    case signIn
    case skip
}

// MARK: - Onboarding View

/// 首次运行 4 步引导，占满主窗口（由 `LaunchSplashContainer` 在 splash 结束后 present）。
struct FirstRunOnboardingView: View {

    var onFinish: (FirstRunOnboardingCompletion) -> Void = { _ in }
    /// 引导收束淡出开始时回调，供 `LaunchSplashContainer` 同步主窗口 blur → clear。
    var onMainContentRevealBegin: (() -> Void)? = nil

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var currentStep = 0
    @State private var stepRevealToken = 0
    @State private var glowDrift = false
    @State private var exitPhase: FirstRunOnboardingExitPhase = .none
    @State private var chromeOpacity: Double = 1
    @State private var overlayOpacity: Double = 1
    @State private var overlayScale: CGFloat = 1
    @State private var welcomeContentVisible = false
    @State private var welcomeTextVisible = false
    @State private var isExitInProgress = false
    @State private var stepContentOpacity: Double = 1
    @State private var stepContentScale: CGFloat = 1
    @State private var backdropIntensity: Double = 1
    @State private var exitBlurRadius: CGFloat = 0

    private let starGold = Color(red: 1.0, green: 0.74, blue: 0.28)

    /// 正文区最大阅读宽度，宽窗口下避免一行过长。
    private let contentMaxWidth: CGFloat = 560
    /// 底部操作栏最大宽度，与正文对齐。
    private let footerMaxWidth: CGFloat = 640

    private static let steps: [FirstRunOnboardingStep] = [
        FirstRunOnboardingStep(
            id: 0,
            systemImage: "chart.line.uptrend.xyaxis",
            title: "onboarding.step1.title",
            detail: "onboarding.step1.detail",
            highlights: [
                "onboarding.step1.highlight.trending",
                "onboarding.step1.highlight.weekly",
                "onboarding.step1.highlight.recommendations"
            ],
            screenshotAssetName: "OnboardingDiscover",
            screenshotFallback: .discover,
            tint: Color(red: 1.0, green: 0.74, blue: 0.28)
        ),
        FirstRunOnboardingStep(
            id: 1,
            systemImage: "sparkles",
            title: "onboarding.step2.title",
            detail: "onboarding.step2.detail",
            highlights: [
                "onboarding.step2.highlight.summary",
                "onboarding.step2.highlight.codeflow",
                "onboarding.step2.highlight.readme"
            ],
            screenshotAssetName: "OnboardingUnderstand",
            screenshotFallback: .intelligence,
            tint: Color(red: 0.98, green: 0.55, blue: 0.38)
        ),
        FirstRunOnboardingStep(
            id: 2,
            systemImage: "magnifyingglass.circle.fill",
            title: "onboarding.step3.title",
            detail: "onboarding.step3.detail",
            highlights: [
                "onboarding.step3.highlight.global",
                "onboarding.step3.highlight.semantic",
                "onboarding.step3.highlight.filters"
            ],
            screenshotAssetName: "OnboardingSearch",
            screenshotFallback: .search,
            tint: Color(red: 0.45, green: 0.78, blue: 1.0)
        ),
        FirstRunOnboardingStep(
            id: 3,
            systemImage: "tray.and.arrow.down.fill",
            title: "onboarding.step4.title",
            detail: "onboarding.step4.detail",
            highlights: [
                "onboarding.step4.highlight.sync",
                "onboarding.step4.highlight.notes",
                "onboarding.step4.highlight.releases"
            ],
            screenshotAssetName: "OnboardingLibrary",
            screenshotFallback: .library,
            tint: Color(red: 0.62, green: 0.88, blue: 0.55)
        ),
        FirstRunOnboardingStep(
            id: 4,
            systemImage: "quote.bubble.fill",
            title: "onboarding.step5.title",
            detail: "onboarding.step5.detail",
            highlights: [
                "onboarding.step5.highlight.scope",
                "onboarding.step5.highlight.answers",
                "onboarding.step5.highlight.citations"
            ],
            screenshotAssetName: "OnboardingRAG",
            screenshotFallback: .rag,
            tint: Color(red: 0.36, green: 0.78, blue: 0.76)
        )
    ]

    private var isLastStep: Bool {
        currentStep >= Self.steps.count - 1
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top

            ZStack {
                // 背景层向上溢出 safe area，盖住透明 window toolbar / titlebar 区域。
                fullWindowBackdrop
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.height + topInset
                    )
                    .offset(y: -topInset)

                VStack(spacing: 0) {
                    progressHeader
                        .padding(.top, topInset + 20)
                        .padding(.horizontal, 40)
                        .frame(maxWidth: footerMaxWidth)
                        .frame(maxWidth: .infinity)
                        .opacity(chromeOpacity)

                    Spacer(minLength: 24)

                    ZStack {
                        if exitPhase == .none {
                            stepContentArea
                                .opacity(stepContentOpacity)
                                .scaleEffect(stepContentScale)
                        } else {
                            FirstRunWelcomeExitPanel(
                                starGold: starGold,
                                reduceMotion: reduceMotion,
                                iconVisible: welcomeContentVisible,
                                textVisible: welcomeTextVisible
                            )
                            .padding(.horizontal, 40)
                            .frame(maxWidth: contentMaxWidth)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Spacer(minLength: 24)

                    actionBar
                        .padding(.horizontal, 40)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom + 24, 36))
                        .frame(maxWidth: footerMaxWidth)
                        .frame(maxWidth: .infinity)
                        .opacity(chromeOpacity)
                }
                .disabled(isExitInProgress)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(overlayScale, anchor: .center)
            .opacity(overlayOpacity)
            .blur(radius: exitBlurRadius)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .all)
        .contentShape(Rectangle())
        .defaultCursorShield()
        .onAppear {
            glowDrift = !reduceMotion
        }
    }

    // MARK: - Backdrop

    /// 铺满主窗口的装饰背景（星流 + 柔光），不拦截点击——交互由上层 VStack 承载。
    private var fullWindowBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            onboardingDotsFlowBackground
                .opacity(0.42 * backdropIntensity)
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    starGold.opacity(0.12 * backdropIntensity),
                    starGold.opacity(0.04 * backdropIntensity),
                    Color.clear
                ],
                center: .center,
                startRadius: 60,
                endRadius: 680
            )
            .ignoresSafeArea()
            .offset(x: glowDrift ? 24 : -20, y: glowDrift ? -16 : 18)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 8).repeatForever(autoreverses: true),
                value: glowDrift
            )
        }
        .allowsHitTesting(false)
    }

    /// 星流点阵：dark 走 gold + plusLighter；light 下 gold 加亮会融进白底，
    /// 改深琥珀 tint + multiply 压暗 window 背景，与 ShareCardSheet 同类方案。
    @ViewBuilder
    private var onboardingDotsFlowBackground: some View {
        if colorScheme == .dark {
            DotsFlowBackground(
                tint: starGold,
                background: .black,
                speed: 0.22,
                brightness: 0.65,
                dotSize: 0.9,
                gridDensity: 1.0,
                patternScale: 0.88,
                vignette: 0.35
            )
            .blendMode(.plusLighter)
        } else {
            DotsFlowBackground(
                tint: Color.fromHex6(0xB45309),
                background: .white,
                speed: 0.22,
                brightness: 0.72,
                dotSize: 0.9,
                gridDensity: 1.0,
                patternScale: 0.88,
                vignette: 0.35
            )
            .blendMode(.multiply)
        }
    }

    // MARK: - Progress

    /// 顶部居中进度胶囊条（步数文案已移至底栏两按钮之间）。
    private var progressHeader: some View {
        HStack(spacing: 8) {
            ForEach(Self.steps) { step in
                Capsule()
                    .fill(step.id <= currentStep ? Color.accentColor : Color.secondary.opacity(0.22))
                    .frame(width: step.id == currentStep ? 32 : 8, height: 8)
                    .animation(
                        reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.78),
                        value: currentStep
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var stepCounterLabel: String {
        String(format: String.l10n("onboarding.stepCounterFormat"), currentStep + 1, Self.steps.count)
    }

    // MARK: - Step Content

    private var stepContentArea: some View {
        ZStack {
            stepPanel(for: Self.steps[currentStep])
                .id("\(currentStep)-\(stepRevealToken)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .clipped()
        .animation(
            reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.86),
            value: currentStep
        )
    }

    private func stepPanel(for step: FirstRunOnboardingStep) -> some View {
        FirstRunOnboardingStepPanel(
            step: step,
            reduceMotion: reduceMotion
        )
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                )
        )
    }

    // MARK: - Actions

    private var actionBar: some View {
        Group {
            if isLastStep {
                lastStepActionBar
            } else {
                steppingActionBar
            }
        }
        .padding(.top, 20)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
    }

    /// 第 1–5 步：返回 │ 跳过 │ 步数 │ 下一步，四列对齐。
    private var steppingActionBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                backStepButton

                Button(action: { finish(.skip) }) {
                    Text("onboarding.action.skip")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .focusEffectDisabled()
                .disabled(isExitInProgress)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(stepCounterLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: currentStep)

            Button(action: advanceStep) {
                HStack(spacing: 5) {
                    Text("onboarding.action.next")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .focusEffectDisabled()
            .keyboardShortcut(.defaultAction)
            .disabled(isExitInProgress)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// 最后一步沿用前三列底部栏，避免 Step 文案在最终页突然上浮造成布局跳动。
    private var lastStepActionBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                backStepButton

                Button(action: { finish(.browseTrending) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "safari")
                            .font(.subheadline.weight(.semibold))
                        Text("onboarding.action.browseTrending")
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .frame(minWidth: 160)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .focusEffectDisabled()
                .disabled(isExitInProgress)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(stepCounterLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .center)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: currentStep)

            Button(action: { finish(.signIn) }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.subheadline.weight(.semibold))
                    Text("onboarding.action.signInSync")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .focusEffectDisabled()
            .keyboardShortcut(.defaultAction)
            .disabled(isExitInProgress)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var backStepButton: some View {
        Button(action: retreatStep) {
            Image(systemName: "chevron.left")
                .font(.subheadline.weight(.semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .focusEffectDisabled()
        .disabled(isExitInProgress || currentStep == 0)
        .opacity(currentStep == 0 ? 0.42 : 1)
        .help("onboarding.action.back")
    }

    // MARK: - Navigation

    private func retreatStep() {
        guard currentStep > 0 else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.86)) {
            currentStep -= 1
            stepRevealToken += 1
        }
    }

    private func advanceStep() {
        guard currentStep < Self.steps.count - 1 else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.86)) {
            currentStep += 1
            stepRevealToken += 1
        }
    }

    private func finish(_ completion: FirstRunOnboardingCompletion) {
        guard !isExitInProgress else { return }
        beginWelcomeExit(completion: completion)
    }

    /// 「浏览 / 登录 / 跳过」统一走欢迎收束动画，再移除 overlay 露出主窗口。
    private func beginWelcomeExit(completion: FirstRunOnboardingCompletion) {
        isExitInProgress = true
        // 点击时先登记播放，服务内部延迟 1s；4.8s 音效从欢迎画面延续到主窗口揭示。
        OnboardingWelcomeSound.playWelcomeIfAvailable()

        if reduceMotion {
            exitPhase = .welcome
            welcomeContentVisible = true
            welcomeTextVisible = true
            onMainContentRevealBegin?()
            overlayOpacity = 0
            Task { @MainActor in
                try? await Task.sleep(for: FirstRunOnboardingExitTiming.reduceMotionTotal)
                completeImmediately(completion)
            }
            return
        }

        // 1) 顶栏 / 底栏 + 当前步骤内容收起
        withAnimation(.easeOut(duration: 0.52)) {
            chromeOpacity = 0
            stepContentOpacity = 0
            stepContentScale = 0.94
        }

        Task { @MainActor in
            try? await Task.sleep(for: FirstRunOnboardingExitTiming.stepCollapseHold)

            // 2) 切到欢迎画面，背景星流提亮
            exitPhase = .welcome
            withAnimation(.easeInOut(duration: 0.85)) {
                backdropIntensity = 1.55
            }

            withAnimation(.spring(response: 0.82, dampingFraction: 0.68)) {
                welcomeContentVisible = true
            }

            try? await Task.sleep(for: FirstRunOnboardingExitTiming.welcomeTextDelay)
            withAnimation(.easeOut(duration: 0.62)) {
                welcomeTextVisible = true
            }

            try? await Task.sleep(for: FirstRunOnboardingExitTiming.welcomeHold)

            // 3) 整层放大 + 模糊 + 淡出；主窗口与 overlay 同步从 blur → clear
            exitPhase = .fading
            onMainContentRevealBegin?()
            withAnimation(.easeInOut(duration: 2.1)) {
                overlayOpacity = 0
                overlayScale = 1.1
                exitBlurRadius = 10
                backdropIntensity = 1.1
            }

            try? await Task.sleep(for: FirstRunOnboardingExitTiming.overlayFade)
            completeImmediately(completion)
        }
    }

    private func completeImmediately(_ completion: FirstRunOnboardingCompletion) {
        FirstRunOnboardingPreferences.markCompleted()
        onFinish(completion)
    }
}

// MARK: - Welcome Exit Panel

/// 「开始使用 / 跳过」后的欢迎收束画面：脉冲光环 + 大 App Icon + 欢迎文案。
private struct FirstRunWelcomeExitPanel: View {

    let starGold: Color
    let reduceMotion: Bool
    let iconVisible: Bool
    let textVisible: Bool

    @State private var pulseWave1: CGFloat = 0.75
    @State private var pulseWave2: CGFloat = 0.75
    @State private var pulseOpacity1: Double = 0.55
    @State private var pulseOpacity2: Double = 0.45

    var body: some View {
        VStack(spacing: 36) {
            ZStack {
                pulseRing(scale: pulseWave1, opacity: pulseOpacity1)
                pulseRing(scale: pulseWave2, opacity: pulseOpacity2)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                starGold.opacity(0.42),
                                starGold.opacity(0.14),
                                starGold.opacity(0)
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 180
                        )
                    )
                    .frame(width: 360, height: 360)
                    .scaleEffect(iconVisible ? 1 : 0.82)
                    .opacity(iconVisible ? 1 : 0)

                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 26, x: 0, y: 14)
                    .shadow(color: starGold.opacity(0.5), radius: 36, x: 0, y: 10)
                    .scaleEffect(iconVisible ? 1 : 0.62)
                    .opacity(iconVisible ? 1 : 0)
                    .rotationEffect(.degrees(iconVisible ? 0 : -8))
            }
            .frame(height: 320)
            .onChange(of: iconVisible) { _, visible in
                guard visible, !reduceMotion else { return }
                startPulseWaves()
            }

            VStack(spacing: 14) {
                Text("onboarding.exit.title")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                Text("onboarding.exit.subtitle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(textVisible ? 1 : 0)
            .offset(y: textVisible ? 0 : 26)
            .scaleEffect(textVisible ? 1 : 0.96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pulseRing(scale: CGFloat, opacity: Double) -> some View {
        Circle()
            .stroke(starGold.opacity(opacity), lineWidth: 2.5)
            .frame(width: 180, height: 180)
            .scaleEffect(scale)
            .opacity(iconVisible ? Double(max(0, 1.1 - scale)) : 0)
            .allowsHitTesting(false)
    }

    private func startPulseWaves() {
        pulseWave1 = 0.75
        pulseWave2 = 0.75
        pulseOpacity1 = 0.55
        pulseOpacity2 = 0.45

        withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
            pulseWave1 = 2.35
            pulseOpacity1 = 0
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
                pulseWave2 = 2.35
                pulseOpacity2 = 0
            }
        }
    }
}

// MARK: - Step Panel

/// 单步说明面板：能力说明 + 截图预览，带分步入场动画。
private struct FirstRunOnboardingStepPanel: View {

    let step: FirstRunOnboardingStep
    let reduceMotion: Bool

    private let narrativeWidth: CGFloat = 430
    private let horizontalPreviewWidth: CGFloat = 640
    private let horizontalPreviewHeight: CGFloat = 420
    private let verticalPreviewHeight: CGFloat = 320

    @State private var revealPhase = RevealPhase.hidden

    private enum RevealPhase: Int, Comparable {
        case hidden = 0
        case hero = 1
        case text = 2

        static func < (lhs: RevealPhase, rhs: RevealPhase) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 44) {
                narrativeColumn(alignment: .leading, textAlignment: .leading, chipAlignment: .leading)
                    // 六页文案高度不同；固定与右侧预览相同的高度并顶部对齐，
                    // 避免 HStack 默认居中导致 hero 图标在切页时上下漂移。
                    .frame(
                        width: narrativeWidth,
                        height: horizontalPreviewHeight,
                        alignment: .topLeading
                    )

                screenshotPreview
                    .frame(width: horizontalPreviewWidth, height: horizontalPreviewHeight)
            }

            VStack(spacing: 24) {
                narrativeColumn(alignment: .center, textAlignment: .center, chipAlignment: .center)
                    .frame(maxWidth: 560)

                screenshotPreview
                    .frame(maxWidth: 560)
                    .frame(height: verticalPreviewHeight)
            }
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { runEntrance() }
    }

    private func narrativeColumn(
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment,
        chipAlignment: Alignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 18) {
            heroVisual
                .scaleEffect(revealPhase >= .hero ? 1 : 0.82)
                .opacity(revealPhase >= .hero ? 1 : 0)

            VStack(alignment: alignment, spacing: 14) {
                Text(step.title)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(textAlignment)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(step.detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(textAlignment)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)

                highlightRow(alignment: chipAlignment)
            }
            .opacity(revealPhase >= .text ? 1 : 0)
            .offset(y: revealPhase >= .text ? 0 : 18)
        }
    }

    private var screenshotPreview: some View {
        OnboardingScreenshotPreview(step: step)
            .opacity(revealPhase >= .text ? 1 : 0)
            .offset(y: revealPhase >= .text ? 0 : 18)
    }

    private func highlightRow(alignment: Alignment) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(step.highlights.enumerated()), id: \.offset) { _, title in
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(step.tint.opacity(0.16))
                )
                .overlay {
                    Capsule(style: .continuous)
                        .stroke(step.tint.opacity(0.28), lineWidth: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment)
        .padding(.top, 4)
    }

    private var heroVisual: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            step.tint.opacity(0.32),
                            step.tint.opacity(0.10),
                            step.tint.opacity(0)
                        ],
                        center: .center,
                        startRadius: 12,
                        endRadius: 140
                    )
                )
                .frame(width: 180, height: 180)

            Circle()
                .fill(step.tint.opacity(0.12))
                .frame(width: 112, height: 112)
                .overlay {
                    Circle()
                        .stroke(step.tint.opacity(0.24), lineWidth: 1.5)
                }

            if reduceMotion {
                Image(systemName: step.systemImage)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(step.tint)
                    .frame(width: 56, height: 56, alignment: .center)
            } else {
                Image(systemName: step.systemImage)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(step.tint)
                    .frame(width: 56, height: 56, alignment: .center)
                    .symbolEffect(.bounce, value: revealPhase)
            }
        }
        .frame(width: 180, height: 180)
    }

    private func runEntrance() {
        if reduceMotion {
            revealPhase = .text
            return
        }

        withAnimation(.spring(response: 0.58, dampingFraction: 0.78)) {
            revealPhase = .hero
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(160))
            withAnimation(.easeOut(duration: 0.42)) {
                revealPhase = .text
            }
        }
    }
}

// MARK: - Screenshot Preview

/// 每步右侧的截图区域。
///
/// 真实截图资源命名约定：
/// - `OnboardingDiscover`
/// - `OnboardingUnderstand`
/// - `OnboardingSearch`
/// - `OnboardingLibrary`
/// - `OnboardingRAG`
///
/// 这里故意用运行时 `NSImage(named:)` 检测资源是否存在，而不是直接 `Image("...")`：
/// 正式资源缺失时仍保留 Swift fallback，避免资产目录异常导致首次引导出现空白。
private struct OnboardingScreenshotPreview: View {

    let step: FirstRunOnboardingStep

    var body: some View {
        ZStack {
            if let image = NSImage(named: NSImage.Name(step.screenshotAssetName)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    // 正式截图必须由承载层统一裁圆角，避免位图的矩形画布边界露出。
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                fallbackPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background {
            ZStack {
                // 外层负责四周均匀扩散；使用填充后模糊，避免形成可见描边。
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(step.tint.opacity(0.16))
                    .padding(-18)
                    .blur(radius: 52)

                // 内层保留截图与主题色的连接，让光晕切页时随 step.tint 一起过渡。
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                step.tint.opacity(0.30),
                                step.tint.opacity(0.10),
                                step.tint.opacity(0.24)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .padding(2)
                    .blur(radius: 28)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var fallbackPreview: some View {
        switch step.screenshotFallback {
        case .discover:
            discoverPreview
        case .intelligence:
            intelligencePreview
        case .search:
            searchPreview
        case .library:
            libraryPreview
        case .rag:
            ragPreview
        }
    }

    private var discoverPreview: some View {
        previewWindow(title: "Explore / Weekly") {
            HStack(alignment: .top, spacing: 14) {
                miniSidebar(selected: "Weekly")

                VStack(alignment: .leading, spacing: 10) {
                    segmentedHeader(items: [("flame.fill", "Hot"), ("newspaper.fill", "Weekly"), ("sparkles", "New")], selectedIndex: 1)
                    miniRepoCard(name: "open-science", subtitle: "Open AI workbench for researchers", icon: "atom", accent: step.tint, selected: true, chips: ["Python", "7.6"])
                    miniRepoCard(name: "video-use", subtitle: "Edit video with coding agents", icon: "play.rectangle.fill", accent: Color.orange, chips: ["TS", "15k"])
                    miniRepoCard(name: "browser-use", subtitle: "Automate browser tasks", icon: "safari.fill", accent: Color.blue, chips: ["AI", "25k"])
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    inspectorHeader(icon: "star.fill", title: "Trending Signal")
                    metricGrid([("Stars", "32k"), ("Forks", "613"), ("Score", "A")])
                    miniTagRow(["weekly", "ai", "tools"], tint: step.tint)
                    previewLine(width: 132, height: 7, opacity: 0.12)
                    previewLine(width: 164, height: 7, opacity: 0.10)
                }
                .padding(14)
                .frame(width: 180)
                .softPanel(accent: step.tint)
            }
        }
    }

    private var intelligencePreview: some View {
        previewWindow(title: "README + AI") {
            ZStack(alignment: .bottomTrailing) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        repoHeroStrip(icon: "sparkles", title: "ai4s-research / open-science", subtitle: "A local-first AI workbench")
                        codeBlockPreview
                        miniTagRow(["summary", "code flow", "README"], tint: step.tint)
                        previewLine(width: 300, height: 8, opacity: 0.11)
                        previewLine(width: 250, height: 8, opacity: 0.09)
                    }
                    .frame(maxWidth: .infinity)

                    nodeGraphPreview
                        .frame(width: 170, height: 210)
                        .softPanel(accent: Color.blue.opacity(0.8))
                }

                aiFloatingPanel
                    .frame(width: 245, height: 118)
                    .offset(x: -8, y: -4)
            }
        }
    }

    private var searchPreview: some View {
        previewWindow(title: "Global Search") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(step.tint)
                    Text(verbatim: "terminal ui library")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    statusChip("Semantic", tint: step.tint)
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                .softPanel(accent: step.tint)

                HStack(spacing: 12) {
                    searchModeTile(icon: "text.magnifyingglass", title: "Keyword", active: false)
                    searchModeTile(icon: "brain.head.profile", title: "Semantic", active: true)
                    searchModeTile(icon: "tag.fill", title: "Filters", active: false)
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 10) {
                        miniRepoCard(name: "awesome-terminal", subtitle: "Modern terminal frameworks", icon: "scope", accent: step.tint, selected: true, chips: ["Rust", "CLI"])
                        miniRepoCard(name: "agent-shell", subtitle: "Tool calling in local shells", icon: "point.3.connected.trianglepath.dotted", accent: Color.purple, chips: ["AI"])
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        inspectorHeader(icon: "line.3.horizontal.decrease.circle.fill", title: "Refine")
                        miniTagRow(["macOS", "AI", "terminal"], tint: step.tint)
                        previewLine(width: 150, height: 7, opacity: 0.12)
                        previewLine(width: 118, height: 7, opacity: 0.09)
                    }
                    .padding(14)
                    .frame(width: 170)
                    .softPanel(accent: step.tint)
                }
            }
        }
    }

    private var libraryPreview: some View {
        previewWindow(title: "Library") {
            HStack(alignment: .top, spacing: 14) {
                miniSidebar(selected: "Library")

                VStack(spacing: 12) {
                    miniRepoCard(name: "BetterDisplay", subtitle: "Display control, extra brightness", icon: "heart.fill", accent: step.tint, selected: true, chips: ["Library"])
                    miniRepoCard(name: "swift-markdown", subtitle: "Render docs and README", icon: "bookmark.fill", accent: Color.blue, chips: ["Read"])
                    miniRepoCard(name: "release-monitor", subtitle: "Track updates and changelogs", icon: "bell.badge.fill", accent: Color.green, chips: ["Watch"])
                }

                VStack(alignment: .leading, spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 54, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    inspectorHeader(icon: "tray.and.arrow.down.fill", title: "Saved Knowledge")
                    miniTagRow(["display", "macOS", "using"], tint: step.tint)
                    noteCard(title: "Private note", icon: "note.text")
                    noteCard(title: "Release watch", icon: "bell.fill")
                }
                .padding(14)
                .frame(width: 190)
                .softPanel(accent: step.tint)
            }
        }
    }

    private var ragPreview: some View {
        previewWindow(title: "RAG Workspace") {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    questionBubble("Which saved repos help with local AI search?")
                    answerCard
                    HStack(spacing: 8) {
                        statusChip("Answer", tint: step.tint)
                        statusChip("Citations", tint: Color.blue)
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    inspectorHeader(icon: "quote.bubble.fill", title: "Citations")
                    citationRow(index: 1, title: "open-science", tint: step.tint)
                    citationRow(index: 2, title: "llama.cpp", tint: Color.blue)
                    citationRow(index: 3, title: "ragflow", tint: Color.green)
                }
                .padding(14)
                .frame(width: 190)
                .softPanel(accent: step.tint)
            }
        }
    }

    private func previewWindow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            previewChrome(title: title)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 14)

            content()
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private func previewChrome(title: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(Color.red.opacity(0.5)).frame(width: 8, height: 8)
            Circle().fill(Color.yellow.opacity(0.55)).frame(width: 8, height: 8)
            Circle().fill(Color.green.opacity(0.5)).frame(width: 8, height: 8)
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)
            Spacer()
            toolbarIcon("line.3.horizontal.decrease.circle")
            toolbarIcon("magnifyingglass")
        }
    }

    private var nodeGraphPreview: some View {
        ZStack {
            ForEach(0..<7, id: \.self) { index in
                Circle()
                    .fill(index == 0 ? step.tint.opacity(0.85) : Color.primary.opacity(0.13))
                    .frame(width: index == 0 ? 42 : 28, height: index == 0 ? 42 : 28)
                    .offset(nodeOffset(index))
            }

            Path { path in
                path.move(to: CGPoint(x: 95, y: 92))
                path.addLine(to: CGPoint(x: 38, y: 40))
                path.move(to: CGPoint(x: 95, y: 92))
                path.addLine(to: CGPoint(x: 152, y: 45))
                path.move(to: CGPoint(x: 95, y: 92))
                path.addLine(to: CGPoint(x: 56, y: 152))
                path.move(to: CGPoint(x: 95, y: 92))
                path.addLine(to: CGPoint(x: 152, y: 148))
            }
            .stroke(step.tint.opacity(0.28), lineWidth: 1.4)
        }
        .frame(width: 190, height: 188)
    }

    private var aiFloatingPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorHeader(icon: "sparkles", title: "AI Summary")
            previewLine(width: 178, height: 8, opacity: 0.20)
            previewLine(width: 206, height: 7, opacity: 0.12)
            previewLine(width: 146, height: 7, opacity: 0.10)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: step.tint.opacity(0.24), radius: 18, x: 0, y: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(step.tint.opacity(0.32), lineWidth: 1)
        }
    }

    private var codeBlockPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            previewLine(width: 232, height: 8, opacity: 0.16)
            previewLine(width: 288, height: 8, opacity: 0.12)
            previewLine(width: 198, height: 8, opacity: 0.10)
            previewLine(width: 260, height: 8, opacity: 0.09)
        }
        .padding(14)
        .frame(height: 110, alignment: .topLeading)
        .softPanel(accent: step.tint)
    }

    private var answerCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            previewLine(width: 262, height: 8, opacity: 0.18)
            previewLine(width: 318, height: 8, opacity: 0.12)
            previewLine(width: 286, height: 8, opacity: 0.10)
            HStack(spacing: 6) {
                citationBadge(1, tint: step.tint)
                citationBadge(2, tint: Color.blue)
                citationBadge(3, tint: Color.green)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .softPanel(accent: step.tint)
    }

    private func miniSidebar(selected: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sidebarItem(icon: "star.fill", title: "Stars", selected: selected == "Stars")
            sidebarItem(icon: "safari.fill", title: "Explore", selected: selected == "Explore")
            sidebarItem(icon: "newspaper.fill", title: "Weekly", selected: selected == "Weekly")
            sidebarItem(icon: "tray.and.arrow.down.fill", title: "Library", selected: selected == "Library")
            Spacer(minLength: 0)
            sidebarItem(icon: "tag.fill", title: "Tags", selected: false)
        }
        .padding(10)
        .frame(width: 124)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .softPanel(accent: step.tint)
    }

    private func sidebarItem(icon: String, title: String, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? step.tint : .secondary)
                .frame(width: 14)
            Text(verbatim: title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? .primary : .secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? step.tint.opacity(0.18) : Color.clear)
        )
    }

    private func segmentedHeader(items: [(String, String)], selectedIndex: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 6) {
                    Image(systemName: item.0)
                    Text(verbatim: item.1)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(index == selectedIndex ? step.tint : .secondary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background {
                    previewCardBackground(
                        cornerRadius: 9,
                        tint: index == selectedIndex ? step.tint : nil,
                        tintOpacity: 0.14
                    )
                }
            }
        }
    }

    private func miniRepoCard(
        name: String,
        subtitle: String,
        icon: String,
        accent: Color,
        selected: Bool = false,
        chips: [String] = []
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accent.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(verbatim: subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { chip in
                        statusChip(chip, tint: accent)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(11)
        .background {
            previewCardBackground(
                cornerRadius: 13,
                tint: selected ? accent : nil,
                tintOpacity: 0.14
            )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(selected ? accent.opacity(0.34) : Color.white.opacity(0.06), lineWidth: 1)
        }
    }

    private func repoHeroStrip(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(step.tint)
                .frame(width: 42, height: 42)
                .background(step.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(verbatim: subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .softPanel(accent: step.tint)
    }

    private func searchModeTile(icon: String, title: String, active: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
            Text(verbatim: title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(active ? step.tint : .secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 62)
        .background {
            previewCardBackground(
                cornerRadius: 13,
                tint: active ? step.tint : nil,
                tintOpacity: 0.14
            )
        }
    }

    private func metricGrid(_ metrics: [(String, String)]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                VStack(spacing: 3) {
                    Text(verbatim: metric.1)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(verbatim: metric.0)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background {
                    previewCardBackground(cornerRadius: 10)
                }
            }
        }
    }

    private func miniTagRow(_ tags: [String], tint: Color) -> some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                statusChip(tag, tint: tint)
            }
        }
    }

    private func statusChip(_ text: String, tint: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(tint.opacity(0.13), in: Capsule(style: .continuous))
    }

    private func inspectorHeader(icon: String, title: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(step.tint)
            Text(verbatim: title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    private func noteCard(title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(step.tint)
            Text(verbatim: title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background {
            previewCardBackground(cornerRadius: 10)
        }
    }

    private func questionBubble(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .softPanel(accent: step.tint)
    }

    private func citationRow(index: Int, title: String, tint: Color) -> some View {
        HStack(spacing: 9) {
            citationBadge(index, tint: tint)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                previewLine(width: 96, height: 6, opacity: 0.10)
            }
            Spacer()
        }
        .padding(10)
        .background {
            previewCardBackground(cornerRadius: 10)
        }
    }

    private func citationBadge(_ index: Int, tint: Color) -> some View {
        Text(verbatim: "\(index)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(tint.opacity(0.14), in: Circle())
    }

    private func toolbarIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.primary.opacity(0.08), in: Circle())
    }

    private func previewLine(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.primary.opacity(opacity))
            .frame(width: width, height: height)
    }

    /// 卡片先铺适度中灰层，再叠加状态色，在背景氛围与卡片层级之间保持平衡。
    @ViewBuilder
    private func previewCardBackground(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        tintOpacity: Double = 0
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        shape
            .fill(Color.primary.opacity(0.08))
            .overlay {
                if let tint {
                    shape.fill(tint.opacity(tintOpacity))
                }
            }
    }

    private func nodeOffset(_ index: Int) -> CGSize {
        switch index {
        case 1: return CGSize(width: -57, height: -52)
        case 2: return CGSize(width: 57, height: -47)
        case 3: return CGSize(width: -39, height: 60)
        case 4: return CGSize(width: 57, height: 56)
        case 5: return CGSize(width: -72, height: 9)
        case 6: return CGSize(width: 74, height: 5)
        default: return .zero
        }
    }
}

private extension View {
    func softPanel(accent: Color) -> some View {
        background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.20), lineWidth: 1)
        }
    }
}

// MARK: - Preview

#Preview("First Run Onboarding") {
    FirstRunOnboardingView()
        .appLocaleEnvironment()
        .frame(
            minWidth: MainWindowFrameDefaults.contentMinSize.width,
            minHeight: MainWindowFrameDefaults.contentMinSize.height
        )
}
