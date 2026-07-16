//
//  RAGConversationSkeletonView.swift
//  Starcat
//
//  切换历史会话、缓存未命中时的中栏对话骨架占位。
//  与 README 详情骨架同一套 SkeletonAnimatedPhase + shimmer，形状对齐用户右气泡 / 助手左列。
//

import SwiftUI

/// 会话加载骨架：若干轮「用户气泡 + 助手正文」占位，占满中栏剩余高度。
struct RAGConversationSkeletonView: View {
    var turnCount: Int = 3

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // 与 ReadmeSkeletonView 同结构：外层单时钟，子块只消费 phase / phaseOffset。
        SkeletonAnimatedPhase { phase in
            let palette = SkeletonPalette.forColorScheme(colorScheme)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(0..<turnCount, id: \.self) { index in
                        let base = Double(index) * 0.18
                        turn(
                            phase: phase,
                            baseOffset: base,
                            palette: palette
                        )
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDisabled(true)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityLabel(Text("rag.workspace.conversation.loading"))
    }

    @ViewBuilder
    private func turn(
        phase: Double,
        baseOffset: Double,
        palette: SkeletonPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            // 用户消息：右对齐气泡 + 头像
            HStack(alignment: .center, spacing: 0) {
                Spacer(minLength: 80)
                HStack(alignment: .center, spacing: 8) {
                    SkeletonBlock(
                        width: 240,
                        height: 40,
                        cornerRadius: 8,
                        phase: phase,
                        phaseOffset: baseOffset,
                        palette: palette
                    )
                    SkeletonBlock(
                        width: RAGMessageAvatarMetrics.size,
                        height: RAGMessageAvatarMetrics.size,
                        cornerRadius: RAGMessageAvatarMetrics.cornerRadius,
                        phase: phase,
                        phaseOffset: baseOffset + 0.03,
                        palette: palette
                    )
                }
            }

            // 助手消息：左头像 + 多行正文（对齐 Readme 段落 shimmer）
            HStack(alignment: .top, spacing: 8) {
                SkeletonBlock(
                    width: RAGMessageAvatarMetrics.size,
                    height: RAGMessageAvatarMetrics.size,
                    cornerRadius: RAGMessageAvatarMetrics.cornerRadius,
                    phase: phase,
                    phaseOffset: baseOffset + 0.06,
                    palette: palette
                )
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(
                        width: 88,
                        height: 12,
                        cornerRadius: 4,
                        phase: phase,
                        phaseOffset: baseOffset + 0.08,
                        palette: palette
                    )
                    SkeletonBlock(
                        width: nil,
                        maxWidth: 520,
                        height: 12,
                        cornerRadius: 4,
                        phase: phase,
                        phaseOffset: baseOffset + 0.11,
                        palette: palette
                    )
                    SkeletonBlock(
                        width: nil,
                        maxWidth: 480,
                        height: 12,
                        cornerRadius: 4,
                        phase: phase,
                        phaseOffset: baseOffset + 0.14,
                        palette: palette
                    )
                    SkeletonBlock(
                        width: 220,
                        height: 12,
                        cornerRadius: 4,
                        phase: phase,
                        phaseOffset: baseOffset + 0.17,
                        palette: palette
                    )
                }
                Spacer(minLength: 0)
            }
        }
    }
}
