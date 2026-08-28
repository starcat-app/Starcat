//
//  BatchAIOptionsSheet.swift
//  Starcat
//
//  HOM-52 - 批量整理启动前的操作选择 Sheet。
//
//  模块职责：
//  - 让用户选择本次要跑哪些 AI 子任务（摘要 / 标签）。
//  - 让用户决定是否"自动应用推荐标签"+ 设置置信度阈值。
//  - 显示本次将处理的 repo 数量与简单时长估算。
//
//  关键约束：
//  - 默认值与 dong4j 2026-06-06 评审决议一致：actions=[summary,tags]、autoApply=false、threshold=0.90。
//  - 启动按钮在 actions 为空 / repo 数为 0 时禁用，避免误触发。
//
//  UI 设计（2026-06-06 17:51 dong4j 反馈"系统 toggle 太丑"重做）：
//  - 抛弃 `Toggle(...).toggleStyle(.switch)`：macOS 26 的系统 switch 颗粒粗、
//    放在小窗口里视觉权重过大，让 sheet 看着像"安卓系统设置"。
//  - 改用 **可点击卡片 + 圆形 checkmark**：整行点击切换，圆形勾选标记替代 toggle，
//    视觉重量更轻。选中态用 tint 淡色背景 + 描边明确反馈。
//  - hover 反馈复用项目共享 `PressableHover`，与详情页可点击元素一致。
//  - 自动应用作为"标签"的子设置：未选标签时整卡 disabled；阈值滑条仅在
//    autoApply 打开时显示，与上方 OptionCard 左右对齐（不再额外缩进，避免
//    左缘错落破坏视觉节奏）。
//

import SwiftUI

struct BatchAIOptionsSheet: View {

    let pendingCount: Int
    @Binding var options: BatchAIQueueOptions
    let configurationIssue: String?
    let onCancel: () -> Void
    let onStart: () -> Void

    /// 平均每 repo 5-10s（依据 RepoAIInsightService 实测），取中位 8s 给用户一个"约 N 分钟"参考。
    /// 实际进度估算由 BatchAIQueueService.estimatedTimeRemaining 接管。
    private static let avgSecondsPerRepo: Double = 8.0

    /// 2026-06-15:阈值滑杆出/收的 0.18s 动画在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            actionsSection
            autoApplyCard
            if let configurationIssue {
                Label {
                    Text(verbatim: configurationIssue)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
            footer
        }
        .padding(20)
        .frame(width: 480)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.tint.opacity(0.12))
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("batchAI.options.title")
                    .font(.headline)
                Text(String(format: String.l10n("batchAI.options.subtitleFormat"), pendingCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            estimateChip
        }
    }

    private var estimateChip: some View {
        let seconds = Double(pendingCount) * Self.avgSecondsPerRepo
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        return HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption2)
            Text(String(format: String.l10n("batchAI.options.estimateFormat"), minutes))
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    // MARK: - Actions Section（两个操作卡片）

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("batchAI.options.actionsLabel")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 8) {
                OptionCard(
                    icon: "doc.text",
                    title: "batchAI.options.action.summary",
                    subtitle: "batchAI.options.action.summary.desc",
                    isSelected: options.actions.contains(.summary),
                    onToggle: { toggleAction(.summary) }
                )
                OptionCard(
                    icon: "tag",
                    title: "batchAI.options.action.tags",
                    subtitle: "batchAI.options.action.tags.desc",
                    isSelected: options.actions.contains(.tags),
                    onToggle: { toggleAction(.tags) }
                )
            }
        }
    }

    // MARK: - Auto-apply Card（带子设置：阈值滑条）

    private var autoApplyCard: some View {
        let tagsEnabled = options.actions.contains(.tags)

        return VStack(alignment: .leading, spacing: 10) {
            OptionCard(
                icon: "checkmark.seal",
                title: "batchAI.options.autoApply",
                subtitle: "batchAI.options.autoApply.desc",
                isSelected: options.autoApplyTags,
                isDisabled: !tagsEnabled,
                onToggle: {
                    guard tagsEnabled else { return }
                    options.autoApplyTags.toggle()
                }
            )

            if options.autoApplyTags, tagsEnabled {
                thresholdSlider
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: options.autoApplyTags)
    }

    private var thresholdSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("batchAI.options.threshold")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: percentString(options.confidenceThreshold))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }

            Slider(value: $options.confidenceThreshold, in: 0.5...1.0, step: 0.05)
                .controlSize(.mini)
                .tint(.accentColor)

            // 2026-06-14 D-31 follow-up：.tertiary → .secondary。
            // hint 仍需要能读清（百分比阈值是关键提示），与 D-31 全局对比度修正对齐。
            Text(String(format: String.l10n("batchAI.options.threshold.hintFormat"), percentString(options.confidenceThreshold)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        // 2026-06-07 dong4j 反馈：之前 .padding(.leading, 36) 缩进导致与上方
        // OptionCard 左缘不齐，看着像"漏了一块"。改为左右对齐。
        // 父子层级靠"出现时机（autoApply 开了才显示）+ 浅灰圆角背景 + 紧贴上方"
        // 已经能让用户理解依赖关系，不必再靠物理缩进强调。
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("general.cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button {
                onStart()
            } label: {
                Text(String(format: String.l10n("batchAI.options.startFormat"), pendingCount))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!options.isValidForStart || pendingCount == 0 || configurationIssue != nil)
        }
    }

    // MARK: - 辅助

    private func toggleAction(_ action: BatchAIAction) {
        if options.actions.contains(action) {
            options.actions.remove(action)
        } else {
            options.actions.insert(action)
        }
    }

    private func percentString(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}

// MARK: - OptionCard

/// 可点击卡片，代替 system Toggle.switch。
///
/// 视觉规范：
/// - 圆角 10pt、内边距 12pt、最小高度 56pt
/// - 左侧图标固定 28×28 圆角容器，selected 时填充 tint，unselected 时浅灰
/// - 右侧 18pt 圆形 checkmark，selected = tint 实心 + 白勾，unselected = 描边空心圆
/// - 选中态：背景 `tint.opacity(0.08)` + 描边 `tint.opacity(0.35)`
/// - 未选中态：背景透明 + 描边 `secondary.opacity(0.18)`
/// - hover：背景叠加 `secondary.opacity(0.05)`
/// - disabled：整卡 opacity 0.45，不响应点击
///
/// 比起 `.toggleStyle(.switch)` 的好处：
/// - macOS 26 的 system switch 颗粒粗（~30×18pt），三个堆在一起视觉很重；
///   圆形 checkmark 仅 18pt，视觉重量是 switch 的 1/3。
/// - 整卡可点击，命中区域大；用户不必精准点中右侧那个小开关。
/// - 选中态用背景色 + 描边表达，比 switch 的"半截绿条"更明显。
private struct OptionCard: View {

    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let isSelected: Bool
    var isDisabled: Bool = false
    let onToggle: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 12) {
                iconBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                checkmark
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(cardBackground)
            .overlay(cardBorder)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1.0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.12)) {
                isHovered = hovering && !isDisabled
            }
        }
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private var checkmark: some View {
        if isSelected {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.2)
                .frame(width: 18, height: 18)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(
                isSelected
                    ? Color.accentColor.opacity(0.08)
                    : (isHovered ? Color.secondary.opacity(0.06) : Color.clear)
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                isSelected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18),
                lineWidth: 1
            )
    }
}
