//
//  StatusBarController.swift
//  Starcat
//
//  macOS 菜单栏入口。
//
//  设计约束:
//  - Starcat 仍是普通窗口应用，菜单栏入口只是常驻快捷面板；用户选择隐藏 Dock 后，
//    这里就成为恢复主窗口的固定路径。
//  - SwiftUI `MenuBarExtra` 无法可靠区分左键打开窗口、右键展示菜单，因此这里使用
//    AppKit `NSStatusItem` 自行处理鼠标事件。
//  - 菜单内容每次右键时动态生成，确保同步状态、Browser Plugin Service、MCP 开关
//    都读取最新对象，而不是缓存一份过期菜单。
//

import AppKit

@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private weak var dependencies: AppDependencies?
    private let pluginConfiguration = CompanionConfiguration.shared

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
            showContextMenu()
        default:
            AppDelegate.activateMainWindowIfPossible()
        }
    }

    private func showContextMenu() {
        guard let statusItem else { return }
        statusItem.popUpMenu(makeMenu())
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
        }

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
        case .failed:
            return String.l10n("settings.integration.browserPlugin.status.failed")
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
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: self)
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
        dependencies.syncManager.performFullSync(userID: user.id, force: true)
    }

    @objc private func openAbout() {
        AboutPanelController.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func makeStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer {
            image.unlockFocus()
            image.isTemplate = true
        }

        NSColor.labelColor.setStroke()
        NSColor.labelColor.setFill()

        let head = NSBezierPath()
        head.move(to: NSPoint(x: 2.8, y: 3.8))
        head.line(to: NSPoint(x: 2.8, y: 12.6))
        head.line(to: NSPoint(x: 6.0, y: 16.0))
        head.line(to: NSPoint(x: 8.0, y: 13.7))
        head.line(to: NSPoint(x: 10.0, y: 13.7))
        head.line(to: NSPoint(x: 12.0, y: 16.0))
        head.line(to: NSPoint(x: 15.2, y: 12.6))
        head.line(to: NSPoint(x: 15.2, y: 3.8))
        head.close()
        head.lineWidth = 1.8
        head.stroke()

        // 菜单栏会按模板图缩放着色；轮廓尽量占满 18pt 画布，避免与系统状态图标相比显小。
        let star = NSBezierPath()
        star.move(to: NSPoint(x: 9.0, y: 11.4))
        star.line(to: NSPoint(x: 9.8, y: 9.8))
        star.line(to: NSPoint(x: 11.5, y: 9.6))
        star.line(to: NSPoint(x: 10.2, y: 8.4))
        star.line(to: NSPoint(x: 10.5, y: 6.7))
        star.line(to: NSPoint(x: 9.0, y: 7.6))
        star.line(to: NSPoint(x: 7.5, y: 6.7))
        star.line(to: NSPoint(x: 7.8, y: 8.4))
        star.line(to: NSPoint(x: 6.5, y: 9.6))
        star.line(to: NSPoint(x: 8.2, y: 9.8))
        star.close()
        star.fill()

        return image
    }
}
