//
//  AmbientWindowController.swift
//  Starcat
//
//  Ambient 的窄 AppKit 桥：NSWindowController 只拥有全屏切换与销毁时机，
//  Catalog、deadline 和 SwiftUI 状态全部由 AmbientViewModel 管理。
//

import AppKit
import SwiftUI

/// 可单测的全屏窗口阶段。
enum AmbientWindowPhase: Equatable, Sendable {
    case closed
    case opening
    case enteringFullScreen
    case fullScreen
    case exitingFullScreen
    case closing
}

/// 生命周期状态机交给 AppKit 壳执行的唯一副作用。
enum AmbientWindowAction: Equatable, Sendable {
    case enterFullScreen
    case exitFullScreen
    case close
}

/// 约束进入中快速退出、系统 Esc 与失败收口的纯值状态机。
struct AmbientWindowLifecycle: Equatable, Sendable {
    private(set) var phase: AmbientWindowPhase = .closed
    private(set) var hasPendingClose = false

    mutating func beginOpening() {
        guard phase == .closed else { return }
        phase = .opening
    }

    mutating func requestEnterFullScreen() -> AmbientWindowAction? {
        guard phase == .opening else { return nil }
        phase = .enteringFullScreen
        return .enterFullScreen
    }

    mutating func didEnterFullScreen() -> AmbientWindowAction? {
        guard phase == .enteringFullScreen else { return nil }
        if hasPendingClose {
            phase = .exitingFullScreen
            return .exitFullScreen
        }
        phase = .fullScreen
        return nil
    }

    mutating func requestClose() -> AmbientWindowAction? {
        switch phase {
        case .closed, .closing:
            return nil
        case .opening, .enteringFullScreen:
            hasPendingClose = true
            return nil
        case .fullScreen:
            hasPendingClose = true
            phase = .exitingFullScreen
            return .exitFullScreen
        case .exitingFullScreen:
            hasPendingClose = true
            return nil
        }
    }

    mutating func didFailToEnterFullScreen() -> AmbientWindowAction? {
        guard phase == .enteringFullScreen else { return nil }
        phase = .closing
        return .close
    }

    mutating func didExitFullScreen() -> AmbientWindowAction? {
        guard phase == .fullScreen || phase == .exitingFullScreen else { return nil }
        phase = .closing
        return .close
    }

    mutating func didClose() {
        phase = .closed
        hasPendingClose = false
    }
}

/// 进入即全屏、退出即销毁的短生命周期媒体窗口。
@MainActor
final class AmbientWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: AmbientWindowController?

    private let viewModel: AmbientViewModel
    private var lifecycle = AmbientWindowLifecycle()

    static func show(dependencies: AppDependencies, scene: AmbientSceneKind) {
        if let shared {
            shared.viewModel.switchScene(scene)
            shared.showWindow(nil)
            shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = AmbientWindowController(dependencies: dependencies, scene: scene)
        shared = controller
        controller.lifecycle.beginOpening()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor [weak controller] in
            // 等窗口真正挂到 screen 后再进入全屏，避免 AppKit 在无 screen 阶段拒绝切换。
            await Task.yield()
            guard let controller else { return }
            controller.perform(controller.lifecycle.requestEnterFullScreen())
        }
    }

    private init(dependencies: AppDependencies, scene: AmbientSceneKind) {
        let viewModel = AmbientViewModel(
            catalog: LocalAmbientCatalog(repository: dependencies.repoRepository),
            initialScene: scene
        )
        self.viewModel = viewModel

        let rootView = AmbientRootView(
            viewModel: viewModel,
            onExit: {
                AmbientWindowController.shared?.requestClose()
            }
        )
        .appHostEnvironment(dependencies)
        .preferredColorScheme(.dark)

        let hostingController = NSHostingController(rootView: rootView)
        let screenFrame = (NSApp.keyWindow?.screen ?? NSScreen.main)?.frame
            ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        let window = NSWindow(
            contentRect: screenFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = String.l10n("ambient.window.title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.collectionBehavior = [.fullScreenPrimary, .fullScreenDisallowsTiling]
        window.tabbingMode = .disallowed
        window.backgroundColor = .black
        window.isOpaque = true
        window.isReleasedWhenClosed = false
        window.setFrame(screenFrame, display: false)

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AmbientWindowController does not support storyboard initialization")
    }

    func requestClose() {
        perform(lifecycle.requestClose())
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        perform(lifecycle.didEnterFullScreen())
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        perform(lifecycle.didExitFullScreen())
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        AppLog.ui.error("Ambient failed to enter full screen")
        perform(lifecycle.didFailToEnterFullScreen())
    }

    func windowDidBecomeKey(_ notification: Notification) {
        viewModel.setWindowActive(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        viewModel.setWindowActive(false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return lifecycle.phase == .closing || lifecycle.phase == .closed
    }

    func windowWillClose(_ notification: Notification) {
        viewModel.cancelAll()
        lifecycle.didClose()
        if Self.shared === self {
            Self.shared = nil
        }
    }

    private func perform(_ action: AmbientWindowAction?) {
        guard let action else { return }
        switch action {
        case .enterFullScreen, .exitFullScreen:
            window?.toggleFullScreen(nil)
        case .close:
            window?.close()
        }
    }
}
