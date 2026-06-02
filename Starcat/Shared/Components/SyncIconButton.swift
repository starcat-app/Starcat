//
//  SyncIconButton.swift
//  Starcat
//
//  共享同步/刷新 icon 按钮：图标 + 旋转动画 + hover 反馈三件套统一封装。
//
//  设计动机（2026-06-02 dong4j 反馈）：
//  - 之前项目里同款"刷新"诉求散落在三处，图标 / 动画都不一样：
//    ① `SidebarView.SidebarSyncButton`（全部 Stars 右侧）：`arrow.triangle.2.circlepath` +
//       手动 rotationEffect + repeatForever withAnimation —— **唯一稳定的实现**
//    ② `RepoDetailView.cacheFooter`（详情页右下角，manage / trending 共用）：
//       `arrow.clockwise` + `.symbolEffect(.variableColor.iterative, options: .repeating)` —— 图标不一致，
//       且 `.variableColor` 是"颜色脉动"不是"旋转"，dong4j 反馈"刷新中应该转圈"
//    ③ `TrendingView.RefreshIconButton`（toolbar）：`arrow.clockwise` +
//       `.symbolEffect(.rotate, options: .repeating, value: isRefreshing)` —— 图标不一致；
//       且 `.symbolEffect(.rotate, value:)` 是"value 变化时播一次"语义不是"持续状态"，
//       表现是 isRefreshing=false 时也偶尔在转、isRefreshing=true 时只转一圈就停
//  - 抽成共享组件后，三处统一为同一个图标（`arrow.triangle.2.circlepath` —— 与 GitHub /
//    macOS Finder 同步图标视觉一致）+ 同一套旋转动画（手动 rotation + repeatForever）。
//
//  关键约束（避坑指南）：
//  - **不要**用 `.symbolEffect(.rotate, value:)` —— 行为与 dong4j 期望不符
//  - **不要**用 `.symbolEffect(.variableColor)` 替代旋转 —— 那是颜色脉动效果
//  - 用 `@State rotation: Double` + `.rotationEffect(.degrees(rotation))` 是 SidebarSyncButton
//    已经在生产环境验证稳定的方式，本组件直接照搬
//  - 静止时（isRefreshing=false）`rotation` 停在 0，**不会**有任何残留动画
//  - isRefreshing 从 true → false 时用 `.easeOut(0.2)` 平滑回正，避免突然跳变
//  - 默认 hover 反馈用 `.pressableHover()`（与项目其他可点击元素一致）
//
//  使用范围（截至 2026-06-02）：
//  - `TrendingView.toolbarView` 的刷新按钮
//  - `RepoDetailView.ReadmeStateView.cacheFooter` 的右下角刷新按钮（manage + trending 共用）
//
//  暂未替换（surgical changes 原则）：
//  - `SidebarView.SidebarSyncButton` —— 它有"hover 时变 xmark.circle.fill 取消同步"
//    + 三态 icon（syncing / rateLimited / idle）等特殊行为，强行抽象会丢失能力。
//    若后续要统一可加 `cancelIconOnHover` / `customIcon(for: state)` 等参数。
//

import SwiftUI

/// 通用同步/刷新图标按钮。
///
/// 行为：
/// - 静止时（`isRefreshing == false`）：图标静止不转
/// - 刷新中（`isRefreshing == true`）：图标持续旋转（线性，1 秒/圈）
/// - 状态切换：`true → false` 时用 0.2s easeOut 平滑回正到 0°，避免突然跳变
///
/// 自动尊重 `accessibilityReduceMotion`：
/// - reduceMotion 开启时旋转改为"瞬切到 360°"再瞬切回 0，仍提供视觉反馈但无连续动画
/// - 与项目其他动画 modifier 行为一致（详见 `PressableHover` 同款约定）
struct SyncIconButton: View {

    // MARK: - 公开参数

    /// 是否正在刷新中。true → 图标旋转；false → 图标静止。
    let isRefreshing: Bool

    /// 是否禁用按钮（如 `isRefreshing || isLoading` 期间不接受额外点击）。
    let disabled: Bool

    /// 字号（默认 `.caption`，与"全部 Stars"右侧 `SidebarSyncButton` 视觉权重对齐）。
    /// cacheFooter 这种内部都是 `.caption2` 的语境可显式传 `.caption2` 保持局部一致。
    let font: Font

    /// 图标尺寸框架（默认 18×18pt，与 `SidebarSyncButton` 同款）。
    /// 这个尺寸是项目里所有"刷新/同步图标按钮"的统一基准——2026-06-02 dong4j 反馈
    /// "Trending toolbar 那个大一圈"后定下：原 22×22 + 13pt medium 比其他两处大一圈
    /// 视觉割裂，统一收口到 18×18 + .caption。
    let frameSize: CGFloat

    /// hover tooltip 文本。直接传 `String`（已本地化），便于 caller 处理状态相关文案。
    let tooltip: String

    /// 点击回调。
    let action: () -> Void

    // MARK: - 内部状态

    @State private var rotation: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Init（带默认值，常用场景一行调用）

    init(
        isRefreshing: Bool,
        disabled: Bool = false,
        font: Font = .caption,
        frameSize: CGFloat = 18,
        tooltip: String,
        action: @escaping () -> Void
    ) {
        self.isRefreshing = isRefreshing
        self.disabled = disabled
        self.font = font
        self.frameSize = frameSize
        self.tooltip = tooltip
        self.action = action
    }

    // MARK: - body

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(font)
                .foregroundStyle(isRefreshing ? Color.accentColor : Color.secondary)
                .rotationEffect(.degrees(rotation))
                .frame(width: frameSize, height: frameSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .disabled(disabled)
        .help(tooltip)
        .onAppear {
            updateRotation(isRefreshing: isRefreshing)
        }
        .onChange(of: isRefreshing) { _, newValue in
            updateRotation(isRefreshing: newValue)
        }
    }

    // MARK: - 旋转控制（核心逻辑，与 SidebarSyncButton.updateRotation 行为一致）

    private func updateRotation(isRefreshing: Bool) {
        if isRefreshing {
            // 启动连续旋转：linear + repeatForever，1 秒一圈
            // reduceMotion 用户：瞬切到 360° 再回 0（仍提供"刷新中"的视觉反馈但无持续动画）
            if reduceMotion {
                rotation = 360
            } else {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        } else {
            // 停止旋转：0.2s easeOut 平滑回 0°
            // reduceMotion 用户：瞬切回 0
            if reduceMotion {
                rotation = 0
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    rotation = 0
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("SyncIconButton 演示") {
    VStack(spacing: 20) {
        Text("默认 18×18 + .caption（与 SidebarSyncButton + Trending toolbar 同款）")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack(spacing: 30) {
            SyncIconButton(
                isRefreshing: false,
                tooltip: "静止"
            ) {}
            SyncIconButton(
                isRefreshing: true,
                tooltip: "刷新中"
            ) {}
            SyncIconButton(
                isRefreshing: false,
                disabled: true,
                tooltip: "禁用"
            ) {}
        }

        Divider()

        Text("18×18 + .caption2（cacheFooter 用，与内部其他 caption2 元素对齐）")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack(spacing: 30) {
            SyncIconButton(
                isRefreshing: false,
                font: .caption2,
                tooltip: "刷新 README"
            ) {}
            SyncIconButton(
                isRefreshing: true,
                font: .caption2,
                tooltip: "刷新中"
            ) {}
        }
    }
    .padding(40)
}
