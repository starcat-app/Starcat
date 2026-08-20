//
//  StarcatAIGeneratingHalo.swift
//  Starcat
//
//  AI 正在干活时的彩色流动光圈。
//
//  - `StarcatAIGeneratingHalo`：Issue 撰写框用的开花光晕（SwiftUI blur + 角向渐变）。
//  - `StarcatAIBloomHaloLayerView`：README 与通知评论卡共用的 Core Animation 连续光圈，
//    避开 SwiftUI TimelineView / blur 持续占用主线程，同时保持在 WKWebView 上层。
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

    static func fadeDuration(_ reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? reduceMotionFade : fade
    }
}

/// Issue 撰写框用的开花光圈。README 的全尺寸区域走更轻的 Core Animation 实现。
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

/// README 与通知评论卡共用的连续光圈。NSView 保证它能盖住 WKWebView，动画由
/// Core Animation render server 执行，不再用 TimelineView 周期性重建 SwiftUI 视图树。
///
/// 查：`docs/7-工具与脚本/Swift-学习索引.md` → `NSViewRepresentable`、`Core Animation`。
struct StarcatAIBloomHaloLayerView: NSViewRepresentable {
    var isActive: Bool
    var reduceMotion: Bool

    func makeNSView(context: Context) -> StarcatAIBloomHaloNSView {
        let view = StarcatAIBloomHaloNSView()
        view.apply(isActive: isActive, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: StarcatAIBloomHaloNSView, context: Context) {
        nsView.apply(isActive: isActive, reduceMotion: reduceMotion)
    }
}

/// 连续光圈只让一层圆锥渐变旋转；两层柔光保持静态，避免大尺寸 blur 每帧重算。
/// 渐变层使用覆盖 bounds 对角线的正方形，旋转到任意角度都不会露出空白边。
final class StarcatAIBloomHaloNSView: NSView {
    private let gradientClipLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let gradientMaskLayer = CAShapeLayer()
    private let cyanGlowLayer = CAShapeLayer()
    private let pinkGlowLayer = CAShapeLayer()

    private var isActive = false
    private var reduceMotion = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.isOpaque = false
        layer?.opacity = 0

        configureGlowLayer(
            cyanGlowLayer,
            color: NSColor.cyan,
            lineWidth: 4,
            strokeAlpha: 0.28,
            shadowRadius: 8,
            shadowOpacity: 0.34
        )
        configureGlowLayer(
            pinkGlowLayer,
            color: NSColor.systemPink,
            lineWidth: 2.5,
            strokeAlpha: 0.20,
            shadowRadius: 6,
            shadowOpacity: 0.24
        )

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

        gradientMaskLayer.fillColor = nil
        gradientMaskLayer.strokeColor = NSColor.white.cgColor
        gradientMaskLayer.lineWidth = 1.8
        gradientMaskLayer.lineJoin = .round
        gradientMaskLayer.lineCap = .round

        gradientClipLayer.masksToBounds = false
        gradientClipLayer.mask = gradientMaskLayer
        gradientClipLayer.addSublayer(gradientLayer)

        layer?.addSublayer(cyanGlowLayer)
        layer?.addSublayer(pinkGlowLayer)
        layer?.addSublayer(gradientClipLayer)
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
        [
            layer,
            gradientClipLayer,
            gradientLayer,
            gradientMaskLayer,
            cyanGlowLayer,
            pinkGlowLayer
        ].forEach { $0?.contentsScale = scale }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        cyanGlowLayer.frame = bounds
        pinkGlowLayer.frame = bounds
        gradientClipLayer.frame = bounds
        gradientMaskLayer.frame = gradientClipLayer.bounds

        // 父视图已经预留 glowBleed；路径落在 gutter 内沿，让 shadow 只覆盖边框附近。
        let ringRect = gradientClipLayer.bounds.insetBy(
            dx: StarcatAIHaloMetrics.glowBleed,
            dy: StarcatAIHaloMetrics.glowBleed
        )
        let radius = StarcatAIHaloMetrics.cornerRadius
        let path = CGPath(
            roundedRect: ringRect,
            cornerWidth: min(radius, max(ringRect.width / 2, 0)),
            cornerHeight: min(radius, max(ringRect.height / 2, 0)),
            transform: nil
        )
        cyanGlowLayer.path = path
        pinkGlowLayer.path = path
        gradientMaskLayer.path = path
        // 明确 shadowPath 后，CA 不需要根据全尺寸图层的 alpha 每帧推导阴影轮廓。
        cyanGlowLayer.shadowPath = path.copy(
            strokingWithWidth: cyanGlowLayer.lineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 0
        )
        pinkGlowLayer.shadowPath = path.copy(
            strokingWithWidth: pinkGlowLayer.lineWidth,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 0
        )

        let diagonal = ceil(hypot(bounds.width, bounds.height))
        gradientLayer.bounds = CGRect(x: 0, y: 0, width: diagonal, height: diagonal)
        gradientLayer.position = CGPoint(
            x: gradientClipLayer.bounds.midX,
            y: gradientClipLayer.bounds.midY
        )

        CATransaction.commit()

        if isActive && !reduceMotion {
            startSpinIfNeeded()
        }
    }

    func apply(isActive: Bool, reduceMotion: Bool) {
        guard self.isActive != isActive || self.reduceMotion != reduceMotion else { return }
        self.isActive = isActive
        self.reduceMotion = reduceMotion

        CATransaction.begin()
        CATransaction.setAnimationDuration(StarcatAIHaloMetrics.fadeDuration(reduceMotion))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer?.opacity = isActive ? 1 : 0
        CATransaction.commit()

        if isActive && !reduceMotion {
            startSpinIfNeeded()
        } else {
            stopSpin()
        }
    }

    private func configureGlowLayer(
        _ glowLayer: CAShapeLayer,
        color: NSColor,
        lineWidth: CGFloat,
        strokeAlpha: CGFloat,
        shadowRadius: CGFloat,
        shadowOpacity: Float
    ) {
        glowLayer.fillColor = nil
        glowLayer.strokeColor = color.withAlphaComponent(strokeAlpha).cgColor
        glowLayer.lineWidth = lineWidth
        glowLayer.lineJoin = .round
        glowLayer.lineCap = .round
        glowLayer.shadowColor = color.cgColor
        glowLayer.shadowOffset = .zero
        glowLayer.shadowRadius = shadowRadius
        glowLayer.shadowOpacity = shadowOpacity
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
