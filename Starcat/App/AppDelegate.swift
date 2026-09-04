//
//  AppDelegate.swift
//  Starcat
//
//  2026-06-29：NSApplicationDelegate，在 App 启动最早期注册 `NSAppleEventManager`
//  handler 拦截 `kAEGetURL`（即 `starcat://callback?code=...&state=...`）。
//
//  为什么不能只靠 `.onOpenURL`：
//  - `.onOpenURL` 是 SwiftUI View modifier，在 view mount 后才注册
//  - 浏览器跳 `starcat://callback` 时 Launch Services 先看"有没有已注册的 Apple Event
//    handler"——如果没有，就启动新进程
//  - `LSMultipleInstancesProhibited=true` 只阻止 Finder/Dock 双开，不阻止 URL scheme
//    启动新实例
//  - 解决办法：在 `applicationWillFinishLaunching` 里注册 `NSAppleEventManager` handler，
//    让已有实例在 Launch Services 决定"要不要开新进程"时就把 URL event 接住、消化掉
//
//  时序：
//  ① StarcatApp.init() 设 `AppDelegate.onIncomingURL` closure
//  ② `applicationWillFinishLaunching` 注册 `kAEGetURL` handler（窗口还没出现时）
//  ③ 浏览器跳 starcat://callback → macOS 派发 Apple Event → handler 解析 URL
//    → 调 onIncomingURL closure
//  ④ closure 取 `dependencies.authSession` 调 `handleWebFlowCallback(url:)`
//
//  关键约束：
//  - `dependencies` 是 StarcatApp 的 `@State`，AppDelegate 不能直接访问
//  - 用 `onIncomingURL` closure 桥接，避免循环引用
//  - handler 必须在 `applicationWillFinishLaunching` 注册（不是 `applicationDidFinishLaunching`：
//    前者在窗口出现前，后者在窗口出现后——URL event 可能在窗口出现前就被派发）
//

import AppKit
import AppIntents
import CoreSpotlight
import UserNotifications

/// 三件事：
/// 1. `applicationWillFinishLaunching` 注册 `NSAppleEventManager` handler 拦截
///    `kAEGetURL` — 存在即声明"已有实例监听 URL scheme"，Launch Services 不开新进程
/// 2. handler 内解析 URL → 通过 `NotificationCenter` 转发给 SwiftUI view 层
///    （`NSAppleEventManager` 会消费事件，导致 `.onOpenURL` 收不到——必须显式转发）
/// 3. 接收 Core Spotlight 的 `NSUserActivity`，把稳定 repository ID 转交主窗口路由。
///
/// 这里也承接 Dock reopen / 前台激活兜底。SwiftUI 只能挂一个
/// `NSApplicationDelegateAdaptor`，所以 AppKit 生命周期职责必须收敛在同一个 delegate，
/// 避免 OAuth URL handler 与窗口重开逻辑互相覆盖。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static let incomingURLNotification = Notification.Name("starcat.incomingURL")
    static var openMainWindowFallback: (() -> Void)?
    /// AppKit 菜单栏与独立窗口无法直接读取 SwiftUI `OpenWindowAction`，因此由主
    /// Scene 在出现时注册一个很薄的桥接。目标 Tab 仍由 Settings feature 自己路由。
    static var openSettingsWindowFallback: (() -> Void)?
    /// 首次创建 Settings Window 时，跳转通知可能先于 View 的订阅安装。
    /// 暂存最后一个目标，SettingsView 在 onAppear 兜底消费，避免靠固定延迟碰运气。
    private static var pendingSettingsTarget: String?
    private static weak var dependencies: AppDependencies?

    static func configure(dependencies: AppDependencies) {
        self.dependencies = dependencies
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        AppLog.auth.info("AppDelegate: registered kAEGetURL handler (single-instance guard + NotificationCenter forward)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Self.applyActivationPolicy(hideDockIcon: AppSettings.shared.hideDockIcon)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Starcat 有菜单栏常驻入口；关闭主窗口只表示隐藏工作区，不能让进程退出，
        // 否则隐藏 Dock 图标时用户会失去从菜单栏恢复主窗口的路径。
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard flag else {
            // 冷启动状态恢复可能报告“有持久化状态”，却没有真正恢复任何窗口。
            // 此时主 Scene 尚未出现，openWindow fallback 也还未注册；返回 true
            // 让 SwiftUI 按 `.defaultLaunchBehavior(.presented)` 创建唯一的 main Window，
            // 避免 AppDelegate 与主窗口 onAppear 互相等待而陷入零窗口状态。
            return true
        }

        Self.activateMainWindowIfPossible()
        // 返回 false 表示 Dock reopen 已由 Starcat 自己接管；如果返回 true，
        // AppKit/SwiftUI 会继续执行默认 reopen，和已有窗口激活叠加。
        return false
    }

    /// macOS 打开 Core Spotlight 条目时实际发送 `CSSearchableItemActionType` activity。
    ///
    /// App Intents 的 `OpenIntent` 仍保留给系统可用的执行路径；这里是 AppKit 原生回调，
    /// 两条入口最终都只发布 repository ID，避免 SwiftUI 出现第二套导航状态。
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        Self.handleSpotlightUserActivity(
            userActivity,
            using: Self.dependencies?.mainWindowNavigationDispatcher
        )
    }

    /// 解析和路由保持同步且位于 MainActor；测试可以注入独立 dispatcher，
    /// 无需启动 NSApplication 或访问真实 Spotlight 索引。
    @discardableResult
    static func handleSpotlightUserActivity(
        _ userActivity: NSUserActivity,
        using dispatcher: MainWindowNavigationDispatcher?
    ) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType else { return false }
        guard let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let repositoryID = repositoryID(fromSpotlightActivityIdentifier: identifier)
        else {
            let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String ?? "<missing>"
            // GitHub repository IDs are public; logging the malformed value is necessary to diagnose
            // OS-version-specific AppEntity identifier envelopes without exposing notes or credentials.
            AppLog.general.warning(
                "Core Spotlight repository activity has an invalid identifier: \(identifier, privacy: .public)"
            )
            return false
        }
        guard let dispatcher else {
            AppLog.general.error("Core Spotlight repository activity arrived before app dependencies were ready")
            return false
        }

        dispatcher.navigate(to: .spotlightRepository(repositoryID))
        AppLog.general.info("Core Spotlight repository activity routed to the main window")
        return true
    }

    private static func repositoryID(fromSpotlightActivityIdentifier identifier: String) -> Int64? {
        if let entityIdentifier = EntityIdentifier(activityIdentifier: identifier),
           ObjectIdentifier(entityIdentifier.entityType) == ObjectIdentifier(RepositorySpotlightEntity.self)
        {
            return Int64(entityIdentifier.identifier)
        }

        // `indexAppEntities` 在当前 macOS 上把 searchable-item unique identifier 编码为
        // `<AppEntity 类型>/<实体 ID>`；它不是 `EntityIdentifier` 的 activity envelope。
        // 这里只接受 Starcat 自己的精确类型前缀，避免把其它 Spotlight 条目的尾部数字误当仓库 ID。
        let components = identifier.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0] == Substring(String(describing: RepositorySpotlightEntity.self))
        else { return nil }
        return Int64(components[1])
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let resetItem = NSMenuItem(
            title: String.l10n("settings.listPreferences.reset.title"),
            action: #selector(resetListPreferencesFromDockMenu),
            keyEquivalent: ""
        )
        resetItem.target = self
        resetItem.image = NSImage(
            systemSymbolName: "arrow.counterclockwise",
            accessibilityDescription: String.l10n("settings.listPreferences.reset.title")
        )
        resetItem.isEnabled = Self.dependencies?.authSession.state.isAuthenticated == true
        menu.addItem(resetItem)

        return menu
    }

    @objc private func resetListPreferencesFromDockMenu() {
        Self.activateMainWindowIfPossible()
        NotificationCenter.default.post(name: .starcatResetListPreferencesRequested, object: nil)
    }

    @objc private func handleGetURLEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else {
            AppLog.auth.warning("AppDelegate: kAEGetURL event missing URL string")
            return
        }
        // OAuth callback query 可能包含一次性 code 与 state；日志只记录路由，
        // 避免主登录和 GitHub App 项目授权的敏感参数进入本机日志。
        AppLog.auth.info(
            "AppDelegate: forwarding URL via NotificationCenter: scheme=\(url.scheme ?? "", privacy: .public) host=\(url.host ?? "", privacy: .public) path=\(url.path, privacy: .public)"
        )
        // post 到主队列，让 .onReceive 在同一次 run loop 里收到
        NotificationCenter.default.post(name: Self.incomingURLNotification, object: url)
    }

    /// Dock reopen 兜底只处理 AppKit 窗口层，不触碰 `AppDependencies` 或 SwiftUI 状态。
    /// 这样用户关闭主窗口后再次点击 Dock 可以恢复已有窗口，同时不改变业务生命周期。
    /// 根据用户偏好切换 Dock 图标显隐。
    ///
    /// `.accessory` 会隐藏 Dock 和 Cmd+Tab 入口，因此菜单栏 `NSStatusItem` 必须常驻，
    /// 否则用户关闭主窗口后缺少可发现的恢复路径。
    static func applyActivationPolicy(hideDockIcon: Bool) {
        NSApp.setActivationPolicy(hideDockIcon ? .accessory : .regular)
    }

    /// 恢复并激活主窗口。Dock reopen 和菜单栏左键共用这条路径，避免出现两套
    /// “打开主窗口”语义。
    static func activateMainWindowIfPossible() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = mainWindowCandidate() else {
            // 主窗口被关闭后，SwiftUI WindowGroup 对应的 NSWindow 已经从
            // NSApp.windows 移除；这时必须回到 SwiftUI 的 openWindow(id:)
            // 创建窗口，不能只激活 AppKit 进程。
            AppLog.general.info("Main window missing; invoking SwiftUI openWindow fallback")
            openMainWindowFallback?()
            return
        }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// 打开唯一的设置窗口，并可选定位到指定设置页或区块。
    ///
    /// 这里不自行创建 `NSWindow`：窗口生命周期仍由 SwiftUI `Window` scene 管理，
    /// 才能保留系统交通灯、工具栏、状态恢复与 `openWindow(id:)` 的单例语义。
    static func openSettingsWindow(target: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let target {
            pendingSettingsTarget = target
            // 已存在的设置窗口可立即消费；尚未创建时由 onAppear 读取 pending。
            NotificationCenter.default.post(name: .starcatJumpToSettingsTab, object: target)
        }
        openSettingsWindowFallback?()
    }

    /// SettingsView 首次出现时消费尚未被通知订阅处理的深链目标。
    static func consumePendingSettingsTarget() -> String? {
        defer { pendingSettingsTarget = nil }
        return pendingSettingsTarget
    }

    /// 已打开的 SettingsView 收到通知后确认消费，避免窗口下次重建时重复跳转。
    static func acknowledgeSettingsTarget(_ target: String) {
        guard pendingSettingsTarget == target else { return }
        pendingSettingsTarget = nil
    }

    private static func mainWindowCandidate() -> NSWindow? {
        NSApp.windows.first { window in
            window.frameAutosaveName == MainWindowFrameDefaults.autosaveName
        } ?? NSApp.windows.first { window in
            // 冷启动早期 MainWindowFrameReader 可能尚未写入 autosaveName。
            // 用 WindowGroup 的标题做短暂兜底，避免启动期误判为"没有主窗口"。
            window.title == "Starcat" && window.canBecomeMain
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// 前台也展示 banner。点击走 didReceive。
    ///
    /// 必须 `nonisolated`：系统从非主 actor 调 delegate，Swift 6 不允许把
    /// 非 Sendable 的 `UNUserNotificationCenter` / `UNNotification` 送进 `@MainActor` AppDelegate。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let threadId = response.notification.request.content.userInfo["threadId"] as? String
        await MainActor.run {
            if let threadId {
                NotificationCenter.default.post(
                    name: .starcatOpenGitHubNotification,
                    object: nil,
                    userInfo: ["threadId": threadId]
                )
            }
            Self.activateMainWindowIfPossible()
        }
    }
}
