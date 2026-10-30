//
//  DailyRadarPreviewColumnAnchors.swift
//  Starcat
//
//  每日热点原生预览的分栏几何桥接。只在 Debug 构建收集中栏与右栏的真实范围，
//  让共同父层的阅读工作区覆盖内部 divider，同时保留侧栏与左侧分隔线。
//

import SwiftUI

/// 预览只关心两个内容宿主，不把其几何测量写回主窗口宽度或持久化布局。
struct DailyRadarPreviewColumnAnchors: PreferenceKey {
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
