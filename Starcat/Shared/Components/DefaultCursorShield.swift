//
//  DefaultCursorShield.swift
//  Starcat
//
//  macOS cursor rect 接管层：用于覆盖在 SwiftUI 浮层 / 面板上，避免底层
//  WKWebView 或其他 AppKit view 的 cursor rect 穿透到当前第一层面板。
//

import AppKit
import SwiftUI

/// 让当前 SwiftUI 面板在整块区域内使用默认箭头光标。
///
/// SwiftUI 的 `contentShape` / `allowsHitTesting` 只影响事件命中，不会自动接管
/// AppKit 的 cursor rect。README 的 WKWebView 图片会注册 `zoom-in` 光标，如果上层
/// 面板没有自己的 cursor rect，鼠标移到面板上仍可能显示底层光标。
struct DefaultCursorShield: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DefaultCursorShieldView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class DefaultCursorShieldView: NSView {
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 只负责 cursor rect，不拦截按钮点击、hover 和滚动事件。
        nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

extension View {
    /// 为顶层面板注册默认箭头光标，防止底层 AppKit / WebView 光标穿透。
    func defaultCursorShield() -> some View {
        overlay {
            DefaultCursorShield()
        }
    }
}
