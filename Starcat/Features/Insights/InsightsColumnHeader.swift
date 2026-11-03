//
//  InsightsColumnHeader.swift
//  Starcat
//
//  洞察两栏共用的紧凑顶栏；自然高度与用于对齐的显示高度必须分开测量。
//

import SwiftUI

/// 保留内容字号和控件尺寸，只向主窗口报告需要的高度，再使用两栏共同高度对齐。
struct InsightsColumnHeader<Content: View>: View {
    let height: CGFloat
    private let content: Content

    /// 高度由同一主窗口协调，不写入设置，也不在多个窗口之间共享。
    init(height: CGFloat, @ViewBuilder content: () -> Content) {
        self.height = height
        self.content = content()
    }

    var body: some View {
        content
            .padding(.vertical, InsightsColumnChrome.headerVerticalPadding)
            // 测量时忽略外层高度提案，否则上一轮撑高的 frame 会再次上报，永远无法收缩。
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: InsightsColumnHeaderHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
            // 首次测量尚未回传时也允许内容自然增高，不能把控件裁在 64pt 内。
            .frame(minHeight: height, alignment: .topLeading)
    }
}
