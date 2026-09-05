//
//  StarcatApp.swift
//  Starcat
//
//  @main 入口。
//
//  启动期职责：
//  1. 触发 DatabaseManager 单例初始化（含 Migration）
//  2. 跑 KeychainManager 自检
//  3. 构造 AppDependencies（API / OAuth / AuthSession / SyncManager）
//  4. 尝试从 Keychain 恢复登录态
//  5. 应用用户主题偏好（NSApp.appearance）
//

import SwiftUI
import AppKit  // W4-5 D1 follow-up：NSApp.appearance 控制主题（preferredColorScheme 在 macOS 有 nil-restore bug）

extension Notification.Name {
    /// 三处系统入口共用的列表偏好重置意图；实际重置由 HomeView 在当前账号上下文执行。
    static let starcatResetListPreferencesRequested = Notification.Name("starcat.resetListPreferencesRequested")
}

@main
struct StarcatApp: App {

    /// macOS app 生命周期桥接。
    ///
    /// `AppDelegate` 同时负责两类 AppKit 生命周期事件：
    /// - Dock reopen / 前台激活兜底，避免用户关闭主窗口后再次点击 Dock 没反应。
    /// - 早期注册 `kAEGetURL` handler，避免浏览器 OAuth callback 拉起第二个进程。
    /// 保持单个 adaptor，避免两个 NSApplicationDelegate 互相覆盖生命周期回调。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 应用级依赖容器，必须在 init 中创建并通过 environment 传给 ContentView。
    ///
    /// 这里允许为 nil，是为了把数据库初始化失败这类启动期硬错误从 `fatalError`
    /// 改成受控失败页。依赖为空时不进入主界面，避免半初始化状态继续读写本地数据。
    @State private var dependencies: AppDependencies?

    /// 启动期核心依赖失败时给用户展示的友好错误。
    @State private var startupError: UserFacingError?

    /// 主窗口与 Settings Scene 共用的快捷键路由。
    /// Settings 成为 key window 后仍需操作主窗口最后一个有效仓库，不能依赖 scene-local FocusedValue。
    @State private var commandRouter = StarcatCommandRouter.shared

    // MARK: - 用户语言切换（生产可用）
    //
    // dong4j 2026-06-15 需求：用户希望在「设置 → 通用」里能直接切 App 显示语言，
    // 不依赖系统语言、不依赖 Xcode Scheme，也不需要重启 App。
    // `LocaleStore` 是 `@MainActor @Observable` 单例，主窗口与 Settings 两个
    // scene 都通过 `.environment(\.locale, _)` 注入；切换时 `.id(...)` 强制
    // 整棵 view 树重建，避免某些缓存了 Locale 的 formatter（如
    // `RelativeDateTimeFormatter` 实例缓存）不刷新。
    //
    // 2026-06-16 dong4j 删除了 DEBUG-only `DebugLocaleStore`：语言切换正式入口
    // 已在「设置 → 通用 → 语言」落地，调试期切语言走同一份 `LocaleStore`。
    // Debug 菜单本身保留作为后续调试入口的容器（清缓存 / Dump DB 等），但
    // 当前不再承载语言切换。
    @State private var localeStore = LocaleStore.shared

    init() {
        Self.bootstrap()

        // 注意：AppDependencies 是 @MainActor，App init 已在 main thread。
        do {
            let resolvedDependencies = try AppDependencies()
            _dependencies = State(initialValue: resolvedDependencies)
            _startupError = State(initialValue: nil)
            CompanionServiceBootstrapper.startFromStoredConfiguration(dependencies: resolvedDependencies)
        } catch {
            let friendly = UserFacingError.map(error, operation: String.l10n("diagnostics.operation.startup"), service: "Starcat")
            friendly.record(level: .critical, category: "startup", operation: "appDependencies")
            _dependencies = State(initialValue: nil)
            _startupError = State(initialValue: friendly)
        }

        // ⚠️ 不要在这里调 `Self.applyAppearance(...)` / `NSApp.appearance = ...`！
        // `NSApp` 是 implicitly unwrapped optional，`@main App.init()` 阶段
        // `NSApplication.shared` 还没被初始化 (NSApp == nil)，访问 `NSApp.appearance`
        // 会立即崩 "Unexpectedly found nil while implicitly unwrapping an Optional"。
        // 2026-06-03 23:43 dong4j 截图验证。
        //
        // 主题应用走 ContentView 的 `.onAppear` + `.onChange` 路径 —— 那时候
        // NSApp 已经初始化完成，访问 .appearance 安全。代价：冷启动 → 第一帧
        // 之间几十 ms 窗口可能闪一下系统默认外观，再切到用户选择 —— 这是
        // 可接受的权衡，不要为了消除这点闪烁再回到 init() 里调 NSApp。
    }

    /// 处理从 macOS URL handler 进来的 Starcat URL。
    ///
    /// OAuth、Direct License 支付回跳和仓库 Deep Link 共用本入口。Release 链接
    /// 必须先于普通仓库链接和 OAuth 解析：它比仓库链接多一段 `/releases`，并需要
    /// 保留 release ID 才能在时间线中定位。Dispatcher 会保存未消费请求，所以
    /// 冷启动完成登录后仍可继续定位。
    private func handleIncomingURL(_ url: URL) {
        guard let dependencies else {
            // OAuth callback 可能携带一次性 code，启动失败日志只记路由，不能输出完整 URL。
            AppLog.auth.warning(
                "StarcatApp.handleIncomingURL: dependencies not ready, ignoring scheme=\(url.scheme ?? "", privacy: .public) host=\(url.host ?? "", privacy: .public)"
            )
            return
        }
        if let widgetRoute = WidgetAppDeepLink(url: url) {
            switch widgetRoute.destination {
            case .main:
                AppDelegate.activateMainWindowIfPossible()
            case .releaseTimeline:
                dependencies.mainWindowNavigationDispatcher.navigate(to: .releaseTimeline)
            case .insights:
                dependencies.mainWindowNavigationDispatcher.navigate(to: .insights)
            }
            return
        }
        if let release = RepositoryReleaseDeepLink(url: url) {
            dependencies.mainWindowNavigationDispatcher.navigate(to: .repositoryRelease(release))
            return
        }
        if let repository = RepositoryDeepLink(url: url) {
            dependencies.mainWindowNavigationDispatcher.navigate(to: .repository(repository))
            return
        }
        if url.host == "license", url.path == "/activate" {
            guard DistributionChannel.current.isDirect else {
                AppLog.auth.warning("StarcatApp.handleIncomingURL: ignoring Direct license callback in App Store build")
                return
            }
            Task { await dependencies.directLicenseManager.activateFromPaymentSuccessURL(url) }
            return
        }
        if AppConstants.isGitHubAppCallback(url) {
            // 正常 callback 由发起授权的 ASWebAuthenticationSession 直接截获。
            // 外部 URL handler 收到它，说明当前进程没有对应会话；拒绝处理一次性 code，
            // 避免 App Store 与 Direct 同时安装时由错误版本消费授权结果。
            AppLog.auth.warning(
                "Ignoring GitHub App callback outside the initiating authentication session"
            )
            return
        }
        Task { await dependencies.authSession.handleWebFlowCallback(url: url) }
    }

    var body: some Scene {
        Window("Starcat", id: "main") {
            windowRoot
                .registerMainWindowOpenFallback()
                // 2026-06-29：监听 AppDelegate 转发过来的 starcat://callback URL。
                // NSAppleEventManager handler 会消费 kAEGetURL 事件 → .onOpenURL 收不到 →
                // 必须在 AppDelegate handler 里通过 NotificationCenter 显式转发。
                .onReceive(NotificationCenter.default.publisher(for: AppDelegate.incomingURLNotification)) { notification in
                    if let url = notification.object as? URL {
                        handleIncomingURL(url)
                    }
                }
                // 兜底：如果未来 NSAppleEventManager handler 被移除或有其他 URL 来源，
                // .onOpenURL 仍作为 secondary handler 继续工作。
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        // macOS 15 的 AppKit state restoration 可能存在持久化记录，却没有真正恢复
        // 任何窗口。显式使用 `.presented`，保证这种情况下仍创建主窗口，避免只剩
        // Dock 运行点而没有可见界面。
        .defaultLaunchBehavior(.presented)
        .commands {
            // 替换系统默认的"关于 Starcat"菜单项，打开自定义 SwiftUI 关于窗口。
            CommandGroup(replacing: .appInfo) {
                Button("app.about") {
                    AboutPanelController.show()
                }
            }

            SettingsWindowCommands()

            StarcatAppCommands(
                dependencies: dependencies,
                commandRouter: commandRouter,
                settings: dependencies?.settings ?? AppSettings.shared
            )

            // DEBUG-only 菜单承载首次引导重放、Pro 覆盖、Agent 工作台和窗口尺寸工具。
            // Release 包整段不存在；菜单标题 / 选项标签都用 verbatim 文本，
            // 不进入 String Catalog——避免"切到英文后调试菜单也变英文"的循环噩梦。
            #if DEBUG
            DebugMenuCommands(dependencies: dependencies)
            #endif
        }

        // 两个 AI 工作台必须和主窗口一样由 SwiftUI Window Scene 承载：只有这样
        // NavigationSplitView 的原生 Sidebar 才能贯穿 toolbar 并包住交通灯。
        Window("rag.workspace.window.title", id: KnowledgeRAGWorkspaceWindowController.sceneID) {
            KnowledgeRAGWorkspaceSceneHost(coordinator: AIWorkspaceSceneCoordinator.shared)
        }
        .defaultSize(
            width: KnowledgeRAGWorkspaceWindowMetrics.defaultContentSize.width,
            height: KnowledgeRAGWorkspaceWindowMetrics.defaultContentSize.height
        )
        .defaultLaunchBehavior(.suppressed)

        Window("agent.workspace.window.title", id: AgentWorkspaceWindowController.sceneID) {
            if let dependencies {
                AgentWorkspaceSceneRoot(dependencies: dependencies)
            } else {
                StartupFailureView(error: startupError ?? UserFacingError.map(
                    DatabaseError.applicationSupportNotFound,
                    operation: String.l10n("diagnostics.operation.startup"),
                    service: "Starcat"
                ))
            }
        }
        .defaultSize(
            width: AgentWorkspaceWindowMetrics.defaultContentSize.width,
            height: AgentWorkspaceWindowMetrics.defaultContentSize.height
        )
        .defaultLaunchBehavior(.suppressed)

        // 使用普通单例 Window，而不是 SwiftUI `Settings` preference window：保留标准
        // 交通灯、原生 Sidebar/Toolbar，同时按产品约束固定为当前验收尺寸。
        Window("Starcat", id: "settings") {
            settingsSceneRoot
        }
        .defaultSize(width: 720, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)
        .commands {
            SettingsWindowCommands()
        }
    }

    // MARK: - 内容根视图

    @ViewBuilder
    private var windowRoot: some View {
        if let dependencies {
            contentRoot(dependencies: dependencies)
                // 2026-06-15:必须挂在所有 `.environment(...)` 之前(modifier 链
                // 越靠前 = 子树端,SwiftUI 把 environment 注入按"链中靠后 = 父层"
                // 解析)。AnimationOverrideModifier 内部 `@Environment(AppSettings)`
                // 需要 settings 在它的 ancestor 链上,所以 settings env 必须挂在
                // 这一行之后。详见 Shared/Components/AnimationOverrideModifier.swift。
                .starcatAnimationOverride()
                .environment(dependencies)
                .environment(dependencies.authSession)
                .environment(dependencies.syncManager)
                .environment(dependencies.settings)
                .environment(dependencies.telemetryManager)
                .environment(dependencies.subscriptionManager)
                .environment(dependencies.directLicenseManager)
                .environment(dependencies.entitlementGate)
                .starcatCommandRouterEnvironment(commandRouter)
                // HOM-PROFILE 2026-06-05：贡献草坪服务，Sidebar 直接消费 @Observable 实例。
                .environment(dependencies.contributionService)
                // 2026-06-06 A 方案：用户 profile 缓存服务。Sidebar / ShareCardSheet 会调
                // userProfileService.load(force:) 主动触发 TTL 刷新或 force refresh。
                .environment(dependencies.userProfileService)
                // 分享卡开发语言统计服务：登录后预热，分享卡读取用户自有公开仓库语言占比。
                .environment(dependencies.developerLanguageService)
                // HOM-126：自动后台 AI 整理调度器。Sidebar 直接观察 `isAutoTidyRunning`
                // 决定是否展示「AI 自动整理中 N/M」轻量行；设置页观察其触发结果展示
                // 「运行状态」。调度器的 `start()` 由 HomeView 在 .task 里调。
                .environment(dependencies.autoTidyScheduler)
                #if DEBUG
                .onReceive(NotificationCenter.default.publisher(for: DebugFlags.debugProOverrideDidChangeNotification)) { _ in
                    dependencies.subscriptionManager.applyDebugProOverride(active: DebugFlags.debugProOverride)
                }
                #endif
                .onAppear {
                    #if DEBUG
                    dependencies.subscriptionManager.applyDebugProOverride(active: DebugFlags.debugProOverride)
                    #endif
                    StatusBarController.shared.configure(dependencies: dependencies)
                    AppDelegate.configure(dependencies: dependencies)
                    AppDelegate.applyActivationPolicy(hideDockIcon: dependencies.settings.hideDockIcon)
                    applyAppearance(dependencies.settings.appearanceMode)
                    MetricKitReporter.shared.start()
                    // Undo Star 历史记录后台清理调度器
                    dependencies.undoStarCleanupScheduler.start()
                    dependencies.telemetryManager.track(.appLaunched)
                }
                .onChange(of: dependencies.settings.appearanceMode) { _, newMode in
                    applyAppearance(newMode)
                }
                .onChange(of: dependencies.settings.hideDockIcon) { _, hideDockIcon in
                    AppDelegate.applyActivationPolicy(hideDockIcon: hideDockIcon)
                }
                .animation(dependencies.settings.disableAnimations ? nil : .easeInOut(duration: 0.3), value: dependencies.settings.appearanceMode)
        } else {
            StartupFailureView(error: startupError ?? UserFacingError.map(DatabaseError.applicationSupportNotFound, operation: String.l10n("diagnostics.operation.startup"), service: "Starcat"))
        }
    }

    @ViewBuilder
    private var settingsSceneRoot: some View {
        if let dependencies {
            settingsRoot
                // 2026-06-15:Settings 是独立 SwiftUI scene root,主窗口的
                // 同款 modifier 不会传播到这里,必须再挂一次让 Settings 子树
                // 的所有动画（如 List row 切换、Tab 切换）也尊重用户偏好。
                // 必须挂在 environment 之前(链中靠前 = 子树端),让 modifier 内部
                // `@Environment(AppSettings.self)` 能向上找到 settings。
                .starcatAnimationOverride()
                .environment(dependencies)        // W4-4 D4：StorageSettingsTab 需要 readmeRepository
                .environment(dependencies.authSession)
                .environment(dependencies.settings)
                .environment(dependencies.telemetryManager)
                .environment(dependencies.subscriptionManager)
                .environment(dependencies.directLicenseManager)
                .environment(dependencies.entitlementGate)
                .starcatCommandRouterEnvironment(commandRouter)
                // HOM-126：AI 设置「自动整理」分组的「立刻手动触发一次」按钮直接
                // 调 scheduler.triggerManually()。不依赖 AppDependencies 间接路径，
                // 让 Settings tab 与 scheduler 解耦但显式可见。
                .environment(dependencies.autoTidyScheduler)
                .animation(dependencies.settings.disableAnimations ? nil : .easeInOut(duration: 0.3), value: dependencies.settings.appearanceMode)
        } else {
            StartupFailureView(error: startupError ?? UserFacingError.map(DatabaseError.applicationSupportNotFound, operation: String.l10n("diagnostics.operation.startup"), service: "Starcat"))
        }
    }

    /// 包了一层 builder 是为了把 locale 注入和 identity 重建集中在一处，未来要
    /// 加调试期临时覆盖（如 DEBUG 入参）也只需在这里改。
    ///
    /// **关键约束**：
    /// - SwiftUI 中 `.environment(_, _)` 链上**靠子树端（链中后调用）的值**生效，
    ///   所以这里只注入生产 `localeStore`。
    /// - `.id(localeStore.selection.rawValue)` 强制重建 ContentView，避免缓存
    ///   Locale 的子视图（如 `RelativeDateTimeFormatter` 实例缓存）不刷新——
    ///   dong4j 历史截图反馈"切语言后部分时间格式没变"就是少了 identity 重建。
    @ViewBuilder
    private func contentRoot(dependencies: AppDependencies) -> some View {
        let updateController = dependencies.appStoreUpdateController
        let updatePresentation = updateController.presentation

        // LaunchSplashContainer 必须在 `.id(localeStore...)` 外层，否则切语言会重播 splash。
        // Auth restore 时序已迁入 Container 的 `.task`，与最短展示时长并行等待。
        LaunchSplashContainer {
            ContentView()
                .environment(\.locale, localeStore.selection.effectiveLocale)
                .environment(\.layoutDirection, localeStore.selection.effectiveLayoutDirection)
                .environment(\.starcatInterfaceScale, dependencies.settings.interfaceScale)
                .id(localeStore.selection.rawValue)
        }
        .starcatMCPPairingApprovalPresenter(store: dependencies.mcpDeviceStore)
        .task {
            await updateController.checkAutomaticallyIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await updateController.checkAutomaticallyIfNeeded()
            }
        }
        .alert(
            updatePresentation?.title ?? "",
            isPresented: Binding(
                get: { updatePresentation != nil },
                set: { isPresented in
                    if !isPresented {
                        updateController.dismissPresentation()
                    }
                }
            )
        ) {
            if let storeURL = updatePresentation?.storeURL {
                Button(String.l10n("app.update.openAppStore")) {
                    NSWorkspace.shared.open(storeURL)
                    updateController.dismissPresentation()
                }
                Button(String.l10n("app.update.later"), role: .cancel) {
                    updateController.dismissPresentation()
                }
            } else {
                Button(String.l10n("common.ok")) {
                    updateController.dismissPresentation()
                }
            }
        } message: {
            Text(updatePresentation?.message ?? "")
        }
    }

    /// Settings scene 的语言注入与重建逻辑，与 `contentRoot` 完全对称。
    ///
    /// 为什么 Settings 也必须注入：Settings 是独立 SwiftUI scene，主窗口的
    /// `.environment(\.locale, _)` 不会传播过来——如果不注入，用户从设置页
    /// 切完语言后，Settings 自身仍然显示切换前的 locale，体感是"切了个寂寞"。
    /// `LocaleStore` 是 `@Observable` 单例，主窗口与 Settings 共享同一个
    /// `selection`，任意一方写入都会让两个 scene 同步重渲染。
    @ViewBuilder
    private var settingsRoot: some View {
        SettingsView()
            .environment(\.locale, localeStore.selection.effectiveLocale)
            .environment(\.layoutDirection, localeStore.selection.effectiveLayoutDirection)
            .environment(\.starcatInterfaceScale, dependencies?.settings.interfaceScale ?? .standard)
            .id(localeStore.selection.rawValue)
    }

    // MARK: - 主题应用

    /// 把 `AppearanceMode` 写到 `NSApp.appearance`。
    ///
    /// 设计：
    /// - `.system` → `nil`：AppKit 标准的"清除强制外观"，所有 NSWindow 回退跟随系统
    /// - `.light` → `NSAppearance(named: .aqua)`：强制浅色
    /// - `.dark` → `NSAppearance(named: .darkAqua)`：强制深色
    ///
    /// 为什么放在 @MainActor func 而不是 AppearanceMode 的 computed property：
    /// - `AppearanceMode` 在 `AppSettings.swift` 中只 import SwiftUI，
    ///   保持平台无关；NSAppearance 是 AppKit 类型，放在使用点（StarcatApp）
    ///   更符合分层
    /// - 集中在一个 helper，未来如果切到不同主题机制（如自定义 NSAppearance bundle）
    ///   只改这一处
    @MainActor
    private func applyAppearance(_ mode: AppearanceMode) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Bootstrap

    private static func bootstrap() {
        PerformanceTracer.shared.trace(.appBootstrap) {
            bootstrapBody()
        }
    }

    private static func bootstrapBody() {
        // 2026-06-16 root cause #2 修复:把 `Bundle.main` 的 ISA 换成
        // `LocalizedBundle`,让所有 `String(localized:)` / `NSLocalizedString(...)`
        // 调用都跟随 `LocaleStore.shared.selection` 实时切换,而非锁定系统 locale。
        // 必须放在 `AppLog.general.info` 之前——log 也走本地化路径(虽然 OSLog
        // 内部不走 String(localized:),但保险起见早装早安心)。详见
        // `Starcat/Core/Settings/LocalizedBundle.swift` 顶部注释。
        LocalizedBundle.install()

        // 外部 Runtime 已从 Debug POC 转为 Direct 正式能力。必须在任何 @AppStorage
        // 初始化前迁移旧键，避免升级后看似自动回退内置 Loop、实际丢失用户选择。
        ExternalAgentRuntimePreferences.migrateLegacyDefaults()

        AppLog.general.info("Starcat starting (bundle=\(AppConstants.bundleIdentifier, privacy: .public))")

        // 2026-06-12 多账号 DB 隔离：DatabaseManager 不再是单例，由 AppDependencies init
        // 内部 `try DatabaseManager(userId: nil)` 打开 `users/_anonymous` 占位 DB。
        // 这里不再单独 bootstrap DB。AuthSession 在 restoreSession / signIn 成功后通过
        // onUserSessionChanged closure 触发 `database.reopen(userId:)` 切到 user 目录。

        // 测试期跳过 Keychain 自检：ad-hoc 签名 + ACL 不匹配会触发 GUI 授权弹窗，
        // 测试 host 主线程被对话框阻塞 → testmanagerd 永远连不上 App。
        // 详见 docs/4-工程进度/踩坑与故障记录/2026-05-30-Keychain-临时绕过方案.md
        if TestEnvironment.isRunning {
            AppLog.general.info("Test host detected, skipping Keychain self-check")
        } else {
            do {
                try KeychainManager.shared.ping()
            } catch {
                AppLog.keychain.error("Keychain self-check failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        AppLog.general.info("Starcat bootstrap complete")
    }
}

/// 把 SwiftUI `openWindow(id:)` 暴露给 AppKit 生命周期入口。
///
/// 菜单栏 `NSStatusItem`、Dock reopen 都在 AppDelegate / AppKit 一侧触发；当主窗口
/// 已被用户关闭时，AppKit 的 `NSApp.windows` 没有可恢复对象，必须回到 SwiftUI
/// WindowGroup 重新创建窗口。这里保持桥接很薄，只注册固定 id 的主窗口打开动作。
private struct MainWindowOpenFallbackRegistrar: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content
            .onAppear {
                AppDelegate.openMainWindowFallback = {
                    openWindow(id: "main")
                }
                AppDelegate.openSettingsWindowFallback = {
                    openWindow(id: "settings")
                }
                AIWorkspaceSceneCoordinator.shared.registerWindowActions(
                    openAgent: {
                        openWindow(id: AgentWorkspaceWindowController.sceneID)
                    },
                    openKnowledgeRAG: {
                        openWindow(id: KnowledgeRAGWorkspaceWindowController.sceneID)
                    },
                    dismissKnowledgeRAG: {
                        dismissWindow(id: KnowledgeRAGWorkspaceWindowController.sceneID)
                    }
                )
                AppLog.general.info("Main window scene appeared; reopen fallback registered")
            }
    }
}

private extension View {
    func registerMainWindowOpenFallback() -> some View {
        modifier(MainWindowOpenFallbackRegistrar())
    }
}

// MARK: - App 菜单命令

/// 用普通 `Window` 承接设置页后，显式恢复 macOS 标准的「设置…」菜单与 Cmd+,。
/// 重复触发 `openWindow(id:)` 只会激活同一个设置窗口，不会创建多个实例。
private struct SettingsWindowCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("menubar.openSettings") {
                AppDelegate.openSettingsWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// Starcat 顶部菜单命令。
///
/// 这些入口全部复用已有业务路径：同步走 `SyncManager`，主窗口动作通过 focused
/// context 路由，外链 / 诊断导出仍走原 AppKit / 工具类。
/// 这样菜单只是 macOS 可发现性增强，不新增第二套业务状态。
private struct StarcatAppCommands: Commands {
    let dependencies: AppDependencies?
    let commandRouter: StarcatCommandRouter
    let settings: AppSettings
    @FocusedValue(\.starcatRefreshAction) private var focusedRefreshAction
    @FocusedValue(\.starcatRepositoryAIAction) private var focusedRepositoryAIAction
    @FocusedValue(\.starcatReadmeFindAction) private var focusedReadmeFindAction
    @FocusedValue(\.starcatListSearchAction) private var focusedListSearchAction

    var body: some Commands {
        CommandMenu("commands.actions.menu") {
            Button("commands.actions.openGlobalSearch") {
                commandRouter.openGlobalSearch()
            }
            .keyboardShortcut(
                settings.keyboardShortcutsEnabled && settings.globalSearchShortcutEnabled
                    ? settings.globalSearchShortcut.swiftUIShortcut
                    : nil
            )
            .disabled(!commandRouter.canOpenGlobalSearch)

            Button("commands.actions.findInList") {
                commandRouter.performListSearch(preferred: focusedListSearchAction)
            }
            .keyboardShortcut(
                settings.keyboardShortcutsEnabled && settings.regularSearchShortcutEnabled
                    ? settings.regularSearchShortcut.swiftUIShortcut
                    : nil
            )
            .disabled(!commandRouter.isListSearchAvailable(preferred: focusedListSearchAction))

            Button("commands.actions.findInReadme") {
                commandRouter.performReadmeFind(preferred: focusedReadmeFindAction)
            }
            .disabled(!commandRouter.isReadmeFindAvailable(preferred: focusedReadmeFindAction))

            Button("commands.actions.openKnowledgeRAGWorkspace") {
                commandRouter.openKnowledgeRAGWorkspace()
            }
            .keyboardShortcut(
                settings.keyboardShortcutsEnabled && settings.knowledgeRAGShortcutEnabled
                    ? settings.knowledgeRAGShortcut.swiftUIShortcut
                    : nil
            )
            .disabled(!commandRouter.canOpenKnowledgeRAGWorkspace)

            if dependencies?.distributionGate.isAvailable(.externalAgentRuntime) == true {
                Button("toolbar.agentWorkspace.help") {
                    if let dependencies {
                        AgentWorkspaceWindowController.show(dependencies: dependencies)
                    }
                }
                .disabled(dependencies == nil)
            }

            Button("commands.actions.openSelectedRepoAI") {
                commandRouter.openCurrentRepositoryAI(preferred: focusedRepositoryAIAction)
            }
            .keyboardShortcut(
                settings.keyboardShortcutsEnabled && settings.selectedRepoAIShortcutEnabled
                    ? settings.selectedRepoAIShortcut.swiftUIShortcut
                    : nil
            )
            .disabled(!commandRouter.isRepositoryAIAvailable(preferred: focusedRepositoryAIAction))

            Divider()

            Button("commands.actions.refreshCurrentContent") {
                commandRouter.refreshCurrentContent(preferred: focusedRefreshAction)
            }
            .keyboardShortcut(
                settings.keyboardShortcutsEnabled && settings.refreshCurrentContentShortcutEnabled
                    ? settings.refreshCurrentContentShortcut.swiftUIShortcut
                    : nil
            )
            .disabled(!commandRouter.isRefreshAvailable(preferred: focusedRefreshAction))

            Button("ai.usage.open") {
                if let dependencies {
                    AIUsageWindowController.show(dependencies: dependencies)
                }
            }
            .disabled(dependencies == nil)

            Divider()

            if dependencies?.directUpdateController.isDirectBuild == true {
                Button("commands.actions.checkForUpdates") {
                    dependencies?.directUpdateController.checkForUpdates()
                }
                .disabled(dependencies?.directUpdateController.canCheckForUpdates != true)
            } else if let updateController = dependencies?.appStoreUpdateController,
                      updateController.isAppStoreBuild {
                Button("commands.actions.checkForUpdates") {
                    Task {
                        await updateController.checkManually()
                    }
                }
                .disabled(!updateController.canCheckForUpdates)
            }

            Button("diagnostics.export.button") {
                exportDiagnostics()
            }
        }

        // 替换系统 Edit > Find，避免 ⌘F 被默认文本查找吃掉，而 README WebView 收不到。
        CommandGroup(replacing: .textEditing) {
            Button("commands.actions.findInReadme") {
                commandRouter.performReadmeFind(preferred: focusedReadmeFindAction)
            }
            .keyboardShortcut(
                settings.keyboardShortcutsEnabled && settings.readmeFindShortcutEnabled
                    ? settings.readmeFindShortcut.swiftUIShortcut
                    : nil
            )
            .disabled(!commandRouter.isReadmeFindAvailable(preferred: focusedReadmeFindAction))
        }

        CommandGroup(replacing: .help) {
            Button("commands.help.helpCenter") {
                openExternal(AppWebsiteLinks.current.support)
            }

            Button("commands.help.contactSupport") {
                openExternal("mailto:dong4j@gmail.com")
            }

            Button("commands.help.privacyPolicy") {
                openExternal(AppWebsiteLinks.current.privacy)
            }

            Button("commands.help.viewOnGitHub") {
                openExternal(AppWebsiteLinks.sourceRepository)
            }

            Divider()

            Button("commands.help.releaseNotes") {
                ReleaseNotesWindowController.show()
            }
        }
    }

    @MainActor
    private func exportDiagnostics() {
        Task {
            _ = await DiagnosticBundleExporter.exportFromPanel(settings: dependencies?.settings ?? AppSettings.shared)
        }
    }

    @MainActor
    private func openExternal(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        openExternal(url)
    }

    @MainActor
    private func openExternal(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - DEBUG-only 菜单

#if DEBUG
/// DEBUG 菜单聚合（顶部菜单栏出现一个开发专用入口）。
///
/// 设计：
/// - 用 `Commands` 协议而不是直接写在 `.commands` 里——把所有调试入口聚拢到一个
///   独立类型，未来要加新调试项（清数据库 / Dump 偏好 / 强制限流等）就在这个
///   类型里加 `CommandGroup` / `CommandMenu`，主 `StarcatApp.body` 不会被撑大
/// - `CommandMenu("Who's Your Daddy")` 在 menubar 上插入一个顶级菜单（位置由 SwiftUI 决定，
///   一般在 View 菜单之后），不与系统标准菜单冲突
///
/// 2026-06-16 dong4j 删除了「语言切换」子菜单（语言切换正式入口已在「设置 →
/// 通用 → 语言」落地）。该菜单本身保留作为后续调试入口的容器；菜单标题故意
/// 使用非产品化文案，避免 DEBUG-only 能力看起来像正式用户功能。
/// DEBUG 菜单使用的当前窗口外框调整器。
///
/// 只写 `NSWindow.frame`，不触碰 `NavigationSplitView` 的 Sidebar、中栏宽度或
/// 分隔位置；窗口原有最小尺寸仍然生效，避免截图工具把三栏布局压坏。
@MainActor
private enum DebugWindowResizer {
    /// Retina @2x 下输出 Apple 接受的 2880×1800 截图。
    static let appleScreenshotWindowSize = NSSize(width: 1440, height: 900)

    /// Screen Studio 使用 16:9 工作窗口，并在导出阶段输出 1920×1080 视频。
    static let appleVideoWindowSize = NSSize(width: 1920, height: 1080)

    static func resizeFrontmostWindow(to size: NSSize) {
        guard let window = frontmostResizableWindow(),
              canApply(size, to: window)
        else {
            return
        }

        let currentFrame = window.frame
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        var targetOrigin = NSPoint(
            x: currentFrame.minX,
            y: currentFrame.maxY - size.height
        )

        if let visibleFrame {
            // 保持左上角位置；扩大后越界时只把窗口移回当前显示器可用区域。
            targetOrigin.x = min(
                max(targetOrigin.x, visibleFrame.minX),
                visibleFrame.maxX - size.width
            )
            targetOrigin.y = min(
                max(targetOrigin.y, visibleFrame.minY),
                visibleFrame.maxY - size.height
            )
        }

        window.setFrame(
            NSRect(origin: targetOrigin, size: size),
            display: true,
            animate: false
        )
        window.makeKeyAndOrderFront(nil)
    }

    /// 顶部菜单展开时 key window 仍是用户正在操作的窗口，因此优先使用它；
    /// mainWindow 与 orderedWindows 只负责窗口焦点异常时兜底。
    private static func frontmostResizableWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow, isEligible(keyWindow) {
            return keyWindow
        }
        if let mainWindow = NSApp.mainWindow, isEligible(mainWindow) {
            return mainWindow
        }
        return NSApp.orderedWindows.first(where: isEligible)
    }

    private static func isEligible(_ window: NSWindow) -> Bool {
        window.isVisible
            && window.sheetParent == nil
            && window.styleMask.contains(.resizable)
    }

    private static func canApply(_ size: NSSize, to window: NSWindow) -> Bool {
        let contentMinimumFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: window.contentMinSize)
        ).size
        let minimumFrameSize = NSSize(
            width: max(window.minSize.width, contentMinimumFrameSize.width),
            height: max(window.minSize.height, contentMinimumFrameSize.height)
        )
        guard size.width >= minimumFrameSize.width,
              size.height >= minimumFrameSize.height
        else {
            return false
        }

        guard let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return true
        }
        return size.width <= visibleFrame.width && size.height <= visibleFrame.height
    }
}

struct DebugMenuCommands: Commands {
    let dependencies: AppDependencies?

    @AppStorage(DebugFlags.debugProOverrideKey) private var debugProOverride = false

    var body: some Commands {
        CommandMenu("Who's Your Daddy") {
            Button("Replay First-Run Onboarding") {
                FirstRunOnboardingPreferences.requestManualReplay()
            }
            .disabled(!FirstRunOnboardingPreferences.canReplayManually)

            Toggle(
                "Activate Pro",
                isOn: Binding(
                    get: { debugProOverride },
                    set: { newValue in
                        debugProOverride = newValue
                        DebugFlags.setDebugProOverride(newValue)
                    }
                )
            )

            Divider()

            Button("Open Agent Workspace") {
                guard let dependencies else { return }
                // Debug 入口仍走正式工作台控制器，避免调试菜单形成第二套窗口与门禁语义。
                AgentWorkspaceWindowController.show(dependencies: dependencies)
            }
            .disabled(dependencies == nil)

            Button("Border Beam Search Lab") {
                // 独立实验窗口：验收 BorderBeamKit line 搜索条，不改正式 SmartSearchField。
                BorderBeamSearchLabWindowController.show()
            }

            Button("ambient.menu.openRepos") {
                if let dependencies {
                    AmbientWindowController.show(dependencies: dependencies, scene: .repos)
                }
            }
            .disabled(dependencies == nil)

            Button("ambient.menu.openOwners") {
                if let dependencies {
                    AmbientWindowController.show(dependencies: dependencies, scene: .owners)
                }
            }
            .disabled(dependencies == nil)

            Divider()

            Menu("Window Size") {
                Button("Screenshot · 2880 × 1800 px · Apple 16:10") {
                    DebugWindowResizer.resizeFrontmostWindow(
                        to: DebugWindowResizer.appleScreenshotWindowSize
                    )
                }

                Divider()

                Button("Video · 1920 × 1080 px · Apple 16:9") {
                    DebugWindowResizer.resizeFrontmostWindow(
                        to: DebugWindowResizer.appleVideoWindowSize
                    )
                }
            }
        }
    }
}
#endif
