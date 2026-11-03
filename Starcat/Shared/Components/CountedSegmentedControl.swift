//
//  CountedSegmentedControl.swift
//  Starcat
//
//  仓库分组与标签整理共用的紧凑计数 Tab，不持有业务计数或第二份筛选状态。
//

import SwiftUI

/// 标题与按完整批次预留的计数区共同决定宽度，不按当前计数伸缩，也不等宽铺满整行。
struct CountedSegmentedControl<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let totalCount: Int
    let title: (Item) -> LocalizedStringKey
    let count: (Item) -> Int
    let accessibilityLabel: LocalizedStringKey
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedItem: Item?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                segmentButton(for: item)
                if index < items.count - 1 {
                    // 只隐藏分隔线颜色，不移除子视图；选中态切换也不能改变整体宽度。
                    Rectangle()
                        .fill(selection == item || selection == items[index + 1] ? .clear : Color.primary.opacity(0.18))
                        .frame(width: 1, height: interfaceScale.scaled(14))
                }
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colorScheme == .dark ? StarcatSurface.panel(colorScheme: colorScheme) : Color.primary.opacity(0.06))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityLabel))
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
    }

    /// 整段都是一个按钮，标题与数字不能变成两个独立点击目标。
    private func segmentButton(for item: Item) -> some View {
        Button {
            selection = item
        } label: {
            CountedSegmentLabel(title: title(item), count: count(item), totalCount: totalCount)
                .font(interfaceScale.font(.body, weight: .medium))
                .padding(.horizontal, 8)
                // 标准档加上下内边距后仍为原 regular 控件的 24pt，不随修复放大工具栏。
                .frame(height: interfaceScale.scaled(20))
                // 沿用原分段控件的强调色底与白字，未选中仍用系统主文字色。
                .foregroundStyle(selection == item ? Color.white : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selection == item ? Color.accentColor : .clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focusedItem, equals: item)
        .accessibilityAddTraits(selection == item ? .isSelected : [])
        .help(Text(title(item)))
    }

    /// 保留分段控件的方向键切换体验，并同步焦点，避免随后按空格又选回旧项。
    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard let index = items.firstIndex(of: focusedItem ?? selection) else { return .ignored }
        let next = index + offset
        guard items.indices.contains(next) else { return .handled }
        selection = items[next]
        focusedItem = items[next]
        return .handled
    }
}
