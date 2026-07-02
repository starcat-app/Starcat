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
        // 只做 cursor 接管，不参与点击命中。SwiftUI 面板内的按钮、hover 和滚动
        // 仍应由原本的控件处理；cursor 则通过前层 tracking area 在事件尾部抢回。
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
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        enforceArrowCursor(for: event)
    }

    override func mouseMoved(with event: NSEvent) {
        enforceArrowCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        enforceArrowCursor(for: event)
    }

    private func enforceArrowCursor(for event: NSEvent) {
        guard !isTextInputHit(atWindowLocation: event.locationInWindow) else { return }
        NSCursor.arrow.set()

        // WKWebView 会在同一轮 mouse-move 里根据 DOM/CSS cursor 再次 set cursor。
        // 延后一轮补设 arrow，确保视觉上位于浮层区域时最终由浮层决定光标。
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isTextInputUnderCurrentMouse() else { return }
            NSCursor.arrow.set()
        }
    }

    private func isTextInputUnderCurrentMouse() -> Bool {
        guard let window else { return false }
        return isTextInputHit(atWindowLocation: window.mouseLocationOutsideOfEventStream)
    }

    private func isTextInputHit(atWindowLocation location: NSPoint) -> Bool {
        guard let contentView = window?.contentView else { return false }
        let point = contentView.convert(location, from: nil)
        guard let hitView = contentView.hitTest(point), hitView !== self else { return false }
        return hitView.hasTextInputAncestor
    }
}

private extension NSView {
    /// 文本输入区域必须保留系统 I-beam 光标；否则全局搜索框和 AI 输入框会被误改成箭头。
    var hasTextInputAncestor: Bool {
        if self is NSTextView || self is NSTextField || self is NSSearchField {
            return true
        }
        return superview?.hasTextInputAncestor ?? false
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
