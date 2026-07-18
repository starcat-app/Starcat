//
//  EqualWidthSegmentedControl.swift
//  Starcat
//
//  等宽铺满的横向分段切换器（单选）。
//
//  设计动机（2026-07-18 dong4j 反馈）：
//  - 系统 `Picker(.segmented)` 按文案 intrinsic 决定段宽；中文双字短、英文单词长，
//    同一套设置会出现「中文半行短条 / 英文近整行」两套布局。
//  - 即便 `.frame(maxWidth: .infinity)`，macOS 仍常把多余宽度留在轨道右侧空白，
//    段本身不拉伸。
//  - 本控件用 GeometryReader 按父宽均分每段，中英文观感一致，轨道与选中块都占满行。
//
//  关键约束：
//  - 禁止多个子项各自 `.frame(maxWidth: .infinity)` 反向协商 HStack 宽度
//    （macOS 26 上曾导致主线程自旋）；宽度必须由外层 GeometryReader 一次算清。
//  - 每个 segment 是 `.buttonStyle(.plain)` + `.focusEffectDisabled()`（项目铁律）。
//  - 选中态用 `Color.accentColor` + 白字，贴近系统 segmented 的蓝底块。
//
//  使用范围：
//  - AI 设置「模型配置 / Prompt / 索引预设」
//  - RAG 工作台设置「提示词类型 / 检索预设 / Rerank provider」
//  - RAG 引用侧栏 `RAGInspectorTabBar`（同源布局）
//

import SwiftUI

/// 等宽铺满横向分段切换器。
///
/// - Parameters:
///   - items: 从左到右的选项（须唯一，用作 identity）。
///   - selection: 当前选中项。
///   - title: 各选项的本地化标题 key。
///   - font: 段文字字体；设置页默认 13 medium，侧栏可传 caption。
struct EqualWidthSegmentedControl<Item: Hashable>: View {

    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> LocalizedStringKey
    var font: Font = .system(size: 13, weight: .medium)
    var controlHeight: CGFloat = 28

    @Environment(\.starcatReduceMotion) private var reduceMotion

    private static let horizontalInset: CGFloat = 3
    private static let dividerWidth: CGFloat = 1
    private static let cornerRadius: CGFloat = 6
    private static let trackCornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            // 由确定的父宽度一次性分配每段宽度，避免多个 `.infinity` 子项反向参与
            // HStack 的尺寸协商；后者在 macOS 26 的 SwiftUI 布局引擎中会造成主线程自旋。
            let dividerCount = max(items.count - 1, 0)
            let contentWidth = max(
                0,
                proxy.size.width
                    - Self.horizontalInset * 2
                    - CGFloat(dividerCount) * Self.dividerWidth
            )
            let tabWidth = items.isEmpty ? 0 : contentWidth / CGFloat(items.count)
            let segmentHeight = controlHeight - Self.horizontalInset * 2

            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    segmentButton(
                        for: item,
                        width: tabWidth,
                        height: segmentHeight
                    )

                    if index < items.count - 1 {
                        Rectangle()
                            .fill(showsDivider(before: index + 1) ? Color.primary.opacity(0.18) : .clear)
                            .frame(width: Self.dividerWidth, height: 14)
                    }
                }
            }
            .padding(Self.horizontalInset)
        }
        .frame(height: controlHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Self.trackCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selection)
    }

    // MARK: - Segment

    private func segmentButton(for item: Item, width: CGFloat, height: CGFloat) -> some View {
        Button {
            selection = item
        } label: {
            Text(title(item))
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: width, height: height)
                .foregroundStyle(selection == item ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(selection == item ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(selection == item ? .isSelected : [])
    }

    /// 仅在相邻两个未选中段之间画竖线，与系统 segmented 分隔习惯一致。
    private func showsDivider(before index: Int) -> Bool {
        guard index > 0 else { return false }
        return selection != items[index - 1] && selection != items[index]
    }
}
