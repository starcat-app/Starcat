//
//  CountedSegmentedControl.swift
//  Starcat
//
//  仓库分组、标签整理与 Skill 共用的紧凑 Tab，不持有业务计数或第二份筛选状态。
//

import SwiftUI

/// 标题与可选计数共同决定宽度；提供图标时按实际空间收紧展示，不改变业务选择。
struct CountedSegmentedControl<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let totalCount: Int
    let title: (Item) -> LocalizedStringKey
    let count: (Item) -> Int?
    let accessibilityLabel: LocalizedStringKey
    var symbol: ((Item) -> String)? = nil
    var tint: (Item) -> Color = { _ in .accentColor }
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedItem: Item?

    var body: some View {
        Group {
            if symbol != nil {
                // 只测量三个轻量 Tab；正文与列表不放进 ViewThatFits，避免尺寸变化重建业务视图。
                ViewThatFits(in: .horizontal) {
                    segments(iconOnly: false)
                        .fixedSize(horizontal: true, vertical: false)
                    segments(iconOnly: true)
                }
            } else {
                segments(iconOnly: false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityLabel))
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
    }

    /// 两种展示共享分段尺寸与选择状态，选中项、数字更新均不改变控件高度。
    private func segments(iconOnly: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                segmentButton(for: item, iconOnly: iconOnly)
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
    }

    /// 整段都是一个按钮，标题与数字不能变成两个独立点击目标。
    private func segmentButton(for item: Item, iconOnly: Bool) -> some View {
        Button {
            selection = item
        } label: {
            segmentLabel(for: item, iconOnly: iconOnly)
                .font(interfaceScale.font(.body, weight: .medium))
                .padding(.horizontal, iconOnly ? 6 : 8)
                // 标准档加上下内边距后仍为原 regular 控件的 24pt，不随修复放大工具栏。
                .frame(height: interfaceScale.scaled(20))
                // 紧凑模式按产品要求用语义色区分图标；选中仍沿用强调色底与白字，避免只靠颜色辨认。
                .foregroundStyle(selection == item ? Color.white : (iconOnly ? tint(item) : Color.primary))
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

    /// nil 表示该 Tab 不展示计数；图标模式仍以完整标题供读屏和悬停提示使用。
    @ViewBuilder
    private func segmentLabel(for item: Item, iconOnly: Bool) -> some View {
        if let count = count(item) {
            CountedSegmentLabel(
                title: title(item), count: count, totalCount: totalCount,
                symbol: iconOnly ? symbol?(item) : nil
            )
        } else if iconOnly, let symbol {
            Image(systemName: symbol(item))
                .accessibilityLabel(Text(title(item)))
        } else {
            Text(title(item))
                .lineLimit(1)
        }
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
