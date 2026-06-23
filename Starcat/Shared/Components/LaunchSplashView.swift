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
//  - splash / 引导期间隐藏 window toolbar（overlay 盖不住 AppKit 标题栏层）
//  - Manage 排序行在 safeAreaInset；标题仍走 `.navigationTitle`，与 Trending 顶区对齐
//  - Auth restore 从 `StarcatApp` 迁入 Container 的 `.task`，避免与 splash 时序分叉
//  - 首次冷启动最短展示更长，且已登录时尽量等到 sync 首页写入再淡出（有超时兜底）
//  - Auth restore 网络请求不能无限阻塞 splash；启动页有独立超时，避免离线 / GitHub 慢响应时卡首屏
//  - 主窗口 content 在 splash 下保持清晰（不透明 overlay 已完全遮挡）；仅首次引导
//    收束淡出时才 blur → clear 渐显，避免冷启动 splash 撤下时顶栏与列表顶区错层跳动
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
    /// Auth restore 最多占用 splash 的时间。超时后进入主界面，token 仍由 AuthSession 自己决定保留或清理。
    static let authRestoreWaitCap: Duration = .seconds(3)
    /// 淡出 transition 时长（与 `.animation(..., value: isSplashVisible)` 对齐）。
    static let dismissAnimationSeconds = 0.56
    /// splash 撤下后主窗口「模糊 → 清晰」时长（略长于 splash 淡出，形成交叠）。
    static let mainContentRevealSeconds = 0.72
    /// 引导收束淡出阶段主窗口变清晰时长（与 `FirstRunOnboardingExitTiming.overlayFade` 对齐）。
    static let onboardingMainContentRevealSeconds = 2.1
    /// 主窗口被 overlay 遮住时的最大 blur（pt）。
    static let mainContentObscuredBlurRadius: CGFloat = 14
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

/// splash 等待 Auth restore 时使用的一次性回调闸门。
///
/// 这里不用 `withTaskGroup` race，是因为 task group 离开作用域前仍会等待子任务结束；
/// 如果被取消的网络请求没有立刻收尾，仍可能把启动页拖住。这个 actor 只负责保证
/// restore 完成和 timeout 两条非结构化路径里只有第一条能恢复 continuation。
private actor LaunchSplashRestoreGate {
    private var hasResumed = false

    func resumeOnce(_ continuation: CheckedContinuation<Bool, Never>, result: Bool) {
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(returning: result)
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
    /// 0 = 首次引导收束期主窗口模糊，1 = 完全清晰。冷启动 splash 期间保持 1——
    /// splash 本身不透明，无需在底下再做 blur/scale，否则淡出时会露出错层顶栏。
    @State private var mainContentRevealProgress: Double = 1

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ZStack {
            obscuredMainContent

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
                FirstRunOnboardingView(
                    onFinish: { completion in
                        showFirstRunOnboarding = false
                        handleFirstRunCompletion(completion)
                    },
                    onMainContentRevealBegin: {
                        revealMainContent(
                            duration: LaunchSplashTiming.onboardingMainContentRevealSeconds,
                            curve: .easeInOut(duration: LaunchSplashTiming.onboardingMainContentRevealSeconds)
                        )
                    }
                )
                .appLocaleEnvironment()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .all)
                .transition(reduceMotion ? .identity : .opacity)
                .zIndex(1_000)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // splash / 引导期间隐藏 window toolbar。排序行在 safeAreaInset，标题走系统 navigation chrome。
        .environment(\.firstRunOnboardingActive, showFirstRunOnboarding || isSplashVisible)
        .animation(
            reduceMotion ? nil : .easeOut(duration: LaunchSplashTiming.dismissAnimationSeconds),
            value: isSplashVisible
        )
        .task {
            await runSplashSequenceIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: FirstRunOnboardingPreferences.debugReplayNotification)) { _ in
            FirstRunOnboardingPreferences.resetForDebugReplay()
            obscureMainContent()
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.42)) {
                showFirstRunOnboarding = true
            }
        }
    }

    /// 主窗口 content：仅首次引导收束时做 blur / 透明度渐显；冷启动不做 scale，
    /// 避免 NavigationSplitView 顶栏在缩放期间与列表顶区错层。
    private var obscuredMainContent: some View {
        content()
            .blur(radius: mainContentBlurRadius)
            .opacity(mainContentOpacity)
    }

    private var mainContentBlurRadius: CGFloat {
        guard !reduceMotion else { return 0 }
        return LaunchSplashTiming.mainContentObscuredBlurRadius * CGFloat(1 - mainContentRevealProgress)
    }

    private var mainContentOpacity: Double {
        guard !reduceMotion else { return 1 }
        return 0.76 + 0.24 * mainContentRevealProgress
    }

    private func obscureMainContent() {
        guard !reduceMotion else { return }
        mainContentRevealProgress = 0
    }

    private func revealMainContent(duration: TimeInterval, curve: Animation) {
        if reduceMotion {
            mainContentRevealProgress = 1
            return
        }
        withAnimation(curve) {
            mainContentRevealProgress = 1
        }
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

        async let restoreCompleted: Bool = restoreSessionWithinSplashBudget()
        async let minWait: Void = {
            try? await Task.sleep(for: minimumDisplay)
        }()
        let (didFinishRestore, _) = await (restoreCompleted, minWait)

        if !didFinishRestore {
            AppLog.auth.warning("restore: splash budget exceeded; continuing startup without blocking UI")
        }

        if isFirstLaunch {
            await waitForWarmContentIfNeeded()
        }

        LaunchSplashPreferences.markColdStartCompleted()
        isSplashVisible = false
        splashSequenceFinished = true
        // 常规冷启动：主界面在 splash 下已是清晰最终布局，淡出 overlay 即可。
        // 首次引导会在 `presentFirstRunOnboardingIfNeeded` 里主动 obscureMainContent。
        await presentFirstRunOnboardingIfNeeded()
    }

    /// 只给启动页等待登录恢复一个短预算。
    ///
    /// `AuthSession.restoreSessionIfAvailable()` 会访问 GitHub `/user` 校验 token，
    /// 网络层超时较长；如果这里直接 await，离线或 GitHub 慢响应时用户会长时间停在
    /// splash。启动页的职责是避免首屏闪烁，不应该承担完整网络恢复的等待成本。
    private func restoreSessionWithinSplashBudget() async -> Bool {
        let gate = LaunchSplashRestoreGate()
        let restoreTask = Task { @MainActor in
            await authSession.restoreSessionIfAvailable()
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task {
                    _ = await restoreTask.value
                    await gate.resumeOnce(continuation, result: true)
                }

                Task {
                    try? await Task.sleep(for: LaunchSplashTiming.authRestoreWaitCap)
                    restoreTask.cancel()
                    await gate.resumeOnce(continuation, result: false)
                }
            }
        } onCancel: {
            restoreTask.cancel()
        }
    }

    /// splash 淡出动画结束后再展示首次安装分步引导 overlay。
    private func presentFirstRunOnboardingIfNeeded() async {
        guard FirstRunOnboardingPreferences.shouldShow else { return }

        let postSplashDelay: Duration = reduceMotion ? .zero : .milliseconds(520)
        try? await Task.sleep(for: postSplashDelay)

        obscureMainContent()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.42)) {
            showFirstRunOnboarding = true
        }
    }

    /// 把引导层的选择映射回 App 既有入口。
    ///
    /// 约束：
    /// - 登录必须复用 `AuthSession.signIn()`，让 Device Flow sheet、错误处理和取消逻辑保持单一来源。
    /// - Trending 路由交给 `HomeView` 响应通知，避免启动容器反向持有三栏页面状态。
    /// - `.skip` 不做路由；如果用户已登录，保留启动恢复后的 Manage，未登录则自然停在 Trending。
    private func handleFirstRunCompletion(_ completion: FirstRunOnboardingCompletion) {
        switch completion {
        case .browseTrending:
            NotificationCenter.default.post(
                name: FirstRunOnboardingPreferences.browseTrendingNotification,
                object: nil
            )
        case .signIn:
            guard !authSession.state.isAuthenticated else { return }
            authSession.signIn()
        case .skip:
            break
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
    @Environment(\.colorScheme) private var colorScheme

    /// 分阶段揭示：hidden → icon → text → complete
    @State private var revealPhase = RevealPhase.hidden
    @State private var glowDrift = false

    /// 与 About 页品牌区同源的金色，保持 Starcat 视觉一致性。
    private let starGold = Color(red: 1.0, green: 0.74, blue: 0.28)
    /// light 下 starGold 过浅，柔光 / 点阵改用深琥珀（与引导页一致）。
    private let lightBrandTint = Color.fromHex6(0xB45309)

    /// dark 用 plusLighter 已足够；light 走 multiply，略提高 opacity 保证纹理可见。
    private var splashDotsOverlayOpacity: Double {
        colorScheme == .dark ? 0.42 : 0.54
    }

    /// 柔光 tint：dark 金色，light 深琥珀。
    private var splashGlowTint: Color {
        colorScheme == .dark ? starGold : lightBrandTint
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            splashDotsFlowBackground
                .opacity(splashDotsOverlayOpacity)
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

    /// 星流点阵：与首次引导页同一套 light/dark 方案（见 FirstRunOnboardingView）。
    @ViewBuilder
    private var splashDotsFlowBackground: some View {
        if colorScheme == .dark {
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
        } else {
            DotsFlowBackground(
                tint: lightBrandTint,
                background: .white,
                speed: 0.28,
                brightness: 0.82,
                dotSize: 0.95,
                gridDensity: 1.05,
                patternScale: 0.92,
                vignette: 0.35
            )
            .blendMode(.multiply)
        }
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 96, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 22, x: 0, y: 12)
            .shadow(
                color: splashGlowTint.opacity(colorScheme == .dark ? 0.35 : 0.22),
                radius: 28,
                x: 0,
                y: 4
            )
    }

    /// Icon 背后的双层金色柔光，reduceMotion 时静态居中。
    private var brandGlowLayer: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                glowOrb(
                    color: splashGlowTint.opacity(colorScheme == .dark ? 0.16 : 0.12),
                    diameter: min(size.width, size.height) * 0.72,
                    offset: glowDrift ? CGPoint(x: 12, y: -8) : CGPoint(x: -10, y: 10)
                )
                glowOrb(
                    color: splashGlowTint.opacity(colorScheme == .dark ? 0.09 : 0.07),
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

#Preview("Launch Splash — Dark") {
    LaunchSplashView()
        .frame(width: 960, height: 640)
        .preferredColorScheme(.dark)
        .starcatAnimationOverride()
        .environment(AppSettings())
}

#Preview("Launch Splash — Light") {
    LaunchSplashView()
        .frame(width: 960, height: 640)
        .preferredColorScheme(.light)
        .starcatAnimationOverride()
        .environment(AppSettings())
}
