//
//  SheetCloseButton.swift
//  Starcat
//
//  自定义 sheet / 浮层 header 右上角关闭钮 —— 全 App 单一信任源。
//
//  规格（2026-06-26 dong4j 拍板）：
//  - `xmark.circle.fill` + `.symbolRenderingMode(.hierarchical)` + `.foregroundStyle(.secondary)`
//  - 贴合 macOS 搜索清除 / 轻量 dismiss 语义，明暗主题自动适配
//  - **不**用于搜索框「清空内容」、destructive 红叉、同步取消 hover 等特殊语义
//

import SwiftUI

/// Sheet / 面板 header 关闭按钮。
struct SheetCloseButton: View {
    let action: () -> Void
    /// 图标字号；各 surface 按原占位保留尺寸。
    var iconFont: Font = .system(size: 18, weight: .medium)
    /// 点击热区；默认 24×24，与 RepoHealth / ShareCard header 对齐。
    var frameSize: CGFloat = 24
    var helpKey: LocalizedStringKey = "common.close"

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(iconFont)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(helpKey)
    }
}
