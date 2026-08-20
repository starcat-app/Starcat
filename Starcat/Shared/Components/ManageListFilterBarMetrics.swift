//
//  ManageListFilterBarMetrics.swift
//  Starcat
//
//  Manage 中栏列表顶栏（排序 / 同步 / Smart Collections 规则行）共用尺寸。
//  单一信任源：与 `RepoListView.manageFilterBar` padding 保持一致，避免中栏 / 右栏顶区错层。
//

import CoreGraphics
import SwiftUI

enum ManageListFilterBarMetrics {
    static let horizontalPadding: CGFloat = 14
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 6
    /// macOS 分段 Picker 大约这么高。chip / 一句 banner 更矮，只靠 padding 分割线会对不齐。
    static let controlHeight: CGFloat = 28
    /// 中栏 / 右栏顶栏总高度（含上下 padding）。钉死后分割线才能水平对齐。
    static var barHeight: CGFloat { topPadding + bottomPadding + controlHeight }
}

extension View {
    /// 钉死与 Manage 中栏顶栏同高。先水平 padding，再锁高度，内容垂直居中。
    func manageListFilterBarChrome() -> some View {
        padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: ManageListFilterBarMetrics.barHeight,
                maxHeight: ManageListFilterBarMetrics.barHeight,
                alignment: .center
            )
    }
}
