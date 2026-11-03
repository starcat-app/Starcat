//
//  GitHubNotificationIssueSummaryAnchorKey.swift
//  Starcat
//
//  把输入卡片和输入区分割线的真实边界传给详情浮层。水平方向对齐卡片，
//  垂直方向以分割线为准，避免光晕和外边距让入口跨线；测量不写入高度 @State。
//

import SwiftUI

/// 汇总同一详情内两处布局信息；两者齐备时才挂载总结入口。
struct GitHubNotificationIssueSummaryAnchorKey: PreferenceKey {
    /// 不从卡片边缘推测分割线位置，输入框的光晕或留白变化不应再次把按钮压在线上。
    struct Bounds {
        var composer: Anchor<CGRect>?
        var divider: Anchor<CGRect>?
    }

    static var defaultValue: Bounds { Bounds() }

    /// 分割线与卡片分别提供自己的 anchor，不让另一子树的空字段覆盖已测得的边界。
    static func reduce(value: inout Bounds, nextValue: () -> Bounds) {
        let next = nextValue()
        value.composer = next.composer ?? value.composer
        value.divider = next.divider ?? value.divider
    }
}
