//
//  StarcatAIGeneratingHalo.swift
//  Starcat
//
//  AI 正在干活时的彩色流动光圈。
//
//  - `StarcatAIGeneratingHalo`：Issue 撰写框用的开花光晕（SwiftUI blur + 角向渐变）。
//  - `StarcatAIGeneratingHaloHost`：同一份 SwiftUI 光圈嵌进 NSView，给 README 的
//    WKWebView 用。直接 overlay SwiftUI 会被 WebView 盖住。
//  - `StarcatAIHaloLayerView`：Issue 多条评论卡的细描边，避免超高卡走 blur。
//
//  关键约束：CA 路径在 layout 改 bounds 时必须关掉隐式动画，否则滚动会把 mask 路径 tween 一遍。
//  禁止对圆锥渐变整层做 CIFilter：模糊未裁切的 conic 会在页面上拉出斜光条。
//

import AppKit
import SwiftUI

enum StarcatAIHaloMetrics {
    static let cornerRadius: CGFloat = 8
    static let glowBleed: CGFloat = 8
    static let fade: TimeInterval = 0.48
    static let reduceMotionFade: TimeInterval = 0.28
    static let rotationPeriod: TimeInterval = 3.2
    static let strokeWidth: CGFloat = 3

    static func fadeDuration(_ reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? reduceMotionFade : fade
    }
}

/// Issue 撰写框用的开花光圈。README 翻译通过 `StarcatAIGeneratingHaloHost` 复用这一份。
struct StarcatAIGeneratingHalo: View {
    var isActive: Bool

    @Environment(\.starcatReduceMotion) private var reduceMotion

    private let colors: [Color] = [
        .cyan.opacity(0.95),
        .purple.opacity(0.95),
        .pink.opacity(0.90),
        .orange.opacity(0.82),
        .cyan.opacity(0.95)
    ]

    var body: some View {
        ZStack {
            // 灭掉之后卸掉 TimelineView / blur 层，避免 opacity 0 还在合成。
            if isActive {
                haloContent
                    .transition(.opacity)
            }
        }
        .padding(StarcatAIHaloMetrics.glowBleed)
        .animation(
            .easeInOut(duration: StarcatAIHaloMetrics.fadeDuration(reduceMotion)),
            value: isActive
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var haloContent: some View {
        if reduceMotion {
            bloomRing(angle: 0)
        } else {
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 12.0,
                    paused: !isActive
                )
            ) { timeline in
                let turns = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: StarcatAIHaloMetrics.rotationPeriod)
                    / StarcatAIHaloMetrics.rotationPeriod
                bloomRing(angle: turns * 360)
            }
        }
    }

    private func bloomRing(angle: Double) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: StarcatAIHaloMetrics.cornerRadius,
            style: .continuous
        )
        let gradient = AngularGradient(
            colors: colors,
            center: .center,
            angle: .degrees(angle)
        )
        return ZStack {
            shape
                .stroke(gradient, lineWidth: 8)
                .blur(radius: 9)
                .opacity(0.62)
            shape
                .stroke(gradient, lineWidth: 4)
                .blur(radius: 4)
                .opacity(0.45)
            shape
                .strokeBorder(gradient, lineWidth: 1.6)
        }
        .shadow(color: .cyan.opacity(0.22), radius: 6)
        .shadow(color: .pink.opacity(0.16), radius: 8)
    }
}

struct StarcatAIGeneratingHaloRoot: View {
    var isActive: Bool
    var reduceMotion: Bool

    var body: some View {
        StarcatAIGeneratingHalo(isActive: isActive)
            .environment(\.starcatReduceMotion, reduceMotion)
    }
}

/// 把撰写框那份 SwiftUI 光圈嵌进透明 NSView，盖在 WKWebView 上面。
final class StarcatAIHaloHostingNSView: NSHostingView<StarcatAIGeneratingHaloRoot> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

struct StarcatAIGeneratingHaloHost: NSViewRepresentable {
    var isActive: Bool
    var reduceMotion: Bool

    func makeNSView(context: Context) -> StarcatAIHaloHostingNSView {
        let view = StarcatAIHaloHostingNSView(
            rootView: StarcatAIGeneratingHaloRoot(isActive: isActive, reduceMotion: reduceMotion)
        )
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: StarcatAIHaloHostingNSView, context: Context) {
        nsView.rootView = StarcatAIGeneratingHaloRoot(isActive: isActive, reduceMotion: reduceMotion)
    }
}

/// Issue 评论卡细描边。旋转走合成线程，不进 SwiftUI TimelineView。
///
/// 查：`docs/7-工具与脚本/Swift-学习索引.md` → `NSViewRepresentable`。
struct StarcatAIHaloLayerView: NSViewRepresentable {
    var isActive: Bool
    var reduceMotion: Bool

    func makeNSView(context: Context) -> StarcatAIHaloNSView {
        StarcatAIHaloNSView()
    }

    func updateNSView(_ nsView: StarcatAIHaloNSView, context: Context) {
        nsView.apply(isActive: isActive, reduceMotion: reduceMotion)
    }
}

/// 固定圆角描边 mask，只转渐变层。mask 不能挂在渐变上，否则圆角框会跟着转。
final class StarcatAIHaloNSView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()
    private var isActive = false
    private var reduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.isOpaque = false
        layer?.opacity = 0

        gradientLayer.type = .conic
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.colors = [
            NSColor.cyan.withAlphaComponent(0.95).cgColor,
            NSColor.purple.withAlphaComponent(0.95).cgColor,
            NSColor.systemPink.withAlphaComponent(0.90).cgColor,
            NSColor.systemOrange.withAlphaComponent(0.82).cgColor,
            NSColor.cyan.withAlphaComponent(0.95).cgColor
        ]

        maskLayer.fillColor = nil
        maskLayer.strokeColor = NSColor.white.cgColor
        maskLayer.lineWidth = StarcatAIHaloMetrics.strokeWidth
        maskLayer.lineJoin = .round
        maskLayer.lineCap = .round

        layer?.addSublayer(gradientLayer)
        layer?.mask = maskLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        gradientLayer.contentsScale = scale
        maskLayer.contentsScale = scale
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        maskLayer.frame = bounds
        let inset = StarcatAIHaloMetrics.glowBleed
            + StarcatAIHaloMetrics.strokeWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = StarcatAIHaloMetrics.cornerRadius
        maskLayer.path = CGPath(
            roundedRect: rect,
            cornerWidth: min(radius, max(rect.width / 2, 0)),
            cornerHeight: min(radius, max(rect.height / 2, 0)),
            transform: nil
        )
        CATransaction.commit()
        if isActive && !reduceMotion {
            startSpinIfNeeded()
        }
    }

    func apply(isActive: Bool, reduceMotion: Bool) {
        let fade = StarcatAIHaloMetrics.fadeDuration(reduceMotion)
        self.reduceMotion = reduceMotion
        self.isActive = isActive

        CATransaction.begin()
        CATransaction.setAnimationDuration(fade)
        layer?.opacity = isActive ? 1 : 0
        CATransaction.commit()

        if isActive && !reduceMotion {
            startSpinIfNeeded()
        } else {
            stopSpin()
        }
    }

    private func startSpinIfNeeded() {
        guard gradientLayer.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = Double.pi * 2
        spin.duration = StarcatAIHaloMetrics.rotationPeriod
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        gradientLayer.add(spin, forKey: "spin")
    }

    private func stopSpin() {
        gradientLayer.removeAnimation(forKey: "spin")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}
