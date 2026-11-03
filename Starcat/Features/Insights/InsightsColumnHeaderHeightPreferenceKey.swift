//
//  InsightsColumnHeaderHeightPreferenceKey.swift
//  Starcat
//
//  只合并当前视图树内两个洞察顶栏的自然高度，不累计历史高度。
//

import SwiftUI

/// 共享较高一栏的需求，让中栏与右栏的分割线始终处于同一水平位置。
struct InsightsColumnHeaderHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    /// 每次布局重新取最大值；任意一栏变矮后，共用高度仍可下降。
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
