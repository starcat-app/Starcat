//
//  LaunchSplashView.swift
//  Starcat
//
//  冷启动全屏过渡动画：Metal 星流背景 + 品牌金色柔光 + App Icon 弹入 + 文案渐显。
//
//  挂载方式：`LaunchSplashContainer` 包住 `ContentView`，在 AuthSession restore
//  与最短展示时长均完成后淡出移除。测试 host（`TestEnvironment.isRunning`）跳过，
//  避免拖慢 xcodebuild test 启动链路。
//
//  关键约束：
//  - 必须读 `\.starcatReduceMotion`：关动画时入口瞬显、退出无 transition
//  - `LaunchSplashContainer` 放在 `.id(localeStore...)` **外层**，避免切语言时重播
//  - 全屏 overlay 需 `ignoresSafeArea()` 盖住 window toolbar 区域
//  - Auth restore 从 `StarcatApp` 迁入 Container 的 `.task`，避免与 splash 时序分叉
//  - 首次冷启动最短展示更长，且已登录时尽量等到 sync 首页写入再淡出（有超时兜底）
//

import SwiftUI
import AppKit

// MARK: - Timing

/// 启动 splash 时序常量（集中一处，方便产品调参）。
private enum LaunchSplashTiming {
    /// 常规冷启动最短展示（含入口动画 + 品牌停留）。
    static let standardMinimum: Duration = .milliseconds(1_500)
    /// 首次冷启动最短展示——给 Trending / 首屏 sync 多留缓冲。
    static let firstLaunchMinimum: Duration = .milliseconds(2_800)
    /// 关动画时的最短展示。
    static let reduceMotionMinimum: Duration = .milliseconds(120)
    /// 首次启动 + 已登录：在 standard/first minimum 之后，额外等 sync 首页的最长上限。
    static let firstLaunchDataWaitCap: Duration = .milliseconds(3_200)
    /// 首次启动 + 未登录：Trending 在 splash 下方异步拉取，额外多等一小段。
    static let firstLaunchTrendingGrace: Duration = .milliseconds(900)
    /// 淡出 transition 时长（与 `.animation(..., value: isSplashVisible)` 对齐）。
    static let dismissAnimationSeconds = 0.56
    /// 轮询 sync 首页是否就绪的间隔。
    static let dataPollInterval: Duration = .milliseconds(80)
}

/// 首次冷启动标记（仅用于 splash 时序，不影响业务逻辑）。
private enum LaunchSplashPreferences {
    private static let hasCompletedColdStartKey = "launchSplash.hasCompletedColdStart"

    static var isFirstColdStart: Bool {
        !UserDefaults.standard.bool(forKey: hasCompletedColdStartKey)
    }

    static func markColdStartCompleted() {
        UserDefaults.standard.set(true, forKey: hasCompletedColdStartKey)
    }
}

// MARK: - Container

/// 冷启动 splash 容器：子内容立即可见（被 overlay 遮住），就绪后淡出 splash。
struct LaunchSplashContainer<Content: View>: View {

    @ViewBuilder private let content: () -> Content

    @Environment(AuthSession.self) private var authSession
    @Environment(SyncManager.self) private var syncManager
    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 测试 host 直接跳过；正常冷启动从 true 开始，`.task` 结束后置 false。
    @State private var isSplashVisible = !TestEnvironment.isRunning
    /// splash 时序是否已跑完（与 overlay 是否可见解耦，供 onboarding 单独监听）。
    @State private var splashSequenceFinished = TestEnvironment.isRunning
    /// splash 淡出后、首次安装时展示分步引导 overlay。
    @State private var showFirstRunOnboarding = false

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            content()

            if isSplashVisible {
                LaunchSplashView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .all)
                    .transition(
                        reduceMotion
                            ? .identity
                            : .opacity.combined(with: .scale(scale: 1.015))
                    )
                    .zIndex(999)
            }
            if showFirstRunOnboarding {
                FirstRunOnboardingView {
                    showFirstRunOnboarding = false
                }
                .appLocaleEnvironment()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .all)
                .transition(reduceMotion ? .identity : .opacity)
                .zIndex(1_000)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.firstRunOnboardingActive, showFirstRunOnboarding || isSplashVisible)
        .animation(
            reduceMotion ? nil : .easeOut(duration: LaunchSplashTiming.dismissAnimationSeconds),
            value: isSplashVisible
        )
        .task {
            await runSplashSequenceIfNeeded()
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: FirstRunOnboardingPreferences.debugReplayNotification)) { _ in
            FirstRunOnboardingPreferences.resetForDebugReplay()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.42)) {
                showFirstRunOnboarding = true
            }
        }
        #endif
    }

    /// 冷启动 splash 时序；完成后置 `splashSequenceFinished`，onboarding 由 onChange 触发。
    private func runSplashSequenceIfNeeded() async {
        guard !TestEnvironment.isRunning else {
            splashSequenceFinished = true
            return
        }

        guard isSplashVisible else {
            splashSequenceFinished = true
            return
        }

        let isFirstLaunch = LaunchSplashPreferences.isFirstColdStart
        let minimumDisplay: Duration = {
            if reduceMotion { return LaunchSplashTiming.reduceMotionMinimum }
            return isFirstLaunch ? LaunchSplashTiming.firstLaunchMinimum : LaunchSplashTiming.standardMinimum
        }()

        async let restore: Void = authSession.restoreSessionIfAvailable()
        async let minWait: Void = {
            try? await Task.sleep(for: minimumDisplay)
        }()
        _ = await (restore, minWait)

        if isFirstLaunch {
            await waitForWarmContentIfNeeded()
        }

        LaunchSplashPreferences.markColdStartCompleted()
        isSplashVisible = false
        splashSequenceFinished = true
        await presentFirstRunOnboardingIfNeeded()
    }

    /// splash 淡出动画结束后再展示首次安装分步引导 overlay。
    private func presentFirstRunOnboardingIfNeeded() async {
        guard FirstRunOnboardingPreferences.shouldShow else { return }

        let postSplashDelay: Duration = reduceMotion ? .zero : .milliseconds(520)
        try? await Task.sleep(for: postSplashDelay)

        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.42)) {
            showFirstRunOnboarding = true
        }
    }

    /// 首次启动在 minimum 之后继续等首屏数据，避免 splash 一撤就露出 loading 骨架。
    ///
    /// HomeView 在 splash overlay 下方已挂载：auth restore 完成后会触发 sync /
    /// Trending reload，这里轮询 `firstPageWrittenAt` 或 sync 终态，超时则强制淡出。
    private func waitForWarmContentIfNeeded() async {
        if authSession.state.isAuthenticated {
            let deadline = ContinuousClock.now + LaunchSplashTiming.firstLaunchDataWaitCap
            while ContinuousClock.now < deadline {
                if syncManager.firstPageWrittenAt != nil { return }
                switch syncManager.state {
                case .completed, .failed:
                    return
                case .idle, .syncing, .rateLimited:
                    break
                }
                try? await Task.sleep(for: LaunchSplashTiming.dataPollInterval)
            }
            return
        }

        // 未登录首启默认进 Trending，无精确就绪信号，靠额外 grace 降低「空白 → 骨架」闪烁。
        try? await Task.sleep(for: LaunchSplashTiming.firstLaunchTrendingGrace)
    }
}

// MARK: - Splash View

/// 启动过渡视觉层（纯展示，时序由 `LaunchSplashContainer` 控制）。
struct LaunchSplashView: View {

    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 分阶段揭示：hidden → icon → text → complete
    @State private var revealPhase = RevealPhase.hidden
    @State private var glowDrift = false

    /// 与 About 页品牌区同源的金色，保持 Starcat 视觉一致性。
    private let starGold = Color(red: 1.0, green: 0.74, blue: 0.28)

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            // Metal 星流：黑底 + plusLighter 只留亮点，叠在 window 背景上
            DotsFlowBackground(
                tint: starGold,
                background: .black,
                speed: 0.28,
                brightness: 0.75,
                dotSize: 0.95,
                gridDensity: 1.05,
                patternScale: 0.92,
                vignette: 0.35
            )
            .blendMode(.plusLighter)
            .opacity(0.42)
            .ignoresSafeArea()

            brandGlowLayer

            VStack(spacing: 16) {
                appIcon
                    .scaleEffect(revealPhase >= .icon ? 1 : 0.76)
                    .opacity(revealPhase >= .icon ? 1 : 0)

                VStack(spacing: 7) {
                    Text("Starcat")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text("about.brand.slogan")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 320)
                }
                .opacity(revealPhase >= .text ? 1 : 0)
                .offset(y: revealPhase >= .text ? 0 : 10)
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
        .onAppear { runEntranceSequence() }
    }

    // MARK: - Subviews

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 96, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 12)
            .shadow(color: starGold.opacity(0.35), radius: 28, x: 0, y: 4)
    }

    /// Icon 背后的双层金色柔光，reduceMotion 时静态居中。
    private var brandGlowLayer: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                glowOrb(
                    color: starGold.opacity(0.16),
                    diameter: min(size.width, size.height) * 0.72,
                    offset: glowDrift ? CGPoint(x: 12, y: -8) : CGPoint(x: -10, y: 10)
                )
                glowOrb(
                    color: starGold.opacity(0.09),
                    diameter: min(size.width, size.height) * 0.95,
                    offset: glowDrift ? CGPoint(x: -14, y: 12) : CGPoint(x: 16, y: -10)
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .blur(radius: 36)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 7.5).repeatForever(autoreverses: true),
                value: glowDrift
            )
        }
        .allowsHitTesting(false)
    }

    private func glowOrb(color: Color, diameter: CGFloat, offset: CGPoint) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color, color.opacity(0.4), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter * 0.5
                )
            )
            .frame(width: diameter, height: diameter)
            .offset(x: offset.x, y: offset.y)
    }

    // MARK: - Entrance

    private func runEntranceSequence() {
        if reduceMotion {
            revealPhase = .complete
            return
        }

        glowDrift = true

        withAnimation(.spring(response: 0.62, dampingFraction: 0.78)) {
            revealPhase = .icon
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.easeOut(duration: 0.42)) {
                revealPhase = .text
            }
            try? await Task.sleep(for: .milliseconds(320))
            revealPhase = .complete
        }
    }
}

// MARK: - Reveal Phase

private enum RevealPhase: Int, Comparable {
    case hidden = 0
    case icon = 1
    case text = 2
    case complete = 3

    static func < (lhs: RevealPhase, rhs: RevealPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Preview

#Preview("Launch Splash") {
    LaunchSplashView()
        .frame(width: 960, height: 640)
        .starcatAnimationOverride()
        .environment(AppSettings())
}
