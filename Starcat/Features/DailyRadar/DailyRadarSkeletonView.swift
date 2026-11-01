//
//  DailyRadarSkeletonView.swift
//  Starcat
//
//  每日热点首页加载骨架：布局镜像「本期精选大卡 + 往期卡片网格」，
//  配色与 shimmer 动画复用中栏 Repo 卡片骨架的共享组件
//  （SkeletonPalette / SkeletonBlock / SkeletonAnimatedPhase，见
//  SkeletonPlaceholderSupport.swift），保证全 App 骨架观感一致。
//
//  关键约束：
//  - 只在 `isLoading && items.isEmpty` 首屏加载时出现；刷新已有内容不闪骨架。
//  - reduceMotion 时 phase 恒 0（由 SkeletonAnimatedPhase 处理），只剩静态占位。
//  - 纯展示：accessibilityHidden + 不接收点击，不进入辅助功能树。
//

import SwiftUI

struct DailyRadarSkeletonView: View {
    /// 与真实内容网格同源的可用宽度（≥780 双列，窄窗口单列）。
    let width: CGFloat

    @Environment(\.starcatInterfaceScale) private var scale

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: width >= 780 ? 2 : 1)
    }

    var body: some View {
        SkeletonAnimatedPhase { phase in
            VStack(alignment: .leading, spacing: 20) {
                featuredCard(phase)

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(0..<4, id: \.self) { index in
                        storyCard(phase: phase, phaseOffset: Double(index + 1) * 0.08)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .top)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// 本期精选大卡：大图块 + 两行标题 + 一行摘要，高度跟随界面缩放。
    private func featuredCard(_ phase: Double) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SkeletonBlock(height: scale.scaled(320), cornerRadius: 16, phase: phase, palette: palette)
            SkeletonBlock(width: 220, height: 16, cornerRadius: 4, phase: phase, phaseOffset: 0.08, palette: palette)
            SkeletonBlock(height: 12, cornerRadius: 4, phase: phase, phaseOffset: 0.08, palette: palette)
            SkeletonBlock(width: 260, height: 12, cornerRadius: 4, phase: phase, phaseOffset: 0.16, palette: palette)
        }
    }

    /// 往期网格卡：图片块 + 两行标题 + 一行摘要，逐卡错峰形成波浪 shimmer。
    private func storyCard(phase: Double, phaseOffset: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SkeletonBlock(height: 160, cornerRadius: 16, phase: phase, phaseOffset: phaseOffset, palette: palette)
            SkeletonBlock(height: 14, cornerRadius: 4, phase: phase, phaseOffset: phaseOffset, palette: palette)
            SkeletonBlock(height: 14, cornerRadius: 4, phase: phase, phaseOffset: phaseOffset, palette: palette)
                .frame(maxWidth: 200, alignment: .leading)
            SkeletonBlock(height: 12, cornerRadius: 4, phase: phase, phaseOffset: phaseOffset, palette: palette)
                .frame(maxWidth: 150, alignment: .leading)
        }
    }

    private var palette: SkeletonPalette {
        SkeletonPalette.forColorScheme(colorScheme)
    }

    @Environment(\.colorScheme) private var colorScheme
}
