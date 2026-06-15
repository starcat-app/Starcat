//
//  StarStatChipButton.swift
//  Starcat
//
//  R-01「三场景共用架构」详情页 hero stats 行 ⭐/☆ chip 状态机封装。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.1.2 / §3.2.3 / §3.3 / 附录 A 决策矩阵 Q1/N1/N2/Q2）
//  ────────────────────────────────────────────────────────────────────────────
//
//  Star chip 是 R-01 设计里**用户感知最直接**的交互元素：用户在详情页 hero
//  里点一下 ⭐/☆ 触发 star/unstar，所有列表 ✓ 标记同步出现/消失。本组件把
//  设计 §3.2.3 表格规定的 4 个状态机一次封装，避免每个调用方各写一份。
//
//  状态机：
//
//  | 状态 | 视觉 | 触发 |
//  |---|---|---|
//  | 已 star（idle） | ⭐ 实心黄 + 数字 | repo.isStarred == true && !isLoading |
//  | 未 star（idle） | ☆ 空心灰 + 数字 | repo.isStarred == false && !isLoading |
//  | API 进行中 | ProgressView 替代图标 + 数字保留 | 点击后到 await 结束之间 |
//  | API 失败 | chip 抖动 + 短暂红色 600ms | action throws |
//
//  关键约束（设计 §3.2.3）：
//
//  - **API 200 才变 UI**（不做乐观 UI）—— 本组件不假设 action 成功，UI 由外
//    层 Repo / StarredRegistry 变更驱动重渲染；本组件只负责 loading / 失败
//    抖动这种**纯本地**反馈。
//  - **不弹 toast / alert**（Q2 决策）—— 失败仅 chip 抖动 + 短暂红色，调用
//    方 catch 后无需做 UI 反馈，AppLog 记日志即可。
//  - **防双击**（N1 决策）—— 点击立刻 isLoading = true，禁用按钮直到 action
//    返回 / 抛错。
//  - **未登录门控**由调用方在 action 闭包内做（如 authSession.signIn() 后
//    return），本组件不知道登录态。
//
//  调用契约：
//
//  ```swift
//  StarStatChipButton(
//      isStarred: repo.isStarred,
//      count: repo.starsCount,
//      helpKey: repo.isStarred ? "repo.unstar" : "repo.star",
//      action: {
//          guard authSession.state.isAuthenticated else {
//              authSession.signIn()
//              return    // 不抛错，chip 不抖
//          }
//          if repo.isStarred {
//              try await dependencies.starActionService.unstar(repo: repo)
//          } else {
//              _ = try await dependencies.starActionService.star(owner: repo.owner, repo: repo.name)
//          }
//      }
//  )
//  ```
//

import SwiftUI

/// 详情页 hero stats 行 ⭐/☆ chip 按钮。
///
/// 视觉与 `RepoStatItem` 对齐（14pt 图标 + 14pt 数字 monospaced + 10pt label），
/// 但加了 4 状态机：idle / loading / shake / error-flash。
struct StarStatChipButton: View {

    let isStarred: Bool
    let count: Int
    let helpKey: LocalizedStringKey

    /// 点击后执行的异步闭包。
    /// - 抛错 → chip 抖动 + 短暂红色（约 600ms）
    /// - 不抛 → chip 等 action 返回后退出 loading；UI 状态变更由外层数据流驱动
    let action: () async throws -> Void

    /// API 进行中（点击 → action 返回/抛错）。
    /// 期间禁用按钮防双击，图标位置渲染 ProgressView 替代。
    @State private var isLoading: Bool = false

    /// 失败抖动累计触发次数 — 通过 keyframe 把 0→1 的 progress 映射成左右往复偏移。
    @State private var shakeTrigger: Int = 0

    /// 失败短暂红色（600ms 自动复位）。
    @State private var showErrorFlash: Bool = false

    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            tapped()
        } label: {
            chipBody
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .disabled(isLoading)
        .help(helpKey)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var chipBody: some View {
        VStack(alignment: .center, spacing: 2) {
            HStack(spacing: 4) {
                iconOrSpinner
                Text(count, format: .number)
                    .monospacedDigit()
                    .font(.system(size: 14, weight: .medium))
            }
            Text("repo.stars")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(showErrorFlash ? Color.red : Color.primary)
        // 设计 §3.2.3 失败 chip 抖动：仅在 reduceMotion = false 时触发
        // keyframeAnimator 通过 trigger 计数变化驱动一段 ~ 0.45s 横向往复（4 次衰减）
        .modifier(ShakeOnTriggerModifier(trigger: shakeTrigger, reduceMotion: reduceMotion))
    }

    /// 已 star → ⭐ 实心黄；未 star → ☆ 空心灰；loading → ProgressView。
    @ViewBuilder
    private var iconOrSpinner: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        } else if isStarred {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 14))
        } else {
            Image(systemName: "star")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
        }
    }

    private var accessibilityLabel: Text {
        if isStarred {
            Text("repo.unstar")
        } else {
            Text("repo.star")
        }
    }

    /// 点击处理：guard 防双击 → isLoading = true → 执行 action → 失败时抖动 +
    /// 短暂红色（reduceMotion 时跳过抖动只闪红色）。
    private func tapped() {
        guard !isLoading else { return }
        Task { @MainActor in
            isLoading = true
            do {
                try await action()
            } catch {
                triggerFailureFeedback()
                AppLog.sync.error("star chip action failed: \(error.localizedDescription, privacy: .public)")
            }
            isLoading = false
        }
    }

    /// 失败反馈：chip 抖动 + 短暂红色 ~600ms 后自动复位。
    private func triggerFailureFeedback() {
        shakeTrigger &+= 1   // 触发 keyframe，溢出回卷无副作用（动画只看相邻不同值）
        showErrorFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            showErrorFlash = false
        }
    }
}

// MARK: - Shake keyframe modifier

/// 横向往复抖动 modifier（trigger 计数变化时驱动一次 0.45s 衰减抖动）。
///
/// 用 `keyframeAnimator(initialValue:trigger:content:keyframes:)` 而非
/// SwiftUI implicit animation 是为了：① 与 button 主体的 disabled / 颜色
/// flash 这些状态变化解耦，避免它们也跟着抖动 ② keyframes 可精确控制 4 次
/// 衰减弹性，比 .transition 一次性 spring 更接近设计 §3.2.3 "约 600ms" 的
/// 视觉规格。
private struct ShakeOnTriggerModifier: ViewModifier {
    let trigger: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            // 辅助功能场景下不抖，仅靠颜色 flash 反馈
            content
        } else {
            content.keyframeAnimator(
                initialValue: CGFloat(0),
                trigger: trigger
            ) { view, value in
                view.offset(x: value)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0, duration: 0)
                    SpringKeyframe(-6, duration: 0.08)
                    SpringKeyframe(5, duration: 0.08)
                    SpringKeyframe(-3, duration: 0.08)
                    SpringKeyframe(2, duration: 0.08)
                    SpringKeyframe(0, duration: 0.08)
                }
            }
        }
    }
}
