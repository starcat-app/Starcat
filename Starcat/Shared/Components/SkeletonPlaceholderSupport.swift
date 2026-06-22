//
//  SkeletonPlaceholderSupport.swift
//  Starcat
//
//  Repo 列表 / README 等加载占位共用的配色、shimmer 与 Timeline phase 驱动。
//  单时钟 + 子视图只消费 phase，避免加载期多个 display-link 抢帧（见 RepoRowSkeletonView 注释）。
//

import SwiftUI

// MARK: - Palette

/// 占位块 / shimmer 配色。不用 `quaternaryLabelColor`——在 window 背景上对比度不足。
struct SkeletonPalette {
    let base: Color
    let highlight: Color
    let shimmerBlendMode: BlendMode

    static func forColorScheme(_ scheme: ColorScheme) -> SkeletonPalette {
        switch scheme {
        case .dark:
            return SkeletonPalette(
                base: Color.white.opacity(0.16),
                highlight: Color.white.opacity(0.34),
                shimmerBlendMode: .plusLighter
            )
        case .light:
            return SkeletonPalette(
                base: Color(white: 0.85),
                highlight: Color.white.opacity(0.88),
                shimmerBlendMode: .overlay
            )
        @unknown default:
            return SkeletonPalette(
                base: Color.secondary.opacity(0.22),
                highlight: Color.white.opacity(0.40),
                shimmerBlendMode: .plusLighter
            )
        }
    }
}

// MARK: - Timeline phase

/// 骨架动画统一 phase 源：reduceMotion 时静态 0，否则 15 FPS TimelineView。
struct SkeletonAnimatedPhase<Content: View>: View {
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var period: TimeInterval = 1.4
    @ViewBuilder var content: (_ phase: Double) -> Content

    var body: some View {
        if reduceMotion {
            content(0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                content(phase)
            }
        }
    }
}

// MARK: - Shimmer

extension View {
    /// 骨架占位上的移动高光带；phase 由父层 `SkeletonAnimatedPhase` 下发。
    func skeletonShimmer(phase: Double, palette: SkeletonPalette) -> some View {
        modifier(SkeletonShimmerModifier(phase: phase, palette: palette))
    }
}

private struct SkeletonShimmerModifier: ViewModifier {
    let phase: Double
    let palette: SkeletonPalette

    func body(content: Content) -> some View {
        content.overlay {
            let center = phase * 1.6 - 0.3
            let leftLoc = min(max(center - 0.25, 0), 1)
            let midLoc = min(max(center, 0), 1)
            let rightLoc = min(max(center + 0.25, 0), 1)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: leftLoc),
                    .init(color: palette.highlight, location: midLoc),
                    .init(color: .clear, location: rightLoc)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .blendMode(palette.shimmerBlendMode)
            .allowsHitTesting(false)
        }
        .mask(content)
    }
}

// MARK: - Block helper

/// 单条骨架占位（圆角矩形 + shimmer）。
struct SkeletonBlock: View {
    let width: CGFloat?
    let maxWidth: CGFloat?
    let height: CGFloat
    let cornerRadius: CGFloat
    let phase: Double
    let phaseOffset: Double
    let palette: SkeletonPalette

    init(
        width: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        height: CGFloat,
        cornerRadius: CGFloat = 4,
        phase: Double,
        phaseOffset: Double = 0,
        palette: SkeletonPalette
    ) {
        self.width = width
        self.maxWidth = maxWidth
        self.height = height
        self.cornerRadius = cornerRadius
        self.phase = phase
        self.phaseOffset = phaseOffset
        self.palette = palette
    }

    private var effectivePhase: Double {
        (phase + phaseOffset).truncatingRemainder(dividingBy: 1)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(palette.base)
            .frame(width: width, height: height)
            .frame(maxWidth: maxWidth ?? (width == nil ? .infinity : nil), alignment: .leading)
            .skeletonShimmer(phase: effectivePhase, palette: palette)
    }
}
