//
//  MainWindowContentColumnAnchors.swift
//  Starcat
//
//  让洞察和每日热点在共同父层跨越中右栏，同时保留侧栏与左侧分隔线。
//

import SwiftUI

/// 只测量两个内容宿主，不把结果写回主窗口宽度或持久化布局。
struct MainWindowContentColumnAnchors: PreferenceKey {
    enum Column: Hashable {
        case content
        case detail
    }

    static var defaultValue: [Column: Anchor<CGRect>] { [:] }

    /// 合并两个分栏独立发出的锚点，在 HomeView 共同坐标空间中统一解析。
    static func reduce(
        value: inout [Column: Anchor<CGRect>],
        nextValue: () -> [Column: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
