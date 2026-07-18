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
//  - 本控件按父宽均分每段，中英文观感一致，轨道与选中块都占满行。
//
//  关键约束：
//  - 禁止多个子项各自 `.frame(maxWidth: .infinity)` 反向协商 HStack 宽度
//    （macOS 26 上曾导致主线程自旋）；宽度必须由外层一次算清。
//  - Form / DisclosureGroup 里裸 GeometryReader 常只拿到 intrinsic 窄宽：先用
//    `Color.clear` 撑满父宽，再 overlay 测量，才能真正等分整行。
//  - 每个 segment 是 `.buttonStyle(.plain)` + `.focusEffectDisabled()`（项目铁律）。
//  - 选中态用 `Color.accentColor` + 白字，贴近系统 segmented 的蓝底块。
//
//  使用范围：
//  - AI 设置「模型配置 / Prompt / 索引预设」
//  - RAG 工作台设置「提示词类型 / 检索预设 / Rerank provider」
//  - RAG 引用侧栏 `RAGInspectorTabBar`（同源布局）
//

import SwiftUI

/// 等宽 segmented 的几何常量（独立于泛型 View，避免 generic type 不能放 static stored）。
private enum EqualWidthSegmentedMetrics {
    static let horizontalInset: CGFloat = 3
    static let dividerWidth: CGFloat = 1
    static let cornerRadius: CGFloat = 6
    static let trackCornerRadius: CGFloat = 8
}

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

    var body: some View {
        // Form / DisclosureGroup 里裸 GeometryReader 常只拿到 intrinsic 窄宽；
        // 先用 clear 撑满父宽，再 overlay 测量，才能真正等分整行。
        Color.clear
            .frame(height: controlHeight)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { proxy in
                    let dividerCount = max(items.count - 1, 0)
                    let contentWidth = max(
                        0,
                        proxy.size.width
                            - EqualWidthSegmentedMetrics.horizontalInset * 2
                            - CGFloat(dividerCount) * EqualWidthSegmentedMetrics.dividerWidth
                    )
                    let tabWidth = items.isEmpty ? 0 : contentWidth / CGFloat(items.count)
                    let segmentHeight = controlHeight - EqualWidthSegmentedMetrics.horizontalInset * 2

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
                                    .frame(width: EqualWidthSegmentedMetrics.dividerWidth, height: 14)
                            }
                        }
                    }
                    .padding(EqualWidthSegmentedMetrics.horizontalInset)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: EqualWidthSegmentedMetrics.trackCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            // 细描边：轨道在半透明卡片上仍能看出边界，避免只剩「裸文字 + 蓝 pill」。
            .overlay {
                RoundedRectangle(cornerRadius: EqualWidthSegmentedMetrics.trackCornerRadius, style: .continuous)
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
            }
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
                    RoundedRectangle(cornerRadius: EqualWidthSegmentedMetrics.cornerRadius, style: .continuous)
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
