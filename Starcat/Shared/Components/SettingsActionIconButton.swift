//
//  SettingsActionIconButton.swift
//  Starcat
//
//  设置页通用轻操作入口。固定图标尺寸与命中区，避免翻译长度改变操作组布局。
//  删除、刷新、重置等已有专用组件的动作继续使用原组件。
//

import SwiftUI

/// 保留可访问的动作名称，只隐藏视觉文案；业务门控由调用方的 disabled 控制。
struct SettingsActionIconButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    /// Tooltip 与 VoiceOver 共享同一个本地化名称，图标本身不承担唯一语义。
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(SettingsIconMetrics.standardGlyph)
                .foregroundStyle(.secondary)
                .frame(width: SettingsIconMetrics.actionFrameSize, height: SettingsIconMetrics.actionFrameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}
