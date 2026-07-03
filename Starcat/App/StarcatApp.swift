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
import MarkdownUI
import TipKit

extension Notification.Name {
    /// 顶部菜单触发全局搜索。HomeView 持有 SearchCenterViewModel，因此命令层只发意图。
    static let starcatCommandOpenGlobalSearch = Notification.Name("starcat.command.openGlobalSearch")
    /// Debug 菜单触发知识库 RAG 工作台。当前只打开 UI 原型，真实 RAG 后端后续再接。
    static let starcatCommandOpenKnowledgeRAGWorkspace = Notification.Name("starcat.command.openKnowledgeRAGWorkspace")
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

    /// 2026-06-29：处理从 macOS URL handler 进来的 `starcat://callback?code=...&state=...`。
    /// `dependencies` 在 `init()` 失败时为 nil，此时收到 URL 也无法处理（没有 authSession）——
    /// 直接忽略，让用户手动重新登录。
    private func handleIncomingURL(_ url: URL) {
        guard let session = dependencies?.authSession else {
            AppLog.auth.warning("StarcatApp.handleIncomingURL: dependencies not ready, ignoring \(url.absoluteString, privacy: .public)")
            return
        }
        Task { await session.handleWebFlowCallback(url: url) }
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
        .commands {
            // 替换系统默认的"关于 Starcat"菜单项，打开自定义 SwiftUI 关于窗口。
            CommandGroup(replacing: .appInfo) {
                Button("app.about") {
                    AboutPanelController.show()
                }
                .keyboardShortcut("I", modifiers: .command)
            }

            StarcatAppCommands(dependencies: dependencies)

            // DEBUG-only 菜单：作为后续调试入口的容器（清缓存 / 强制制造网络
            // 错误 / Dump 数据库等）。语言切换 2026-06-16 移除（已在设置页落地）。
            // 当前菜单内只放一个 disabled 占位项，等加入第一个真功能时移除占位。
            // Release 包整段不存在；菜单标题 / 选项标签都用 verbatim 文本，
            // 不进入 String Catalog——避免"切到英文后调试菜单也变英文"的循环噩梦。
            #if DEBUG
            DebugMenuCommands()
            #endif
        }

        // macOS 原生 Settings 窗口（Cmd+,）
        Settings {
            settingsSceneRoot
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
                .environment(dependencies.entitlementGate)
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
                    AppDelegate.applyActivationPolicy(hideDockIcon: dependencies.settings.hideDockIcon)
                    applyAppearance(dependencies.settings.appearanceMode)
                    MetricKitReporter.shared.start()
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
                .environment(dependencies.entitlementGate)
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
        // LaunchSplashContainer 必须在 `.id(localeStore...)` 外层，否则切语言会重播 splash。
        // Auth restore 时序已迁入 Container 的 `.task`，与最短展示时长并行等待。
        LaunchSplashContainer {
            ContentView()
                .environment(\.locale, localeStore.selection.effectiveLocale)
                .environment(\.starcatInterfaceScale, dependencies.settings.interfaceScale)
                .id(localeStore.selection.rawValue)
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

        // TipKit 只承载少量局部功能发现提示；真正的新手任务进度由 Starcat 自己的
        // GettingStartedProgressStore 管理，避免用户关闭 tip 后被误判为完成步骤。
        // 测试 host 跳过，保持单测环境没有额外持久化写入和展示频率状态。
        if !TestEnvironment.isRunning {
            try? Tips.configure([
                .displayFrequency(.immediate),
                .datastoreLocation(.applicationDefault)
            ])
        }

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

    func body(content: Content) -> some View {
        content
            .onAppear {
                AppDelegate.openMainWindowFallback = {
                    openWindow(id: "main")
                }
            }
    }
}

private extension View {
    func registerMainWindowOpenFallback() -> some View {
        modifier(MainWindowOpenFallbackRegistrar())
    }
}

// MARK: - App 菜单命令

/// Starcat 顶部菜单命令。
///
/// 这些入口全部复用已有业务路径：同步走 `SyncManager`，搜索由 HomeView 持有的
/// `SearchCenterViewModel` 响应通知，外链 / 诊断导出仍走原 AppKit / 工具类。
/// 这样菜单只是 macOS 可发现性增强，不新增第二套业务状态。
private struct StarcatAppCommands: Commands {
    let dependencies: AppDependencies?

    var body: some Commands {
        CommandMenu("commands.actions.menu") {
            Button("commands.actions.syncStars") {
                syncStars()
            }
            .disabled(dependencies == nil)

            Button("commands.actions.openGlobalSearch") {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .starcatCommandOpenGlobalSearch, object: nil)
            }

            Button("diagnostics.export.button") {
                exportDiagnostics()
            }
        }

        CommandGroup(replacing: .help) {
            Button("commands.help.helpCenter") {
                openExternal("https://starcat.ink/support")
            }

            Button("commands.help.contactSupport") {
                openExternal("mailto:dong4j@gmail.com")
            }

            Button("commands.help.privacyPolicy") {
                openExternal("https://starcat.ink/privacy")
            }

            Divider()

            Button("commands.help.releaseNotes") {
                ReleaseNotesWindowController.show()
            }
        }
    }

    @MainActor
    private func syncStars() {
        guard let dependencies,
              let user = dependencies.authSession.state.user
        else {
            NSApp.activate(ignoringOtherApps: true)
            dependencies?.authSession.requestLoginSheet()
            return
        }
        dependencies.syncManager.performFullSync(userID: user.id, force: true)
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
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Release Notes

/// Release Notes 窗口尺寸。
private enum ReleaseNotesWindowMetrics {
    static let defaultContentSize = NSSize(width: 620, height: 520)
    static let minimumContentSize = NSSize(width: 540, height: 420)
}

/// App 内静态版本说明窗口。
///
/// 首版只需要一个可从 Help 菜单打开的说明面板，不接 Sparkle / GitHub Releases
/// 之类自动更新链路，避免上架前引入额外分发和网络语义。
private final class ReleaseNotesWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: ReleaseNotesWindowController?

    @MainActor
    static func show() {
        let controller: ReleaseNotesWindowController
        let shouldCenter: Bool

        if let shared {
            controller = shared
            shouldCenter = false
        } else {
            controller = ReleaseNotesWindowController()
            shared = controller
            shouldCenter = true
        }

        controller.showWindow(nil)
        if shouldCenter {
            controller.window?.center()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init() {
        let content = ReleaseNotesView()
            .starcatAnimationOverride()
            .appLocaleEnvironment()
            .environment(AppSettings.shared)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)

        window.title = String.l10n("releaseNotes.window.title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(ReleaseNotesWindowMetrics.defaultContentSize)
        window.contentMinSize = ReleaseNotesWindowMetrics.minimumContentSize
        window.minSize = ReleaseNotesWindowMetrics.minimumContentSize
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReleaseNotesWindowController does not support storyboard initialization")
    }

    func windowWillClose(_ notification: Notification) {
        window?.resignKey()
    }
}

/// Release Notes 的 SwiftUI 内容。
///
/// 内容来自 App bundle 内的更新日志。`project.yml` 的构建脚本负责在 codesign 前
/// 同步拷贝英文 `CHANGELOG.md` 与中文 `CHANGELOG-ZH.md`。
private struct ReleaseNotesView: View {
    @State private var expandedVersionIDs: Set<String> = []
    @State private var localeStore = LocaleStore.shared

    var body: some View {
        let document = ChangelogParser.parse(
            ReleaseNotesLoader.loadBundledChangelog(for: localeStore.selection)
        )

        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ReleaseNotesHero()

                if let latestVersion = document.latestVersion {
                    ReleaseNotesVersionCard(
                        version: latestVersion,
                        isLatest: true,
                        isExpanded: true,
                        toggle: nil
                    )
                }

                ForEach(document.previousVersions) { version in
                    ReleaseNotesVersionCard(
                        version: version,
                        isLatest: false,
                        isExpanded: expandedVersionIDs.contains(version.id),
                        toggle: {
                            toggleVersion(version.id)
                        }
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.52))
    }

    private func toggleVersion(_ id: String) {
        if expandedVersionIDs.contains(id) {
            expandedVersionIDs.remove(id)
        } else {
            expandedVersionIDs.insert(id)
        }
    }
}

private struct ReleaseNotesHero: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("releaseNotes.hero.title")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text("releaseNotes.hero.subtitle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) {
            Divider()
                .offset(y: 18)
        }
    }
}

private struct ReleaseNotesVersionCard: View {
    let version: ChangelogVersion
    let isLatest: Bool
    let isExpanded: Bool
    let toggle: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let toggle {
                Button(action: toggle) {
                    ReleaseNotesVersionTitle(
                        title: version.title,
                        isExpanded: isExpanded,
                        showsDisclosureIcon: true
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            } else {
                ReleaseNotesVersionTitle(
                    title: version.title,
                    isExpanded: true,
                    showsDisclosureIcon: false,
                    badgeText: "releaseNotes.badge.new"
                )
            }

            if isExpanded {
                changelogBody
            }
        }
        .padding(18)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        }
    }

    private var changelogBody: some View {
        Markdown(version.bodyMarkdown)
            .font(.body)
            .textSelection(.enabled)
            .padding(.leading, 26)
    }

    private var cardBackground: Color {
        if isLatest {
            return Color.accentColor.opacity(0.07)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var cardBorder: Color {
        if isLatest {
            return Color.accentColor.opacity(0.18)
        }
        return Color(nsColor: .separatorColor).opacity(0.55)
    }
}

private struct ReleaseNotesVersionTitle: View {
    let title: String
    let isExpanded: Bool
    let showsDisclosureIcon: Bool
    var badgeText: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.title.weight(.bold))
                .foregroundStyle(.primary)

            if let badgeText {
                Text(LocalizedStringKey(badgeText))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }

            Spacer(minLength: 0)

            if showsDisclosureIcon {
                Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.16), value: isExpanded)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}

private struct ChangelogDocument {
    let preamble: String?
    let versions: [ChangelogVersion]

    var latestVersion: ChangelogVersion? {
        versions.first
    }

    var previousVersions: ArraySlice<ChangelogVersion> {
        versions.dropFirst()
    }
}

private struct ChangelogVersion: Identifiable {
    let id: String
    let title: String
    let bodyMarkdown: String

    var markdown: String {
        "## \(title)\n\n\(bodyMarkdown)"
    }
}

private enum ChangelogParser {
    static func parse(_ markdown: String) -> ChangelogDocument {
        let lines = markdown.components(separatedBy: .newlines)
        var preambleLines: [String] = []
        var versions: [ChangelogVersion] = []
        var currentTitle: String?
        var currentBodyLines: [String] = []

        for line in lines {
            if let title = versionTitle(from: line) {
                appendVersion(title: currentTitle, bodyLines: currentBodyLines, to: &versions)
                currentTitle = title
                currentBodyLines = []
            } else if currentTitle == nil {
                preambleLines.append(line)
            } else {
                currentBodyLines.append(line)
            }
        }
        appendVersion(title: currentTitle, bodyLines: currentBodyLines, to: &versions)

        let preamble = normalizedMarkdown(from: preambleLines)
        return ChangelogDocument(
            preamble: preamble.isEmpty ? nil : preamble,
            versions: versions
        )
    }

    /// 只按 Keep a Changelog 的二级标题切版本，避免把三级功能小节误判为版本。
    private static func versionTitle(from line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        let rawTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawTitle.isEmpty == false else { return nil }

        if rawTitle.hasPrefix("["),
           let closingBracket = rawTitle.firstIndex(of: "]") {
            let version = rawTitle[rawTitle.index(after: rawTitle.startIndex)..<closingBracket]
            let suffix = rawTitle[rawTitle.index(after: closingBracket)...]
            return "\(version)\(suffix)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rawTitle
    }

    private static func appendVersion(
        title: String?,
        bodyLines: [String],
        to versions: inout [ChangelogVersion]
    ) {
        guard let title else { return }
        versions.append(
            ChangelogVersion(
                id: title,
                title: title,
                bodyMarkdown: normalizedMarkdown(from: bodyLines)
            )
        )
    }

    private static func normalizedMarkdown(from lines: [String]) -> String {
        lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 读取随 App 打包的 CHANGELOG。
///
/// 这里保持同步读取：文件体积很小，窗口打开时读一次即可；失败时返回短 Markdown
/// 兜底，避免 Help 菜单能打开窗口但内容区域空白。
private enum ReleaseNotesLoader {
    static func loadBundledChangelog(for appLocale: AppLocale) -> String {
        for resourceName in preferredResourceNames(for: appLocale) {
            if let markdown = loadMarkdown(resourceName: resourceName) {
                return markdown
            }
        }
        return fallbackMarkdown
    }

    /// `LocaleStore` 的 `.system` 代表跟随系统，因此要按系统语言列表决定中文/英文文件。
    /// 中文文件缺失时总是回退英文，避免中文 bundle 资源漏拷导致发布说明空白。
    private static func preferredResourceNames(for appLocale: AppLocale) -> [String] {
        switch appLocale {
        case .simplifiedChinese:
            return ["CHANGELOG-ZH", "CHANGELOG"]
        case .english:
            return ["CHANGELOG"]
        case .system:
            if systemPrefersChinese {
                return ["CHANGELOG-ZH", "CHANGELOG"]
            }
            return ["CHANGELOG"]
        }
    }

    private static var systemPrefersChinese: Bool {
        let identifier = Bundle.main.preferredLocalizations.first
            ?? Locale.preferredLanguages.first
            ?? Locale.current.identifier
        return Locale.Language(identifier: identifier).languageCode?.identifier == "zh"
    }

    private static func loadMarkdown(resourceName: String) -> String? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "md"),
              let markdown = try? String(contentsOf: url, encoding: .utf8),
              markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            return nil
        }
        return markdown
    }

    private static let fallbackMarkdown = """
    # Release Notes

    The bundled changelog is temporarily unavailable.
    """
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
	struct DebugMenuCommands: Commands {
        @AppStorage(DebugFlags.debugProOverrideKey) private var debugProOverride = false
        @AppStorage(DebugFlags.agentToolbarEntryKey) private var agentToolbarEntry = false

		var body: some Commands {
			CommandMenu("Who's Your Daddy") {
				Button("Replay First-Run Onboarding") {
					FirstRunOnboardingPreferences.resetForDebugReplay()
					NotificationCenter.default.post(
						name: FirstRunOnboardingPreferences.debugReplayNotification,
						object: nil
					)
				}

                Button("Open Knowledge RAG Workspace") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .starcatCommandOpenKnowledgeRAGWorkspace, object: nil)
                }

				Divider()

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

                    Toggle(
                        "Show Agent Toolbar Entry",
                        isOn: Binding(
                            get: { agentToolbarEntry },
                            set: { newValue in
                                agentToolbarEntry = newValue
                                DebugFlags.setAgentToolbarEntry(newValue)
                            }
                        )
                    )
                }
            }
        }
#endif
