//
//  EqualWidthSegmentedControl.swift
//  Starcat
//
//  等宽铺满的横向分段切换器（单选）。
//
//  设计动机（2026-07-18 dong4j 反馈）：
//  - 系统 `Picker(.segmented)` 按文案 intrinsic 决定段宽；中文短 / 英文长会两套布局。
//  - Form / DisclosureGroup 里 GeometryReader 常常量不到父宽，控件会缩成「中间一小截」。
//  - 这里用自定义 `Layout`：有提案宽就吃满并均分；避免多个 `.infinity` 子项反向协商
//    （macOS 26 上曾主线程自旋）。
//
//  关键约束：
//  - 每个 segment：`.buttonStyle(.plain)` + `.focusEffectDisabled()`。
//  - 选中态：`Color.accentColor` + 白字。
//

import SwiftUI

private enum EqualWidthSegmentedMetrics {
    static let horizontalInset: CGFloat = 3
    static let dividerWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 6
    static let trackCornerRadius: CGFloat = 8
}

/// 等宽铺满横向分段切换器。
struct EqualWidthSegmentedControl<Item: Hashable>: View {

    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> LocalizedStringKey
    var font: Font = .system(size: 13, weight: .medium)
    var controlHeight: CGFloat = 28

    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        EqualWidthSegmentLayout(dividerWidth: EqualWidthSegmentedMetrics.dividerWidth) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                segmentButton(for: item)

                if index < items.count - 1 {
                    Rectangle()
                        .fill(showsDivider(before: index + 1) ? Color.primary.opacity(0.18) : .clear)
                        .frame(width: EqualWidthSegmentedMetrics.dividerWidth, height: 14)
                        // Layout 用固定宽识别分隔线子视图
                        .layoutValue(key: EqualWidthSegmentIsDividerKey.self, value: true)
                }
            }
        }
        .padding(EqualWidthSegmentedMetrics.horizontalInset)
        .frame(height: controlHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: EqualWidthSegmentedMetrics.trackCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: EqualWidthSegmentedMetrics.trackCornerRadius, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selection)
    }

    private func segmentButton(for item: Item) -> some View {
        Button {
            selection = item
        } label: {
            Text(title(item))
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(selection == item ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: EqualWidthSegmentedMetrics.cornerRadius, style: .continuous)
                        .fill(selection == item ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(selection == item ? .isSelected : [])
        .layoutValue(key: EqualWidthSegmentIsDividerKey.self, value: false)
    }

    private func showsDivider(before index: Int) -> Bool {
        guard index > 0 else { return false }
        return selection != items[index - 1] && selection != items[index]
    }
}

// MARK: - Layout

private struct EqualWidthSegmentIsDividerKey: LayoutValueKey {
    static let defaultValue = false
}

/// 把非分隔线子视图等分可用宽度；分隔线保持固定宽并垂直居中。
private struct EqualWidthSegmentLayout: Layout {
    var dividerWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let heights = subviews.map { $0.sizeThatFits(.unspecified).height }
        let height = max(heights.max() ?? 0, 22)
        // 有明确提案宽 → 吃满（Form 行宽）；否则退回子项 intrinsic 之和（预览兜底）。
        if let width = proposal.width, width.isFinite, width > 0 {
            return CGSize(width: width, height: height)
        }
        let intrinsic = subviews.reduce(CGFloat(0)) { partial, subview in
            partial + subview.sizeThatFits(.unspecified).width
        }
        return CGSize(width: max(intrinsic, 1), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let dividers = subviews.filter { $0[EqualWidthSegmentIsDividerKey.self] }
        let segments = subviews.filter { !$0[EqualWidthSegmentIsDividerKey.self] }
        let dividerTotal = CGFloat(dividers.count) * dividerWidth
        let segmentCount = max(segments.count, 1)
        let segmentWidth = max((bounds.width - dividerTotal) / CGFloat(segmentCount), 0)

        var x = bounds.minX
        for subview in subviews {
            if subview[EqualWidthSegmentIsDividerKey.self] {
                let size = CGSize(width: dividerWidth, height: min(14, bounds.height))
                subview.place(
                    at: CGPoint(x: x, y: bounds.midY - size.height / 2),
                    proposal: ProposedViewSize(size)
                )
                x += dividerWidth
            } else {
                let size = CGSize(width: segmentWidth, height: bounds.height)
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    proposal: ProposedViewSize(size)
                )
                x += segmentWidth
            }
        }
    }
}
