//
//  ManageListFilterBarMetrics.swift
//  Starcat
//
//  Manage 中栏列表顶栏（排序 / 同步 / Smart Collections 规则行）共用尺寸。
//  单一信任源：与 `RepoListView.manageFilterBar` padding 保持一致，避免中栏 / 右栏顶区错层。
//

import CoreGraphics

enum ManageListFilterBarMetrics {
    static let horizontalPadding: CGFloat = 14
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 6
}
