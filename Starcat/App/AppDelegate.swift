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

/// 两件事：
/// 1. `applicationWillFinishLaunching` 注册 `NSAppleEventManager` handler 拦截
///    `kAEGetURL` — 存在即声明"已有实例监听 URL scheme"，Launch Services 不开新进程
/// 2. handler 内解析 URL → 通过 `NotificationCenter` 转发给 SwiftUI view 层
///    （`NSAppleEventManager` 会消费事件，导致 `.onOpenURL` 收不到——必须显式转发）
///
/// 这里也承接 Dock reopen / 前台激活兜底。SwiftUI 只能挂一个
/// `NSApplicationDelegateAdaptor`，所以 AppKit 生命周期职责必须收敛在同一个 delegate，
/// 避免 OAuth URL handler 与窗口重开逻辑互相覆盖。
final class AppDelegate: NSObject, NSApplicationDelegate {

    static let incomingURLNotification = Notification.Name("starcat.incomingURL")

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
        NSApp.setActivationPolicy(.regular)
        activateMainWindowIfPossible()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        activateMainWindowIfPossible()
        return true
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
        AppLog.auth.info("AppDelegate: forwarding URL via NotificationCenter: \(url.absoluteString, privacy: .public)")
        // post 到主队列，让 .onReceive 在同一次 run loop 里收到
        NotificationCenter.default.post(name: Self.incomingURLNotification, object: url)
    }

    /// Dock reopen 兜底只处理 AppKit 窗口层，不触碰 `AppDependencies` 或 SwiftUI 状态。
    /// 这样用户关闭主窗口后再次点击 Dock 可以恢复已有窗口，同时不改变业务生命周期。
    private func activateMainWindowIfPossible() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows
                .first { !$0.isMiniaturized }
                .map { window in
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                }
        }
    }
}
