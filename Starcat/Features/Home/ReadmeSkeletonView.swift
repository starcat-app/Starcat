//
//  ReadmeSkeletonView.swift
//  Starcat
//
//  README 详情加载占位：模拟 Markdown 文档结构（标题 / 段落 / 代码块），
//  与 Manage 列表共用 `SkeletonPalette` + shimmer，替代 ProgressView 转圈。
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
                        paragraphLine(width: nil, phase: phase, offset: 0.04, palette: palette)
                        paragraphLine(width: nil, phase: phase, offset: 0.08, palette: palette)
                        paragraphLine(maxWidth: 520, phase: phase, offset: 0.12, palette: palette)
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
                        paragraphLine(width: nil, phase: phase, offset: 0.20, palette: palette)
                        paragraphLine(width: nil, phase: phase, offset: 0.24, palette: palette)
                        paragraphLine(maxWidth: 480, phase: phase, offset: 0.28, palette: palette)
                        paragraphLine(width: nil, phase: phase, offset: 0.32, palette: palette)
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
                        paragraphLine(width: nil, phase: phase, offset: 0.40, palette: palette)
                        paragraphLine(maxWidth: 440, phase: phase, offset: 0.44, palette: palette)
                        paragraphLine(width: nil, phase: phase, offset: 0.48, palette: palette)
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
                        paragraphLine(width: nil, phase: phase, offset: 0.56, palette: palette)
                        paragraphLine(maxWidth: 500, phase: phase, offset: 0.60, palette: palette)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDisabled(true)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func paragraphLine(
        width: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        phase: Double,
        offset: Double,
        palette: SkeletonPalette
    ) -> some View {
        SkeletonBlock(
            width: width,
            maxWidth: maxWidth,
            height: 12,
            phase: phase,
            phaseOffset: offset,
            palette: palette
        )
    }
}
