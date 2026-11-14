//
//  RepoLanguageFilterChip.swift
//  Starcat
//
//  语言多选胶囊沿用许可证的标签表面，语言图标由调用方提供以复用现有图标缓存。
//

import SwiftUI

/// 显式展示选中态，点击行为继续由全局语言筛选绑定负责。
struct RepoLanguageFilterChip<Icon: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    var helpText: String? = nil
    @ViewBuilder let icon: Icon
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Group {
                    if isSelected && differentiateWithoutColor {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .medium))
                    } else {
                        icon
                    }
                }
                .frame(width: 14, height: 14)
                Text(verbatim: title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // 与许可证共用选中底色、描边和内边距，避免两组胶囊出现不同的视觉密度。
            .modifier(TagChipSurface(color: .accentColor, isSelected: isSelected))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: TagChipSurface.cornerRadius))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text(verbatim: helpText ?? title))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .pressableHover(scale: 1)
    }
}
