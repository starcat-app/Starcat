//
//  StatusBarController.swift
//  Starcat
//
//  macOS 菜单栏入口。
//
//  设计约束:
//  - Starcat 仍是普通窗口应用，菜单栏入口只是常驻快捷面板；用户选择隐藏 Dock 后，
//    这里就成为恢复主窗口的固定路径。
//  - SwiftUI `MenuBarExtra` 无法可靠区分左键状态面板、右键快捷菜单，因此这里使用
//    AppKit `NSStatusItem` 自行处理鼠标事件。
//  - 菜单内容每次右键时动态生成，确保同步状态、Browser Plugin Service、MCP 开关
//    都读取最新对象，而不是缓存一份过期菜单。
//

import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    static let shared = StatusBarController()

    var openLocalAILogWindow: (() -> Void)?

    private var statusItem: NSStatusItem?
    private weak var dependencies: AppDependencies?
    private let pluginConfiguration = CompanionConfiguration.shared
    private let diagnostics = AppStatusDiagnostics()
    private var statusPopover: NSPopover?
    private var afterStatusPopoverClose: (() -> Void)?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    private override init() {
        super.init()
    }

    func configure(dependencies: AppDependencies) {
        self.dependencies = dependencies
        installStatusItemIfNeeded()
    }

    private func installStatusItemIfNeeded() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.image = Self.makeStatusIcon()
        button.imagePosition = .imageOnly
        button.toolTip = "Starcat"
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        switch NSApp.currentEvent?.type {
        case .rightMouseUp:
            statusPopover?.close()
            showContextMenu()
        default:
            if let statusPopover {
                statusPopover.close()
            } else {
                showStatusPopover(anchoredTo: sender)
            }
        }
    }

    /// 浮层只依赖状态栏锚点。这里不激活应用，也不查找或恢复主窗口。
    private func showStatusPopover(anchoredTo button: NSStatusBarButton) {
        guard let dependencies, button.window != nil else { return }
        let popover = NSPopover()
        let height = min(
            AppStatusPopover.maximumHeight,
            (button.window?.screen?.visibleFrame.height ?? AppStatusPopover.maximumHeight + 32) - 32
        )
        let content = AppStatusPopover(
            diagnostics: diagnostics,
            loadsStoredSyncDate: true,
            dismissThen: { [weak self] action in
                self?.afterStatusPopoverClose = action
                self?.statusPopover?.close()
            },
            onOpenWorkspaceTask: { id in
                dependencies.mainWindowNavigationDispatcher.navigate(
                    to: .statusTask(id, accountID: dependencies.authSession.state.user?.id)
                )
            },
            onOpenLocalAILogs: { [weak self] in self?.openLocalAILogWindow?() }
        )
        .frame(width: AppStatusPopover.contentWidth, height: height)
        .appHostEnvironment(dependencies)

        popover.contentViewController = NSHostingController(rootView: content)
        popover.contentSize = NSSize(width: AppStatusPopover.contentWidth, height: height)
        // 自行处理外部按下事件，避免系统先关闭浮层，再由同一次 mouseUp 把它重新打开。
        popover.behavior = .applicationDefined
        popover.animates = !dependencies.settings.disableAnimations && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        statusPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        guard popover.isShown else {
            statusPopover = nil
            return
        }
        button.highlight(true)
        monitorOutsideClicks(button: button, popover: popover)
    }

    private func monitorOutsideClicks(button: NSStatusBarButton, popover: NSPopover) {
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [mouseDown, .keyDown]) { [weak button, weak popover] event in
            guard let popover, let popoverWindow = popover.contentViewController?.view.window else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53, event.window === popoverWindow else { return event }
                popover.close()
                return nil
            }
            if event.window !== popoverWindow, event.window !== button?.window {
                popover.close()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) { [weak popover] _ in
            popover?.close()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === statusPopover else { return }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
        statusPopover = nil
        if statusItem?.menu == nil {
            statusItem?.button?.highlight(false)
        }
        let action = afterStatusPopoverClose
        afterStatusPopoverClose = nil
        if let action {
            DispatchQueue.main.async { action() }
        }
    }

    private func showContextMenu() {
        guard let statusItem, let button = statusItem.button else { return }
        let menu = makeMenu()
        menu.delegate = self
        // `popUpMenu(_:)` 已废弃；右键时临时绑定 menu 后触发按钮点击，
        // 菜单关闭后再解绑，避免左键也变成展开菜单。
        statusItem.menu = menu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(actionItem(
            title: String.l10n("menubar.openStarcat"),
            action: #selector(openMainWindow),
            imageName: "macwindow"
        ))
        menu.addItem(actionItem(
            title: String.l10n("menubar.openSettings"),
            action: #selector(openSettings),
            imageName: "gearshape"
        ))
        menu.addItem(NSMenuItem.separator())

        addStatusSection(to: menu)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(toggleItem(
            title: String.l10n("menubar.pluginService"),
            isOn: pluginConfiguration.isEnabled,
            action: #selector(togglePluginService)
        ))
        if let dependencies {
            menu.addItem(toggleItem(
                title: String.l10n("menubar.mcpService"),
                isOn: dependencies.settings.mcpServiceEnabled,
                action: #selector(toggleMCPService)
            ))
            menu.addItem(toggleItem(
                title: String.l10n("menubar.notifications"),
                isOn: dependencies.settings.notificationsEnabled,
                action: #selector(toggleNotifications)
            ))
            menu.addItem(actionItem(
                title: String.l10n("menubar.syncStars"),
                action: #selector(syncStars),
                imageName: "arrow.triangle.2.circlepath"
            ))
            if dependencies.directUpdateController.isDirectBuild {
                let updateItem = actionItem(
                    title: String.l10n("menubar.checkForUpdates"),
                    action: #selector(checkForUpdates),
                    imageName: "arrow.down.circle"
                )
                updateItem.isEnabled = dependencies.directUpdateController.canCheckForUpdates
                menu.addItem(updateItem)
            } else if dependencies.appStoreUpdateController.isAppStoreBuild {
                let updateItem = actionItem(
                    title: String.l10n("menubar.checkForUpdates"),
                    action: #selector(checkForUpdates),
                    imageName: "arrow.down.circle"
                )
                updateItem.isEnabled = dependencies.appStoreUpdateController.canCheckForUpdates
                menu.addItem(updateItem)
            }
        }

        let resetItem = actionItem(
            title: String.l10n("settings.listPreferences.reset.title"),
            action: #selector(resetListPreferences),
            imageName: "arrow.counterclockwise"
        )
        resetItem.isEnabled = dependencies?.authSession.state.isAuthenticated == true
        menu.addItem(resetItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(actionItem(
            title: String.l10n("app.about"),
            action: #selector(openAbout),
            imageName: "info.circle"
        ))
        menu.addItem(actionItem(
            title: String.l10n("menubar.quit"),
            action: #selector(quit),
            imageName: "power"
        ))

        return menu
    }

    private func addStatusSection(to menu: NSMenu) {
        let loginValue: String
        if let user = dependencies?.authSession.state.user {
            loginValue = "@\(user.login)"
        } else {
            loginValue = String.l10n("menubar.status.notSignedIn")
        }
        menu.addItem(infoItem(title: String.l10n("menubar.status.account"), value: loginValue))

        if let dependencies {
            menu.addItem(infoItem(
                title: String.l10n("menubar.status.sync"),
                value: syncStatusText(state: dependencies.syncManager.state)
            ))
            menu.addItem(infoItem(
                title: String.l10n("menubar.status.mcp"),
                value: mcpStatusText(state: dependencies.mcpService.state)
            ))
        }

        menu.addItem(infoItem(
            title: String.l10n("menubar.status.plugin"),
            value: pluginStatusText()
        ))
        menu.addItem(infoItem(
            title: String.l10n("settings.integration.browserPlugin.endpoint"),
            value: "127.0.0.1:\(pluginConfiguration.port)"
        ))
    }

    private func actionItem(title: String, action: Selector, imageName: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: imageName, accessibilityDescription: title)
        return item
    }

    private func toggleItem(title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = actionItem(title: title, action: action, imageName: isOn ? "checkmark.circle" : "circle")
        item.state = isOn ? .on : .off
        return item
    }

    private func infoItem(title: String, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title): \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func syncStatusText(state: SyncState) -> String {
        switch state {
        case .idle:
            return String.l10n("menubar.status.idle")
        case .syncing:
            return String.l10n("menubar.status.syncing")
        case .completed:
            return String.l10n("menubar.status.completed")
        case .failed:
            return String.l10n("menubar.status.failed")
        case .rateLimited:
            return String.l10n("menubar.status.rateLimited")
        }
    }

    private func pluginStatusText() -> String {
        switch pluginConfiguration.serverStatus {
        case .stopped:
            return String.l10n("settings.integration.browserPlugin.status.stopped")
        case .starting:
            return String.l10n("settings.integration.browserPlugin.status.starting")
        case .running:
            return String.l10n("settings.integration.browserPlugin.status.running")
        case .failed(let failure):
            return failure.localizedDescription
        }
    }

    private func mcpStatusText(state: StarcatMCPService.State) -> String {
        switch state {
        case .stopped:
            return String.l10n("settings.mcp.status.stopped")
        case .running:
            return String.l10n("settings.mcp.status.running")
        case .failed:
            return String.l10n("settings.mcp.status.failed")
        }
    }

    @objc private func openMainWindow() {
        AppDelegate.activateMainWindowIfPossible()
    }

    @objc private func openSettings() {
        AppDelegate.openSettingsWindow()
    }

    @objc private func togglePluginService() {
        pluginConfiguration.isEnabled.toggle()
        CompanionServiceBootstrapper.apply(configuration: pluginConfiguration)
    }

    @objc private func toggleMCPService() {
        guard let dependencies else { return }
        dependencies.settings.mcpServiceEnabled.toggle()
        dependencies.mcpService.refreshForCurrentSettings()
    }

    @objc private func toggleNotifications() {
        dependencies?.settings.notificationsEnabled.toggle()
    }

    @objc private func syncStars() {
        guard let dependencies,
              let user = dependencies.authSession.state.user
        else {
            AppDelegate.activateMainWindowIfPossible()
            dependencies?.authSession.requestLoginSheet()
            return
        }
        dependencies.syncManager.performFullSync(userID: user.id, force: true, trigger: .manual)
    }

    @objc private func checkForUpdates() {
        guard let dependencies else { return }
        if dependencies.directUpdateController.isDirectBuild {
            dependencies.directUpdateController.checkForUpdates()
            return
        }

        // App Store 版的结果由主窗口 SwiftUI alert 呈现；菜单栏触发时先恢复主窗口，
        // 避免窗口已关闭导致状态更新后用户看不到任何反馈。
        AppDelegate.activateMainWindowIfPossible()
        Task {
            await dependencies.appStoreUpdateController.checkManually()
        }
    }

    @objc private func resetListPreferences() {
        AppDelegate.activateMainWindowIfPossible()
        NotificationCenter.default.post(name: .starcatResetListPreferencesRequested, object: nil)
    }

    @objc private func openAbout() {
        AboutPanelController.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            let silhouette = CGMutablePath()
            silhouette.move(to: CGPoint(x: 2, y: 10.15))
            silhouette.addQuadCurve(to: CGPoint(x: 2.8, y: 3), control: CGPoint(x: 2, y: 6.8))
            silhouette.addQuadCurve(to: CGPoint(x: 4, y: 2.6), control: CGPoint(x: 3.05, y: 1.9))
            silhouette.addLine(to: CGPoint(x: 6.75, y: 4.78))
            silhouette.addQuadCurve(to: CGPoint(x: 11.25, y: 4.78), control: CGPoint(x: 9, y: 4))
            silhouette.addLine(to: CGPoint(x: 14, y: 2.6))
            silhouette.addQuadCurve(to: CGPoint(x: 15.2, y: 3), control: CGPoint(x: 14.95, y: 1.9))
            silhouette.addQuadCurve(to: CGPoint(x: 16, y: 10.15), control: CGPoint(x: 16, y: 6.8))
            silhouette.addCurve(
                to: CGPoint(x: 9, y: 16),
                control1: CGPoint(x: 16, y: 13.75),
                control2: CGPoint(x: 13.15, y: 16)
            )
            silhouette.addCurve(
                to: CGPoint(x: 2, y: 10.15),
                control1: CGPoint(x: 4.85, y: 16),
                control2: CGPoint(x: 2, y: 13.75)
            )
            silhouette.closeSubpath()

            // 四角星需要是透明镂空，才能在菜单栏反色时保留清晰轮廓。
            silhouette.move(to: CGPoint(x: 9, y: 6.5))
            silhouette.addLine(to: CGPoint(x: 10.1, y: 8.9))
            silhouette.addLine(to: CGPoint(x: 12.5, y: 10))
            silhouette.addLine(to: CGPoint(x: 10.1, y: 11.1))
            silhouette.addLine(to: CGPoint(x: 9, y: 13.5))
            silhouette.addLine(to: CGPoint(x: 7.9, y: 11.1))
            silhouette.addLine(to: CGPoint(x: 5.5, y: 10))
            silhouette.addLine(to: CGPoint(x: 7.9, y: 8.9))
            silhouette.closeSubpath()

            context.setFillColor(gray: 0, alpha: 1)
            context.addPath(silhouette)
            context.fillPath(using: .evenOdd)
            return true
        }

        // 由状态栏按钮按当前外观与按压状态着色，避免锁定为创建图标时的颜色。
        image.isTemplate = true
        return image
    }
}
