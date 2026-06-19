//
//  FirstRunWelcomeSheet.swift
//  Starcat
//
//  首次安装分步引导（4 步）：splash 淡出后占满整个主窗口，逐步切换说明内容
//  （不高亮主界面控件），带步骤进度、滑入切换与每步入场动画。
//
//  步骤：欢迎 → Trending → 登录同步 → 标签搜索 →「开始使用」
//
//  - 「开始使用 / 跳过」统一走欢迎退出动画后再露出主窗口（含欢迎收束短音效）
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

    static var shouldShow: Bool {
        !TestEnvironment.isRunning && !UserDefaults.standard.bool(forKey: hasCompletedKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: hasCompletedKey)
    }

    #if DEBUG
    /// Debug 菜单「重看首次引导」用：清标记并重置展示状态。
    static func resetForDebugReplay() {
        UserDefaults.standard.removeObject(forKey: hasCompletedKey)
    }

    /// Debug 菜单触发重看时广播；`LaunchSplashContainer` 监听并 present overlay。
    static let debugReplayNotification = Notification.Name("starcat.debug.replayFirstRunOnboarding")
    #endif
}

// MARK: - Environment

/// 主窗口是否处于 splash / 首次引导等沉浸式覆盖态（用于隐藏 window toolbar）。
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
    /// 每步 hero 区强调色（与 About / splash 金色体系一致，逐步微调色相）。
    let tint: Color
    /// 第 0 步用 App Icon 替代 SF Symbol。
    let usesAppIcon: Bool
}

// MARK: - Onboarding View

/// 首次运行 4 步引导，占满主窗口（由 `LaunchSplashContainer` 在 splash 结束后 present）。
struct FirstRunOnboardingView: View {

    var onFinish: () -> Void = {}

    @Environment(\.starcatReduceMotion) private var reduceMotion

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
            systemImage: "star.fill",
            title: "onboarding.step1.title",
            detail: "onboarding.step1.detail",
            tint: Color(red: 1.0, green: 0.74, blue: 0.28),
            usesAppIcon: true
        ),
        FirstRunOnboardingStep(
            id: 1,
            systemImage: "chart.line.uptrend.xyaxis",
            title: "onboarding.step2.title",
            detail: "onboarding.step2.detail",
            tint: Color(red: 0.98, green: 0.55, blue: 0.38),
            usesAppIcon: false
        ),
        FirstRunOnboardingStep(
            id: 2,
            systemImage: "arrow.triangle.2.circlepath",
            title: "onboarding.step3.title",
            detail: "onboarding.step3.detail",
            tint: Color(red: 0.45, green: 0.78, blue: 1.0),
            usesAppIcon: false
        ),
        FirstRunOnboardingStep(
            id: 3,
            systemImage: "tag.fill",
            title: "onboarding.step4.title",
            detail: "onboarding.step4.detail",
            tint: Color(red: 0.62, green: 0.88, blue: 0.55),
            usesAppIcon: false
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

    /// 第 1–3 步：跳过 │ 步数 │ 下一步，三列对齐。
    private var steppingActionBar: some View {
        HStack(spacing: 16) {
            Button(action: finish) {
                Text("onboarding.action.skip")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .focusEffectDisabled()
            .disabled(isExitInProgress)
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

    /// 第 4 步：步数居中 +「开始使用」。
    private var lastStepActionBar: some View {
        VStack(spacing: 14) {
            Text(stepCounterLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: currentStep)

            Button(action: finish) {
                Text("onboarding.action.getStarted")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .focusEffectDisabled()
            .keyboardShortcut(.defaultAction)
            .disabled(isExitInProgress)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Navigation

    private func advanceStep() {
        guard currentStep < Self.steps.count - 1 else { return }
        withAnimation(reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.86)) {
            currentStep += 1
            stepRevealToken += 1
        }
    }

    private func finish() {
        guard !isExitInProgress else { return }
        beginWelcomeExit()
    }

    /// 「开始使用 / 跳过」统一走欢迎收束动画，再移除 overlay 露出主窗口。
    private func beginWelcomeExit() {
        isExitInProgress = true
        // 点击瞬间即播，贯穿后续收起 → 欢迎 → 淡出整段动画（约 3.2s 音效 + 视觉 ~5s）
        OnboardingWelcomeSound.playWelcomeIfAvailable()

        if reduceMotion {
            exitPhase = .welcome
            welcomeContentVisible = true
            welcomeTextVisible = true
            overlayOpacity = 0
            Task { @MainActor in
                try? await Task.sleep(for: FirstRunOnboardingExitTiming.reduceMotionTotal)
                completeImmediately()
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

            // 3) 整层放大 + 模糊 + 淡出，主窗口从下方渐露
            exitPhase = .fading
            withAnimation(.easeInOut(duration: 2.1)) {
                overlayOpacity = 0
                overlayScale = 1.1
                exitBlurRadius = 10
                backdropIntensity = 1.1
            }

            try? await Task.sleep(for: FirstRunOnboardingExitTiming.overlayFade)
            completeImmediately()
        }
    }

    private func completeImmediately() {
        FirstRunOnboardingPreferences.markCompleted()
        onFinish()
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

/// 单步说明面板：hero 图标区 + 标题 + 正文，带分步入场动画。
private struct FirstRunOnboardingStepPanel: View {

    let step: FirstRunOnboardingStep
    let reduceMotion: Bool

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
        VStack(spacing: 28) {
            heroVisual
                .scaleEffect(revealPhase >= .hero ? 1 : 0.82)
                .opacity(revealPhase >= .hero ? 1 : 0)

            VStack(spacing: 14) {
                Text(step.title)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                Text(step.detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .opacity(revealPhase >= .text ? 1 : 0)
            .offset(y: revealPhase >= .text ? 0 : 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { runEntrance() }
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
                .frame(width: 280, height: 280)

            Circle()
                .fill(step.tint.opacity(0.12))
                .frame(width: 168, height: 168)
                .overlay {
                    Circle()
                        .stroke(step.tint.opacity(0.24), lineWidth: 1.5)
                }

            if step.usesAppIcon {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 10)
                    .shadow(color: step.tint.opacity(0.35), radius: 24, x: 0, y: 6)
            } else if reduceMotion {
                Image(systemName: step.systemImage)
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(step.tint)
            } else {
                Image(systemName: step.systemImage)
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(step.tint)
                    .symbolEffect(.bounce, value: revealPhase)
            }
        }
        .frame(height: 280)
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

// MARK: - Preview

#Preview("First Run Onboarding") {
    FirstRunOnboardingView()
        .appLocaleEnvironment()
        .frame(
            minWidth: MainWindowFrameDefaults.contentMinSize.width,
            minHeight: MainWindowFrameDefaults.contentMinSize.height
        )
}
