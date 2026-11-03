//
//  SettingsDisclosureGroupStyle.swift
//  Starcat
//
//  设置页折叠组的统一呈现：箭头位于行尾，整行支持点击与键盘操作。
//  展开状态继续使用 DisclosureGroup 原有绑定，不创建新的偏好或业务状态。
//

import SwiftUI

/// 调用方的 label 只提供内容，避免与这里的整行 Button 嵌套后重复切换状态。
struct SettingsDisclosureGroupStyle: DisclosureGroupStyle {
    let accessibilityLabel: Text
    var accessibilityHint: Text = Text(verbatim: "")
    @Environment(\.starcatReduceMotion) private var reduceMotion

    /// 自定义样式替换系统默认箭头，不叠加第二个指示器；行尾方向随 RTL 自动镜像。
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
                        .font(SettingsIconMetrics.smallGlyph)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(accessibilityHint)
            .accessibilityValue(Text(LocalizedStringKey(configuration.isExpanded
                                                        ? "settings.general.disclosure.expanded"
                                                        : "settings.general.disclosure.collapsed")))

            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
