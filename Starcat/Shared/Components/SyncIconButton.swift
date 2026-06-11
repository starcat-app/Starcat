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
//  2026-06-11 dong4j 反馈「weekly 板块刷新按钮没转圈」根因 + 修复：
//  - 表象：weekly 列表上方的 SyncIconButton 点击后没有可见的旋转动画
//  - 根因：本地后端响应极快（1-6ms），加上 JSON 解码 + UI 更新整个 reload() 全程
//    20-50ms，`isLoading=true` 状态在屏幕上停留不到 2 帧（< 33ms），人眼根本看不到旋转
//  - 反观 SidebarSyncButton 转得明显是因为 GitHub 全量同步要几秒到几十秒
//  - 修复（本次）：加 `minVisibleDuration` 参数（默认 600ms）+ 内部 `enforcedRefreshing`
//    状态机。一旦 isRefreshing 触发 true，无论数据多快返回都至少持续旋转 minVisibleDuration，
//    给用户明确「我点了 + 它在做事」的反馈。属于行业常规做法（iOS UIRefreshControl 同款）。
//  - 所有现有调用方零改动直接受益（默认值），需要立即停止旋转的特殊场景可显式传 0。
//

import SwiftUI

/// 通用同步/刷新图标按钮。
///
/// 行为：
/// - 静止时（`isRefreshing == false`）：图标静止不转
/// - 刷新中（`isRefreshing == true`）：图标持续旋转（线性，1 秒/圈）
/// - 状态切换：`true → false` 时用 0.2s easeOut 平滑回正到 0°，避免突然跳变
/// - **最短可见时长**（R-04 2026-06-11）：即便 `isRefreshing` 闪一下立即变 false（典型：
///   本地后端 5ms 返回），按钮仍至少持续旋转 `minVisibleDuration`（默认 600ms），
///   保证用户看到「按了 + 在做事」的视觉反馈。详见 `enforcedRefreshing` 状态机。
///
/// 自动尊重 `accessibilityReduceMotion`：
/// - reduceMotion 开启时旋转改为"瞬切到 360°"再瞬切回 0，仍提供视觉反馈但无连续动画
/// - 与项目其他动画 modifier 行为一致（详见 `PressableHover` 同款约定）
struct SyncIconButton: View {

    // MARK: - 公开参数

    /// 是否正在刷新中。true → 图标旋转；false → 图标静止。
    ///
    /// **注意**（R-04 2026-06-11）：实际旋转时长 = max(外部 isRefreshing 持续时间, `minVisibleDuration`)。
    /// 即便 caller 只让 isRefreshing=true 持续 5ms，按钮也会强制旋转至少 minVisibleDuration。
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

    /// **最短可见旋转时长**（R-04 2026-06-11 dong4j 反馈）。
    ///
    /// 即使 `isRefreshing` 极快变 false（本地后端 5ms 返回这种），按钮也保证至少持续旋转
    /// 这么久。给用户「我点了 + 它在做事」的明确反馈，避免"按了好像没反应"的错觉。
    ///
    /// 默认 600ms（视觉上恰好能感受到旋转节奏，又不显得故意拖时间）。
    /// 如果调用方明确不需要（已自己保证最短可见性），可传 0 关闭本机制。
    /// 行业常规做法（iOS UIRefreshControl / 各种 PullToRefresh 都有类似约定）。
    let minVisibleDuration: TimeInterval

    /// hover tooltip 文本。直接传 `String`（已本地化），便于 caller 处理状态相关文案。
    let tooltip: String

    /// 点击回调。
    let action: () -> Void

    // MARK: - 内部状态

    @State private var rotation: Double = 0

    /// **强制旋转状态**（R-04 2026-06-11 最短可见时长机制）。
    /// 与 `isRefreshing` 的关系：
    /// - `isRefreshing=true` → `enforcedRefreshing` 立即 true，记 `enforcedStartedAt`
    /// - `isRefreshing=false` → 延迟到 `enforcedStartedAt + minVisibleDuration` 才 false
    /// - 视图层旋转动画绑定 **enforcedRefreshing**（而非 isRefreshing），让最短可见时长生效
    @State private var enforcedRefreshing: Bool = false
    @State private var enforcedStartedAt: Date?
    @State private var stopTask: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Init（带默认值，常用场景一行调用）

    init(
        isRefreshing: Bool,
        disabled: Bool = false,
        font: Font = .caption,
        frameSize: CGFloat = 18,
        minVisibleDuration: TimeInterval = 0.6,
        tooltip: String,
        action: @escaping () -> Void
    ) {
        self.isRefreshing = isRefreshing
        self.disabled = disabled
        self.font = font
        self.frameSize = frameSize
        self.minVisibleDuration = minVisibleDuration
        self.tooltip = tooltip
        self.action = action
    }

    // MARK: - body

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(font)
                .foregroundStyle(enforcedRefreshing ? Color.accentColor : Color.secondary)
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
            syncEnforcedState(isRefreshing: isRefreshing)
        }
        .onChange(of: isRefreshing) { _, newValue in
            syncEnforcedState(isRefreshing: newValue)
        }
        .onChange(of: enforcedRefreshing) { _, newValue in
            updateRotation(isRefreshing: newValue)
        }
    }

    // MARK: - 最短可见时长状态机（R-04 核心）

    /// 把外部 `isRefreshing` 翻译为内部 `enforcedRefreshing`：
    /// - true → 立即同步并记起始时间；取消任何 pending 的 stop task
    /// - false → 如果已转够 minVisibleDuration 立即停；否则启动 task 延迟到满足
    ///
    /// 重复触发安全：每次都 cancel 上一个 stopTask，避免状态机错乱。
    /// minVisibleDuration <= 0 → 直接透传 isRefreshing（关闭本机制，给特殊场景兜底）。
    private func syncEnforcedState(isRefreshing: Bool) {
        if minVisibleDuration <= 0 {
            stopTask?.cancel()
            stopTask = nil
            if enforcedRefreshing != isRefreshing {
                enforcedRefreshing = isRefreshing
                enforcedStartedAt = isRefreshing ? Date() : nil
            }
            return
        }

        if isRefreshing {
            stopTask?.cancel()
            stopTask = nil
            if !enforcedRefreshing {
                enforcedRefreshing = true
                enforcedStartedAt = Date()
            }
            return
        }

        guard enforcedRefreshing else { return } // 本来就没转，no-op
        let elapsed = enforcedStartedAt.map { Date().timeIntervalSince($0) } ?? minVisibleDuration
        let remaining = max(0, minVisibleDuration - elapsed)

        stopTask?.cancel()
        if remaining <= 0 {
            enforcedRefreshing = false
            enforcedStartedAt = nil
            return
        }
        // 还差 remaining 秒才到最短可见时长——挂个定时器到点再停
        stopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // 期间外部又触发了 true？跳过停止（onChange 会再来一遍）
            guard !self.isRefreshing else { return }
            self.enforcedRefreshing = false
            self.enforcedStartedAt = nil
        }
    }

    // MARK: - 旋转控制（与 SidebarSyncButton.updateRotation 行为一致）

    /// 由 `enforcedRefreshing` 驱动（而非 isRefreshing），caller 闪烁 isRefreshing
    /// 时按钮仍能完整转完最短可见时长。
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

        Divider()

        // R-04 最短可见时长验证（dong4j 2026-06-11 反馈本地 5ms 返回看不到旋转）：
        // 点击下面三个按钮模拟「isRefreshing 极快闪烁」场景，验证 minVisibleDuration 生效。
        Text("R-04：模拟「闪烁 5ms / 50ms / 默认 600ms 兜底」效果")
            .font(.caption)
            .foregroundStyle(.secondary)
        FlashRefreshDemoRow()
    }
    .padding(40)
}

/// Preview 专用：模拟 caller 把 isRefreshing 闪烁 5ms / 50ms 的体验。
/// 即便闪烁时间远小于一帧，按钮仍能完整旋转至少 minVisibleDuration。
private struct FlashRefreshDemoRow: View {
    @State private var flashing5ms: Bool = false
    @State private var flashing50ms: Bool = false
    @State private var flashing600msOff: Bool = false

    var body: some View {
        HStack(spacing: 30) {
            VStack(spacing: 6) {
                SyncIconButton(isRefreshing: flashing5ms, tooltip: "5ms 闪烁") {
                    flashing5ms = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        flashing5ms = false
                    }
                }
                Text("5ms 闪烁").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                SyncIconButton(isRefreshing: flashing50ms, tooltip: "50ms 闪烁") {
                    flashing50ms = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        flashing50ms = false
                    }
                }
                Text("50ms 闪烁").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                SyncIconButton(
                    isRefreshing: flashing600msOff,
                    minVisibleDuration: 0,
                    tooltip: "关闭最短可见（透传）"
                ) {
                    flashing600msOff = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        flashing600msOff = false
                    }
                }
                Text("min=0 透传").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
