//
//  PillSegmentedControl.swift
//  Starcat
//
//  胶囊外框 + 选中项独立 pill 背景的横向分段切换器。
//
//  设计动机（2026-06-18 dong4j 反馈）：
//  - 系统 `Picker(.segmented)` 在 macOS 上是灰底 + 蓝色选中块，与 Trending 顶部
//    「今日 / 本周 / 本月」期望的深色胶囊风格不一致。
//  - 参考外部 pill tab：外容器大圆角 + 细边框；选中项内嵌小 pill；未选中纯文字；
//    相邻未选中项之间细竖线分隔（选中项两侧不画线，避免视觉断裂）。
//
//  关键约束：
//  - 颜色走语义色（`.primary` / `.secondary` opacity），明暗主题均可用；禁止写死深色 hex。
//  - 每个 segment 是 `.buttonStyle(.plain)` + `.focusEffectDisabled()`（项目铁律）。
//  - `title` 闭包返回 `LocalizedStringKey`，调用方 `Text(title(item))` 直出 i18n key。
//
//  使用范围（截至 2026-07-28）：
//  - `TrendingView.periodPicker`（regular，对齐 Activity / Weekly 顶栏行高）
//  - `RepoAIWindowContentView.panelToggleBar`（regular）
//  - `ManageDetailContent`（compact：README / 洞察）
//  - `MyInsightsView`（compact：全部收藏 / 知识库）
//  - `RepositoryInsightsView`（compact：Star / 提交活动范围）
//

import SwiftUI

/// 胶囊分段控件的视觉密度。
enum PillSegmentedControlSize: Sendable {
    /// 顶栏 / 工具条默认尺寸。
    case regular
    /// 详情内嵌、卡片工具条：更小字号与内边距，少占垂直空间。
    case compact

    var fontSize: CGFloat {
        switch self {
        case .regular: return 13
        case .compact: return 11
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: return 13
        case .compact: return 9
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .regular: return 4
        case .compact: return 2
        }
    }

    var chromePadding: CGFloat {
        switch self {
        case .regular: return 3
        case .compact: return 2
        }
    }

    var dividerHeight: CGFloat {
        switch self {
        case .regular: return 12
        case .compact: return 10
        }
    }
}

/// 胶囊风格横向分段切换器（单选）。
///
/// - Parameters:
///   - items: 从左到右的选项顺序（须唯一，用作 `ForEach` identity）。
///   - selection: 当前选中项 binding。
///   - title: 各选项的本地化标题（`LocalizedStringKey`）。
///   - size: 视觉密度；详情内嵌默认倾向 `.compact`。
struct PillSegmentedControl<Item: Hashable>: View {

    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> LocalizedStringKey
    var size: PillSegmentedControlSize = .regular

    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if showsDivider(before: index) {
                    segmentDivider
                }

                segmentButton(for: item)
            }
        }
        .padding(size.chromePadding)
        .background(Color.secondary.opacity(0.08), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
        }
        .animation(selectionAnimation, value: selection)
    }

    // MARK: - Segment

    private func segmentButton(for item: Item) -> some View {
        Button {
            selection = item
        } label: {
            Text(title(item))
                .font(.system(size: size.fontSize, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, size.horizontalPadding)
                .padding(.vertical, size.verticalPadding)
                .background(
                    selection == item
                        ? Color.primary.opacity(0.10)
                        : Color.clear,
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(selection == item ? .isSelected : [])
    }

    /// 相邻两个**均未选中**的 segment 之间画竖线；选中项两侧不画。
    private func showsDivider(before index: Int) -> Bool {
        guard index > 0 else { return false }
        let previous = items[index - 1]
        let current = items[index]
        return selection != previous && selection != current
    }

    private var segmentDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.20))
            .frame(width: 0.5, height: size.dividerHeight)
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }
}
