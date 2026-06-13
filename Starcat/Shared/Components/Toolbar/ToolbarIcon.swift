//
//  ToolbarIcon.swift
//  Starcat
//
//  顶部 toolbar 中 SF Symbol 的统一视觉容器。
//
//  原归属：`RepoListView.toolbarIcon(_ systemName:)` 私有 helper。W12 toolbar
//  专项 PR-1 抽出共享，让 ExternalLinksMenu / CloneMenu / MultiSelectButton /
//  UnifiedSortMenu / UnifiedFilterMenu 共享同一份 size / 行内 frame，避免
//  不同 SF Symbol 默认 bounding box 差异（典型如 `doc.on.clipboard` 比
//  `safari` 高）造成 toolbar 控件视觉错位。
//

import SwiftUI

/// Toolbar 用 SF Symbol 的标准容器：固定 18×18 命中区 + 16pt regular weight。
struct ToolbarIcon: View {

    private let systemName: String

    init(_ systemName: String) {
        self.systemName = systemName
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .regular))
            .frame(width: 18, height: 18, alignment: .center)
            .contentShape(Rectangle())
    }
}
