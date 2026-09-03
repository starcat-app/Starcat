//
//  ToolbarIcon.swift
//  Starcat
//
//  顶部 toolbar 中 SF Symbol 的统一视觉容器。
//
//  原归属：`RepoListView.toolbarIcon(_ systemName:)` 私有 helper。W12 toolbar
//  专项 PR-1 抽出共享，让 ExternalLinksMenu / MultiSelectButton /
//  UnifiedSortMenu / UnifiedFilterMenu 共享同一份 size / 行内 frame，避免
//  不同 SF Symbol 默认 bounding box 差异会造成 toolbar 控件视觉错位；
//  具体 symbol 由各 toolbar 入口按当前语义传入，本组件只负责统一光学尺寸。
//

import SwiftUI

/// 主窗口 toolbar SF Symbol 的统一尺寸（单一信任源）。
///
/// dong4j 2026-06-21 反馈 toolbar 图标偏大，从 16pt / 18×18 收紧到 13pt / 15×15。
/// 凡 toolbar 内自绘图标（含 chevron、状态按钮）都应引用此处，避免再次视觉错位。
enum ToolbarIconMetrics {
    static let defaultFontSize: CGFloat = 13
    static let frameSize: CGFloat = 15
    /// 与主图标同高，宽度略窄以匹配 chevron 字形比例。
    static let chevronFontSize: CGFloat = 9
    static let chevronFrameWidth: CGFloat = 10
    static let chevronFrameHeight: CGFloat = frameSize

    /// 同 pt 下 SF Symbol 光学尺寸不一致；按 symbol 微调字号。
    static func fontSize(for systemName: String) -> CGFloat {
        switch systemName {
        // compass 笔画细，且在 ExternalLinksMenu 的 ControlGroup 左半格内更显小。
        case "safari": 14.5
        default: defaultFontSize
        }
    }
}

/// Toolbar 用 SF Symbol 的标准容器：固定命中区 + regular weight。
struct ToolbarIcon: View {

    private let systemName: String

    init(_ systemName: String) {
        self.systemName = systemName
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: ToolbarIconMetrics.fontSize(for: systemName), weight: .regular))
            .frame(
                width: ToolbarIconMetrics.frameSize,
                height: ToolbarIconMetrics.frameSize,
                alignment: .center
            )
            .contentShape(Rectangle())
    }
}
