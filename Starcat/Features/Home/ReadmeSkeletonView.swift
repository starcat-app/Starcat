//
//  ReadmeSkeletonView.swift
//  Starcat
//
//  README 详情加载占位：模拟 Markdown 文档结构（标题 / 段落 / 代码块），
//  与 Manage 列表共用 `SkeletonPalette` + shimmer，替代 ProgressView 转圈。
//
//  宽度约束（2026-07-18）：
//  - 真实 README WebView 用 `max-width: 100%`，随详情栏拖宽铺满；
//  - 骨架曾硬编码 `maxWidth: 760`，窗口拉宽后右侧大片留白。
//  - 外层只保留 `maxWidth: .infinity`；短行用 trailing padding 模拟段落收尾，
//    避免再写绝对 pt 上限导致宽栏再次露白。
//

import SwiftUI

/// README WebView 加载中的文档型骨架屏。
struct ReadmeSkeletonView: View {

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SkeletonAnimatedPhase { phase in
            let palette = SkeletonPalette.forColorScheme(colorScheme)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    SkeletonBlock(
                        width: 280,
                        height: 28,
                        cornerRadius: 6,
                        phase: phase,
                        phaseOffset: 0,
                        palette: palette
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        paragraphLine(phase: phase, offset: 0.04, palette: palette)
                        paragraphLine(phase: phase, offset: 0.08, palette: palette)
                        paragraphLine(trailingInset: 96, phase: phase, offset: 0.12, palette: palette)
                    }

                    SkeletonBlock(
                        width: 200,
                        height: 18,
                        cornerRadius: 5,
                        phase: phase,
                        phaseOffset: 0.16,
                        palette: palette
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        paragraphLine(phase: phase, offset: 0.20, palette: palette)
                        paragraphLine(phase: phase, offset: 0.24, palette: palette)
                        paragraphLine(trailingInset: 120, phase: phase, offset: 0.28, palette: palette)
                        paragraphLine(phase: phase, offset: 0.32, palette: palette)
                    }

                    SkeletonBlock(
                        width: nil,
                        maxWidth: .infinity,
                        height: 128,
                        cornerRadius: 8,
                        phase: phase,
                        phaseOffset: 0.36,
                        palette: palette
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        paragraphLine(phase: phase, offset: 0.40, palette: palette)
                        paragraphLine(trailingInset: 160, phase: phase, offset: 0.44, palette: palette)
                        paragraphLine(phase: phase, offset: 0.48, palette: palette)
                    }

                    SkeletonBlock(
                        width: 168,
                        height: 18,
                        cornerRadius: 5,
                        phase: phase,
                        phaseOffset: 0.52,
                        palette: palette
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        paragraphLine(phase: phase, offset: 0.56, palette: palette)
                        paragraphLine(trailingInset: 112, phase: phase, offset: 0.60, palette: palette)
                    }
                }
                // 与 ReadmeCSS `.markdown-body` 的左右 / 顶边距对齐（16 / 24），
                // 避免 loading → loaded 切换时正文左右跳一下。
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDisabled(true)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 段落行：默认铺满可用宽度；`trailingInset` 模拟自然收尾行，随容器变宽仍保持比例感。
    @ViewBuilder
    private func paragraphLine(
        trailingInset: CGFloat = 0,
        phase: Double,
        offset: Double,
        palette: SkeletonPalette
    ) -> some View {
        SkeletonBlock(
            width: nil,
            maxWidth: .infinity,
            height: 12,
            phase: phase,
            phaseOffset: offset,
            palette: palette
        )
        .padding(.trailing, trailingInset)
    }
}
