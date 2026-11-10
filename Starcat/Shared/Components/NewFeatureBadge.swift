//
//  NewFeatureBadge.swift
//  Starcat
//
//  新功能首次发现标识的共享视觉组件。
//

import SwiftUI

/// 蓝色小圆点只承担“这里有新变化”的视觉提示。
///
/// 组件保持固定尺寸：未查看时显示圆点，已查看时透明占位，避免入口文字在点击后发生位移。
/// 具体是否展示由 `NewFeatureBadgeStore` 按功能 ID 决定，组件不读写 UserDefaults。
struct NewFeatureBadge: View {
    let isVisible: Bool

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 5, height: 5)
            .fixedSize()
            .opacity(isVisible ? 1 : 0)
            // 圆点是现有入口行为之外的辅助提示，无障碍名称交给入口自身。
            .accessibilityHidden(true)
    }
}

#Preview("New feature badge") {
    HStack(spacing: 4) {
        Text("Followers")
        NewFeatureBadge(isVisible: true)
    }
    .padding()
}
