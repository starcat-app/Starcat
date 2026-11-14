//
//  RepoFilterTabs.swift
//  Starcat
//
//  全局筛选共用的紧凑单选 Tab，保持各组的原有筛选绑定与完整状态说明。
//

import SwiftUI

/// 选项等宽横排；长译文回退为状态图标，不通过换行或缩小字号增加面板高度。
struct RepoFilterTabs<Value: Hashable>: View {
    let label: LocalizedStringKey
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> LocalizedStringKey
    var shortTitle: ((Value) -> LocalizedStringKey)? = nil
    let symbol: (Value) -> String
    var color: (Value) -> Color = { _ in .secondary }
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Text(shortTitle?(option) ?? title(option))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            // 按完整文案测宽，避免文字先被截断而无法触发图标回退。
                            .fixedSize(horizontal: true, vertical: false)
                        Image(systemName: symbol(option))
                            .symbolRenderingMode(.hierarchical)
                            // 窄宽模式按产品要求用状态色辅助辨认，图标形状仍独立表达含义。
                            .foregroundStyle(color(option))
                    }
                    .font(interfaceScale.font(.captionSmall, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 24)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text(title(option)))
                .accessibilityLabel(Text(title(option)))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }
}
