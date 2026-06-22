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
//  当前做法（2026-06-15 性能重构）：
//  1. 整张骨架列表只保留一个 `TimelineView`，当前 phase 作为普通值下发到每行。
//     旧实现在每行的每个占位块上都建一个 30 FPS display-link，8 行会同时
//     运行几十个时钟，这是加载期列表与窗口明显卡顿的根因。
//  2. 脉冲透明度和 shimmer 共用同一 phase，不再另建 repeatForever 事务。
//  3. 给每行加 stagger phase offset，让 shimmer 形成"波浪传递"，比齐刷刷亮灭更接近真实
//     加载反馈。
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
    @Environment(\.colorScheme) private var colorScheme

    init(rowCount: Int = 8) {
        self.rowCount = rowCount
    }

    var body: some View {
        SkeletonAnimatedPhase { phase in
            skeletonRows(phase: phase)
        }
        .scrollDisabled(true)
    }

    private func skeletonRows(phase: Double) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(0..<rowCount, id: \.self) { index in
                    // 每行相位错开 0.08 周期，10 行刚好分布在 0.8 个周期内，视觉上呈现传递感。
                    let offset = Double(index) * 0.08
                    RepoRowSkeletonView(phaseOffset: offset, phase: phase)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)

                    Divider()
                        .opacity(colorScheme == .dark ? 0.28 : 0.45)
                }
            }
        }
    }
}
