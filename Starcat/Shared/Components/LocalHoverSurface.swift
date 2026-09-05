//
//  LocalHoverSurface.swift
//  Starcat
//
//  将只影响单行外观的 hover 状态收口到行级 View，避免大型父视图因光标移动反复求值。
//

import SwiftUI

/// 为列表行和折叠标题提供局部 hover 表面。
///
/// `content` 在父视图求值时构造一次，光标进出只会刷新当前表面的背景与描边。
/// 这对 RAG、Agent 等长列表很重要：hover 不应成为刷新整棵工作台视图树的全局状态。
struct LocalHoverSurface<Content: View>: View {
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private let normalBackground: Color
    private let hoveredBackground: Color
    private let normalBorder: Color
    private let hoveredBorder: Color
    private let cornerRadius: CGFloat
    private let content: Content

    init(
        normalBackground: Color = .clear,
        hoveredBackground: Color = Color.accentColor.opacity(0.08),
        normalBorder: Color = .clear,
        hoveredBorder: Color = .clear,
        cornerRadius: CGFloat = 8,
        @ViewBuilder content: () -> Content
    ) {
        self.normalBackground = normalBackground
        self.hoveredBackground = hoveredBackground
        self.normalBorder = normalBorder
        self.hoveredBorder = hoveredBorder
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .background(
                isHovered ? hoveredBackground : normalBackground,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isHovered ? hoveredBorder : normalBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovering in
                if reduceMotion {
                    isHovered = hovering
                } else {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHovered = hovering
                    }
                }
            }
            .onDisappear {
                isHovered = false
            }
    }
}
