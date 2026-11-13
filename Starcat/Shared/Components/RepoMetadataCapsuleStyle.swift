//
//  RepoMetadataCapsuleStyle.swift
//  Starcat
//
//  Hero 元信息胶囊共用的尺寸与描边，避免不同内容和边框算法造成视觉高低差。
//

import SwiftUI

/// License、来源与 Skills 使用相同高度和内描边，宽度仍由各自内容决定。
struct RepoMetadataCapsuleStyle: ViewModifier {
    let background: Color
    let border: Color
    var height: CGFloat = 20

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    /// 先确定胶囊外形再画内描边，保证描边和悬停都不会额外撑大可见尺寸。
    func body(content: Content) -> some View {
        content
            .font(interfaceScale.font(.captionSmall, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: interfaceScale.scaled(height))
            .background(background, in: Capsule())
            .overlay {
                Capsule().strokeBorder(border, lineWidth: 1)
            }
            .contentShape(Capsule())
    }
}
