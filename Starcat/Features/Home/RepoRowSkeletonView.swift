//
//  RepoRowSkeletonView.swift
//  Starcat
//
//  骨架屏行视图，RepoListView 加载中时替代真实行显示。
//
//  设计约束：
//  - 骨架行尺寸严格匹配 RepoRowView 的 card 密度
//  - shimmer 动画必须穿越父层 `.transition` / `.animation(_:value:)` 不被吞掉
//  - 不持有任何业务数据，纯展示型组件
//
//  R-01 §3.1.1（2026-06-10 P1）：`RepoListDensity` 枚举已彻底删除（之前为
//  保签名稳定保留单 case 是「自留技术债」）；本组件不再有 density 入参。
//
//  ⚠️ 实现踩坑（2026-06-02 修复）
//  ------------------------------------------------------------------
//  旧实现用 `onAppear { withAnimation(.repeatForever) { isAnimating = true } }`。
//  在 RepoListView 中骨架屏是通过 `.id(contentAnimationID)` 重建并以 `.transition`
//  插入的，父层同时挂着 `.animation(easeOut(0.22), value: contentAnimationID)`。
//  `withAnimation` 是"瞬时调度型"——它把动画绑到当前帧的 state 变化上；当父层 transition
//  动画正在跑时，`repeatForever` 这条 implicit 动画上下文会被吞掉，结果只跑半个 cycle
//  就停在 opacity 0.6，UI 看起来像"定格"。
//
//  当前做法（2026-07-18 性能重构）：
//  1. 整张骨架列表只保留一个 `TimelineView`。
//  2. 列表内全部占位块由单个 `Canvas` 绘制；不能把 phase 继续下发给几十个 SwiftUI
//     Shape。后者每帧都会让整棵占位树重新求值，并触发 AppKit layout / display-list
//     提交，数据已经在后台加载时反而由骨架动画自己占住主线程。
//  3. 脉冲透明度和 shimmer 共用同一 phase，并保留逐行 stagger，视觉契约不变。
//

import SwiftUI

/// 骨架屏行视图入口：渲染 card 密度骨架（紧凑骨架已在 R-01 删除）。
///
/// - Parameters:
///   - phaseOffset: 0...1 的相位偏移；同一时刻不同行用不同 offset，shimmer 会形成波浪效果
struct RepoRowSkeletonView: View {
    let phaseOffset: Double
    let phase: Double

    init(phaseOffset: Double = 0, phase: Double = 0) {
        self.phaseOffset = phaseOffset
        self.phase = phase
    }

    var body: some View {
        RepoRowSkeletonCard(phaseOffset: phaseOffset, phase: phase)
    }
}

// MARK: - Card 骨架行

private struct RepoRowSkeletonCard: View {
    let phaseOffset: Double
    let phase: Double

    @Environment(\.colorScheme) private var colorScheme

    private var palette: SkeletonPalette {
        SkeletonPalette.forColorScheme(colorScheme)
    }

    private var effectivePhase: Double {
        (phase + phaseOffset).truncatingRemainder(dividingBy: 1)
    }

    /// 轻微呼吸，幅度收窄——旧版 0.925±0.075 叠低对比底色后几乎「隐形」。
    private var pulseOpacity: Double {
        0.97 + sin(effectivePhase * .pi * 2) * 0.03
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 20)
                .fill(palette.base)
                .frame(width: 40, height: 40)
                .skeletonShimmer(phase: effectivePhase, palette: palette)

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.base)
                    .frame(width: 160, height: 14)
                    .skeletonShimmer(phase: effectivePhase, palette: palette)

                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.base)
                    .frame(height: 12)
                    .skeletonShimmer(phase: effectivePhase, palette: palette)

                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.base)
                    .frame(width: 200, height: 12)
                    .skeletonShimmer(phase: effectivePhase, palette: palette)

                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(palette.base)
                        .frame(width: 50, height: 12)
                        .skeletonShimmer(phase: effectivePhase, palette: palette)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(palette.base)
                        .frame(width: 40, height: 12)
                        .skeletonShimmer(phase: effectivePhase, palette: palette)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(palette.base)
                        .frame(width: 60, height: 12)
                        .skeletonShimmer(phase: effectivePhase, palette: palette)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .opacity(pulseOpacity)
    }
}

// MARK: - 骨架列表视图

/// 骨架屏列表入口，供 RepoListView 在加载中时渲染。
/// 渲染 N 行（默认 8 行）。
///
/// 行间 `phaseOffset` 按 index 错峰，shimmer 会形成"波浪传递"，避免所有行齐刷刷亮灭。
struct RepoSkeletonListView: View {
    let rowCount: Int

    init(rowCount: Int = 8) {
        self.rowCount = rowCount
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            SkeletonAnimatedPhase { phase in
                RepoSkeletonCanvas(rowCount: rowCount, phase: phase)
                    .frame(maxWidth: .infinity)
                    .frame(height: RepoSkeletonCanvas.contentHeight(for: rowCount))
            }
        }
        .scrollDisabled(true)
    }
}

/// Repo 列表骨架的单画布实现。
///
/// `Canvas` 每个 tick 只重绘像素，不改变 view 层级与约束；这是保证骨架持续动、但不把
/// `NSWindow` 其它组件一起拖进 layout transaction 的关键边界。尺寸与原
/// `RepoRowSkeletonCard + padding + Divider` 保持一致，加载完成后切到真实 List 不跳高。
private struct RepoSkeletonCanvas: View {
    private static let rowHeight: CGFloat = 93
    private static let horizontalPadding: CGFloat = 12
    private static let contentTop: CGFloat = 12
    private static let iconSize: CGFloat = 40
    private static let textLeading: CGFloat = 64
    private static let shimmerWidth: CGFloat = 100

    let rowCount: Int
    let phase: Double

    @Environment(\.colorScheme) private var colorScheme

    static func contentHeight(for rowCount: Int) -> CGFloat {
        CGFloat(max(0, rowCount)) * rowHeight
    }

    var body: some View {
        let palette = SkeletonPalette.forColorScheme(colorScheme)

        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            guard rowCount > 0, size.width > 0 else { return }

            for index in 0..<rowCount {
                let rowOriginY = CGFloat(index) * Self.rowHeight
                let effectivePhase = (phase + Double(index) * 0.08)
                    .truncatingRemainder(dividingBy: 1)
                let pulseOpacity = 0.97 + sin(effectivePhase * .pi * 2) * 0.03

                var rowContext = context
                rowContext.opacity = pulseOpacity
                drawRow(
                    in: &rowContext,
                    size: size,
                    rowOriginY: rowOriginY,
                    phase: effectivePhase,
                    palette: palette
                )

                var dividerContext = context
                dividerContext.opacity = colorScheme == .dark ? 0.28 : 0.45
                let divider = Path(CGRect(
                    x: 0,
                    y: rowOriginY + Self.rowHeight - 1,
                    width: size.width,
                    height: 1
                ))
                dividerContext.fill(divider, with: .color(.secondary))
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func drawRow(
        in context: inout GraphicsContext,
        size: CGSize,
        rowOriginY: CGFloat,
        phase: Double,
        palette: SkeletonPalette
    ) {
        let y = rowOriginY + Self.contentTop
        let availableTextWidth = max(80, size.width - Self.textLeading - Self.horizontalPadding)

        drawPlaceholder(
            CGRect(x: Self.horizontalPadding, y: y, width: Self.iconSize, height: Self.iconSize),
            cornerRadius: 20,
            phase: phase,
            palette: palette,
            in: &context
        )
        drawPlaceholder(
            CGRect(x: Self.textLeading, y: y, width: min(160, availableTextWidth), height: 14),
            cornerRadius: 4,
            phase: phase,
            palette: palette,
            in: &context
        )
        drawPlaceholder(
            CGRect(x: Self.textLeading, y: y + 20, width: availableTextWidth, height: 12),
            cornerRadius: 4,
            phase: phase,
            palette: palette,
            in: &context
        )
        drawPlaceholder(
            CGRect(x: Self.textLeading, y: y + 38, width: min(200, availableTextWidth), height: 12),
            cornerRadius: 4,
            phase: phase,
            palette: palette,
            in: &context
        )

        var statX = Self.textLeading
        for statWidth in [CGFloat(50), 40, 60] {
            guard statX < size.width - Self.horizontalPadding else { break }
            let width = min(statWidth, size.width - Self.horizontalPadding - statX)
            drawPlaceholder(
                CGRect(x: statX, y: y + 56, width: width, height: 12),
                cornerRadius: 4,
                phase: phase,
                palette: palette,
                in: &context
            )
            statX += statWidth + 8
        }
    }

    private func drawPlaceholder(
        _ rect: CGRect,
        cornerRadius: CGFloat,
        phase: Double,
        palette: SkeletonPalette,
        in context: inout GraphicsContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
        context.fill(path, with: .color(palette.base))

        // 高光带只改变 Canvas shading，不改变任何 frame / mask / layout 约束。
        let centerX = rect.minX + (rect.width + Self.shimmerWidth) * phase
            - Self.shimmerWidth / 2
        let start = CGPoint(x: centerX - Self.shimmerWidth / 2, y: rect.midY)
        let end = CGPoint(x: centerX + Self.shimmerWidth / 2, y: rect.midY)
        let gradient = Gradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: palette.highlight, location: 0.5),
            .init(color: .clear, location: 1),
        ])
        context.fill(path, with: .linearGradient(gradient, startPoint: start, endPoint: end))
    }
}
