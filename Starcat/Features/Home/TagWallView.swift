//
//  TagWallView.swift
//  Starcat
//
//  HOM-179：左侧 Tags 列表改为标签墙组件。
//
//  设计演进（dong4j 反馈驱动）：
//  - v1：选中 / 未选中都 30%-50% opacity 透明背景，区分度太弱
//  - v3：选中 = 实色底 + 自适应黑白文字；未选中 = 12% 浅底 + 同色文字
//  - **v4（当前）**：未选中文字色改 `.primary`（系统自适应黑/白），
//    与 swatchColor 浅底形成明显对比，且天然适配亮/暗主题；
//    icon 仍用 swatchColor 保留 tag 身份；
//    选中态保留 v3 的实色底 + 自适应黑白文字 + 阴影方案。
//  - icon 始终展示：tag.icon 优先，无则 fallback 到 `tag.fill`，与 sidebar
//    `tagRow()` 保持同款图标语言，避免标签墙 / 列表两种形态视觉割裂。
//  - 自适应文字色：tag 实色底上的文字色按 sRGB 相对亮度自动选黑或白
//    （阈值 0.6），避免黄色等浅 tag 出现"白字 + 黄底"无法阅读的情况。
//

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - TagWallView

/// 标签墙视图：横向排列、自动换行，支持多选。
///
/// 调用方在 `onTagTap` 中执行 toggle 动作（建议直接调
/// `HomeViewModel.toggleSelectedTag`），本视图不维护任何状态——
/// `selectedTagIds` 是被动入参，更新由外部完成。
struct TagWallView: View {
    let tags: [Tag]
    /// nil 表示当前范围仍在查询，不能显示上一范围的数字或伪装成真实的 0。
    let tagCounts: [String: Int]?
    /// 当前账号每个标签的总量为计数预留空间，筛选和加载时不改变胶囊宽度。
    var countUpperBounds: [String: Int] = [:]
    /// 已勾选的 tag id 集合（多选）。
    let selectedTagIds: Set<String>
    /// 用户点击某个 chip 时调用。调用方负责 toggle 这个 id 在集合内的勾选状态。
    let onTagTap: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags) { tag in
                TagWallChip(
                    tag: tag,
                    count: tagCounts.map { $0[tag.id] ?? 0 },
                    countUpperBound: countUpperBounds[tag.id] ?? tagCounts?[tag.id] ?? 0,
                    isSelected: selectedTagIds.contains(tag.id),
                    onTap: { onTagTap(tag.id) }
                )
            }
        }
    }
}

// MARK: - TagWallChip

/// 标签墙单个标签：
/// - 未选中：tag.color 18% 浅底 + 35% 描边；icon 用 tag.color，name 用 `.primary`，
///   count 用 `.secondary`——颜色身份保留在 icon，文字直接走系统自适应灰阶
///   保证亮/暗主题下都和底色清晰区分（dong4j 2026-06-07 反馈：
///   "字体颜色和底色是一个色系，最好明显区分"）
/// - 选中：tag.color 实色底 + 自适应黑/白文字 + 1pt 描边 + 软阴影（高对比、勾选感强）
/// - icon 始终展示：tag.icon 优先，无则 `tag.fill`
struct TagWallChip: View {
    let tag: Tag
    let count: Int?
    let countUpperBound: Int
    let isSelected: Bool
    let onTap: () -> Void

    /// 2026-06-15:tag chip 选中态切换 0.15s 渐变在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    /// 圆角常量；放在视图外部以便 background / clipShape / overlay 共用同一个值。
    private static let cornerRadius: CGFloat = 6

    /// 标签颜色，fallback 到默认蓝色（tag.color 解析失败 / nil 时）。
    private var swatchColor: Color {
        Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor
    }

    /// 选中态前景色：基于 swatchColor 亮度自适应黑/白，避免黄色等浅 tag 上白字无法阅读。
    /// 阈值 0.6 是经验值——常见 tag palette（红蓝绿紫）大都 < 0.6 → 用白字；
    /// 黄色 / 浅绿 / 浅蓝（≥ 0.6）→ 用黑字。
    private var selectedForeground: Color {
        swatchColor.perceivedLuminance > 0.6 ? .black : .white
    }

    var body: some View {
        HStack(spacing: 4) {
            // 图标：tag.icon 优先，无则用 `tag.fill` 兜底，跟 sidebar tagRow 同款语言。
            // 未选中时显式给 swatchColor，让 tag 颜色身份不被 .primary 覆盖；
            // 选中时跟随外层 selectedForeground，保持与文字同色。
            Image(systemName: tag.icon ?? "tag.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? selectedForeground : swatchColor)

            Text(verbatim: tag.name)
                .font(.caption)
                .lineLimit(1)

            ZStack(alignment: .trailing) {
                // 等宽数字只保证单个数字等宽，不能防止位数和横线占位改变整体宽度。
                // 隐藏参考文本按真实字体 / 数字格式占位，兼顾大计数与本地化分组符。
                Text(max(countUpperBound, count ?? 0).formatted())
                    .hidden()
                    .accessibilityHidden(true)
                Text("—")
                    .hidden()
                    .accessibilityHidden(true)
                Text(count?.formatted() ?? "—")
            }
                .font(.caption2)
                .opacity(isSelected ? 0.85 : 1)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                // 未选中时让计数走 .secondary 减弱视觉权重，避免和 name 同等高对比抢戏。
                // 选中时 count 跟随 selectedForeground，0.85 透明度做层级区分。
                .foregroundStyle(isSelected ? AnyShapeStyle(selectedForeground) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // 选中：实色底，强对比；未选中：18% 浅底，柔和但仍能看清边界。
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(isSelected ? AnyShapeStyle(swatchColor) : AnyShapeStyle(swatchColor.opacity(0.18)))
        }
        // 文字色：未选中用 .primary（系统自适应黑/白），选中用 selectedForeground。
        // 这是与底色对比的关键——.primary 不是 swatchColor，所以肯定不"同色系"。
        .foregroundStyle(isSelected ? AnyShapeStyle(selectedForeground) : AnyShapeStyle(.primary))
        // 描边：未选中 0.5pt 35% 同色描边，强化 chip 边界感；选中 1pt 90% 同色描边。
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(
                    isSelected ? swatchColor.opacity(0.9) : swatchColor.opacity(0.35),
                    lineWidth: isSelected ? 1 : 0.5
                )
        }
        // 选中态加一层柔和投影，进一步突出"已选"层级；未选中投影 radius=0 退化为无。
        .shadow(color: swatchColor.opacity(isSelected ? 0.35 : 0), radius: 2, y: 1)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .onTapGesture {
            // 标签墙使用手势而非 Button，必须主动遵守父视图的禁用状态。
            guard isEnabled else { return }
            onTap()
        }
        .pressableHover(scale: 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
    }
}

// MARK: - 颜色亮度工具

fileprivate extension Color {
    /// sRGB 相对亮度（0..1）。用于在已知色块上选择黑 / 白文字。
    /// 公式来自 W3C WCAG：L = 0.2126R + 0.7152G + 0.0722B（线性近似，
    /// 不做严格 gamma 反变换；对 chip 这种非长文场景足够）。
    var perceivedLuminance: Double {
        #if canImport(AppKit)
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * Double(ns.redComponent)
             + 0.7152 * Double(ns.greenComponent)
             + 0.0722 * Double(ns.blueComponent)
        #else
        return 0.5
        #endif
    }
}

// MARK: - FlowLayout

/// 横向排列自动换行布局，复用自 RepoTagsSection。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Preview

#Preview {
    TagWallView(
        tags: [
            Tag(id: "1", name: "Swift", color: "#FF453A", icon: "swift", sortOrder: 0, isPreset: false, parentId: nil, createdAt: "2024-01-01T00:00:00Z", updatedAt: "2024-01-01T00:00:00Z"),
            Tag(id: "2", name: "JavaScript", color: "#FFD60A", icon: nil, sortOrder: 1, isPreset: false, parentId: nil, createdAt: "2024-01-01T00:00:00Z", updatedAt: "2024-01-01T00:00:00Z"),
            Tag(id: "3", name: "Python", color: "#30D158", icon: nil, sortOrder: 2, isPreset: false, parentId: nil, createdAt: "2024-01-01T00:00:00Z", updatedAt: "2024-01-01T00:00:00Z"),
            Tag(id: "4", name: "Rust", color: "#0A84FF", icon: "hammer", sortOrder: 3, isPreset: false, parentId: nil, createdAt: "2024-01-01T00:00:00Z", updatedAt: "2024-01-01T00:00:00Z"),
            Tag(id: "5", name: "Go", color: "#66D4CF", icon: nil, sortOrder: 4, isPreset: false, parentId: nil, createdAt: "2024-01-01T00:00:00Z", updatedAt: "2024-01-01T00:00:00Z"),
        ],
        tagCounts: ["1": 42, "2": 28, "3": 15, "4": 8, "5": 3],
        selectedTagIds: ["1", "3"],
        onTagTap: { _ in }
    )
    .frame(width: 280)
    .padding()
}
