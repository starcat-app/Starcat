//
//  RAGConversationSkeletonView.swift
//  Starcat
//
//  切换历史会话、缓存未命中时的中栏对话骨架占位。
//  使用 Core Animation 驱动 shimmer，形状对齐用户右气泡 / 助手左列。
//  正文首次布局占用主线程时，动画仍由 Render Server 连续播放，不会先停住再恢复。
//
//  宽度约束（2026-07-18）：助手正文行不再用 520/480 绝对上限，改为铺满中栏 +
//  trailing inset 模拟收尾行，避免宽工作台右侧留白（同 ReadmeSkeletonView）。
//

import AppKit
import SwiftUI

/// 会话加载骨架：若干轮「用户气泡 + 助手正文」占位，占满中栏剩余高度。
struct RAGConversationSkeletonView: View {
    var turnCount: Int = 3

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        let palette = RAGCompositorSkeletonPalette.forColorScheme(colorScheme)
        ScrollView(.vertical, showsIndicators: false) {
            skeletonLayer(fill: Color(nsColor: palette.base))
                .overlay {
                    // 整个会话骨架共用一个 CA 动画层，避免为每个占位块创建独立 NSView。
                    RAGCompositorShimmerView(
                        highlightColor: palette.highlight,
                        reduceMotion: reduceMotion
                    )
                    .mask {
                        skeletonLayer(fill: .white)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
        }
        .scrollDisabled(true)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel(Text("rag.workspace.conversation.loading"))
    }

    private func skeletonLayer(fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(0..<turnCount, id: \.self) { _ in
                turn(fill: fill)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func turn(fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // 用户消息：右对齐气泡 + 头像
            HStack(alignment: .center, spacing: 0) {
                Spacer(minLength: 80)
                HStack(alignment: .center, spacing: 8) {
                    RAGSkeletonShapeBlock(
                        width: 240,
                        height: 40,
                        cornerRadius: 8,
                        fill: fill
                    )
                    RAGSkeletonShapeBlock(
                        width: RAGMessageAvatarMetrics.size,
                        height: RAGMessageAvatarMetrics.size,
                        cornerRadius: RAGMessageAvatarMetrics.cornerRadius,
                        fill: fill
                    )
                }
            }

            // 助手消息：左头像 + 多行正文。
            // 正文行用 infinity + trailing inset，避免硬编码 520/480 在宽中栏留下右侧空白
            // （与 ReadmeSkeletonView 同款约束：外层跟栏宽，短行用 inset 模拟收尾）。
            HStack(alignment: .top, spacing: 8) {
                RAGSkeletonShapeBlock(
                    width: RAGMessageAvatarMetrics.size,
                    height: RAGMessageAvatarMetrics.size,
                    cornerRadius: RAGMessageAvatarMetrics.cornerRadius,
                    fill: fill
                )
                VStack(alignment: .leading, spacing: 10) {
                    RAGSkeletonShapeBlock(
                        width: 88,
                        height: 12,
                        cornerRadius: 4,
                        fill: fill
                    )
                    RAGSkeletonShapeBlock(
                        width: nil,
                        maxWidth: .infinity,
                        height: 12,
                        cornerRadius: 4,
                        fill: fill
                    )
                    RAGSkeletonShapeBlock(
                        width: nil,
                        maxWidth: .infinity,
                        height: 12,
                        cornerRadius: 4,
                        fill: fill
                    )
                    .padding(.trailing, 40)
                    RAGSkeletonShapeBlock(
                        width: nil,
                        maxWidth: .infinity,
                        height: 12,
                        cornerRadius: 4,
                        fill: fill
                    )
                    .padding(.trailing, 120)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// RAG 会话骨架专用配色。这里使用 NSColor，是因为动画在 Core Animation 层完成，
/// 不再让 SwiftUI 每帧重算渐变；数值保持与共享 SkeletonPalette 一致。
private struct RAGCompositorSkeletonPalette {
    let base: NSColor
    let highlight: NSColor

    static func forColorScheme(_ scheme: ColorScheme) -> Self {
        switch scheme {
        case .dark:
            return Self(
                base: NSColor.white.withAlphaComponent(0.09),
                highlight: NSColor.white.withAlphaComponent(0.20)
            )
        case .light:
            return Self(
                base: NSColor(calibratedWhite: 0.91, alpha: 1),
                highlight: NSColor.white.withAlphaComponent(0.94)
            )
        @unknown default:
            return Self(
                base: NSColor.secondaryLabelColor.withAlphaComponent(0.22),
                highlight: NSColor.white.withAlphaComponent(0.40)
            )
        }
    }
}

/// SwiftUI 只绘制静态形状并负责尺寸；同一份布局也作为全局 shimmer 的 alpha mask。
private struct RAGSkeletonShapeBlock: View {
    let width: CGFloat?
    let maxWidth: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat
    let fill: Color

    init(
        width: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        height: CGFloat,
        cornerRadius: CGFloat = 4,
        fill: Color
    ) {
        self.width = width
        self.maxWidth = maxWidth
        self.height = height
        self.cornerRadius = cornerRadius
        self.fill = fill
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .frame(width: width, height: height)
            .frame(maxWidth: maxWidth ?? (width == nil ? .infinity : nil), alignment: .leading)
    }
}

/// `NSViewRepresentable` 是刻意收窄的边界：SwiftUI 仍持有全部状态，NSView 不回写业务数据。
private struct RAGCompositorShimmerView: NSViewRepresentable {
    let highlightColor: NSColor
    let reduceMotion: Bool

    func makeNSView(context: Context) -> RAGCompositorShimmerNSView {
        let view = RAGCompositorShimmerNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: RAGCompositorShimmerNSView, context: Context) {
        nsView.update(
            highlightColor: highlightColor,
            reduceMotion: reduceMotion
        )
    }
}

/// 高光带由 `CABasicAnimation` 提交给 Render Server。主线程短暂忙于 Markdown 首帧布局时，
/// 已提交的动画仍能继续播放；不要在这里放任何业务状态或 SwiftUI 生命周期判断。
private final class RAGCompositorShimmerNSView: NSView {
    private static let animationKey = "starcat.rag.skeleton.shimmer"
    private static let animationPeriod: CFTimeInterval = 1.4

    private let backingLayer = CALayer()
    private let gradientLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = backingLayer
        backingLayer.masksToBounds = true
        backingLayer.addSublayer(gradientLayer)
        gradientLayer.locations = [0, 0.5, 1]
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        CATransaction.commit()
    }

    func update(
        highlightColor: NSColor,
        reduceMotion: Bool
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = [NSColor.clear.cgColor, highlightColor.cgColor, NSColor.clear.cgColor]
        gradientLayer.isHidden = reduceMotion
        CATransaction.commit()

        if reduceMotion {
            gradientLayer.removeAnimation(forKey: Self.animationKey)
        } else if gradientLayer.animation(forKey: Self.animationKey) == nil {
            installShimmerAnimation()
        }
        needsLayout = true
    }

    private func installShimmerAnimation() {
        let startPoint = CABasicAnimation(keyPath: "startPoint")
        startPoint.fromValue = CGPoint(x: -1.0, y: 0.5)
        startPoint.toValue = CGPoint(x: 1.0, y: 0.5)
        startPoint.duration = Self.animationPeriod

        let endPoint = CABasicAnimation(keyPath: "endPoint")
        endPoint.fromValue = CGPoint(x: -0.2, y: 0.5)
        endPoint.toValue = CGPoint(x: 1.8, y: 0.5)
        endPoint.duration = Self.animationPeriod

        let animation = CAAnimationGroup()
        animation.animations = [startPoint, endPoint]
        animation.duration = Self.animationPeriod
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        gradientLayer.add(animation, forKey: Self.animationKey)
    }
}
