//
//  HeroActionIconStyle.swift
//  Starcat
//
//  仓库详情 Hero 操作图标的共用视觉样式。
//

import SwiftUI

/// 统一 Hero 图标按钮的中性底色，让 Wiki、知识库与分享保持相同视觉体积。
///
/// 图标本身继续承载各自语义色；背景只负责提供点击区域层级，因此不跟随图标染色。
/// 深色主题需要略高透明度，避免中性底色融入详情页背景。
enum HeroActionIconStyle {
    static func background(colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06)
    }
}
