//
//  BatchAIOptionsSheet.swift
//  Starcat
//
//  HOM-52 - 批量整理固定工作区中的启动前配置页。
//
//  模块职责：
//  - 固定生成标签，并让用户选择是否同时生成 AI 摘要。
//  - 摘要开启时，提供仅对本次任务生效的代码上下文与外部搜索子选项。
//  - 让用户决定是否"自动应用推荐标签"+ 设置置信度阈值。
//  - 显示本次将处理的 repo 数量与简单时长估算。
//
//  关键约束：
//  - 生成标签固定开启；autoApply=false 时，建议在进度窗口逐仓展开并人工应用。
//  - 启动按钮在 repo 数为 0 或 AI 配置不可用时禁用，避免误触发。
//
//  UI 设计（2026-06-06 17:51 dong4j 反馈"系统 toggle 太丑"重做）：
//  - 抛弃 `Toggle(...).toggleStyle(.switch)`：macOS 26 的系统 switch 颗粒粗、
//    放在小窗口里视觉权重过大，让 sheet 看着像"安卓系统设置"。
//  - 改用 **可点击卡片 + 圆形 checkmark**：整行点击切换，圆形勾选标记替代 toggle，
//    视觉重量更轻。选中态用 tint 淡色背景 + 描边明确反馈。
//  - hover 反馈复用项目共享 `PressableHover`，与详情页可点击元素一致。
//  - 自动应用作为"标签"的子设置：阈值滑条仅在 autoApply 打开时显示，
//    与上方 OptionCard 左右对齐（不再额外缩进，避免
//    左缘错落破坏视觉节奏）。
//

import SwiftUI

struct BatchAIOptionsSheet: View {

    let pendingCount: Int
    let skippedTaggedCount: Int
    @Binding var options: BatchAIQueueOptions
    let canPrepareCodeContext: Bool
    let hasUsableExternalSearchProvider: Bool

    /// 平均每 repo 5-10s（依据 RepoAIInsightService 实测），取中位 8s 给用户一个"约 N 分钟"参考。
    /// 实际进度估算由 BatchAIQueueService.estimatedTimeRemaining 接管。
    private static let avgSecondsPerRepo: Double = 8.0

    /// 2026-06-15:阈值滑杆出/收的 0.18s 动画在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryCards

            HStack(alignment: .top, spacing: 12) {
                actionsPanel
                sessionPanel
            }
            .frame(width: 932, height: 424, alignment: .top)
        }
        .padding(14)
        .frame(width: 960, height: 516, alignment: .topLeading)
    }

    private var summaryCards: some View {
        HStack(spacing: 10) {
            summaryCard(
                title: scopeTitle,
                value: "\(pendingCount)",
                icon: "shippingbox",
                tint: .purple
            )
            summaryCard(
                title: String.l10n("batchAI.generateTags.action.tags"),
                value: "3–8",
                icon: "tag",
                tint: .blue
            )
            summaryCard(
                title: String.l10n("batchAI.options.actionsLabel"),
                value: "\(selectedActionCount)",
                icon: "checklist",
                tint: .green
            )
            summaryCard(
                title: String(format: String.l10n("batchAI.options.estimateFormat"), estimatedMinutes),
                value: "\(estimatedMinutes)",
                icon: "clock",
                tint: .orange
            )
        }
        .frame(width: 932, height: 54)
    }

    private func summaryCard(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: value)
                    .font(.headline.monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 225.5, height: 54, alignment: .leading)
        .background(
            tint.opacity(colorScheme == .dark ? 0.22 : 0.12),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(colorScheme == .dark ? 0.45 : 0.28))
        }
    }

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("batchAI.options.actionsLabel")
                .font(.headline)

            ScrollView {
                VStack(spacing: 8) {
                    OptionCard(
                        icon: "tag",
                        title: "batchAI.generateTags.action.tags",
                        subtitle: "batchAI.generateTags.action.tags.desc",
                        isSelected: true,
                        isDisabled: true,
                        onToggle: {}
                    )
                    autoApplyCard
                    summaryCard
                }
            }
        }
        .padding(12)
        .frame(width: 640, height: 424, alignment: .top)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private var sessionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("githubStarLists.aiGrouping.preflight.session")
                .font(.headline)

            sessionFact(
                title: scopeTitle,
                value: "\(pendingCount)",
                icon: "magnifyingglass"
            )
            sessionFact(
                title: String.l10n("batchAI.options.actionsLabel"),
                value: "\(selectedActionCount)",
                icon: "checklist"
            )
            sessionFact(
                title: String.l10n("batchAI.options.threshold"),
                value: options.autoApplyTags ? percentString(options.confidenceThreshold) : "—",
                icon: "checkmark.seal"
            )

            if skippedTaggedCount > 0 {
                Divider()
                Label {
                    Text(String(
                        format: String.l10n("batchAI.selection.skippedTaggedFormat"),
                        skippedTaggedCount
                    ))
                } icon: {
                    Image(systemName: "tag.slash")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 280, height: 424, alignment: .topLeading)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private func sessionFact(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: value)
                .font(.caption.weight(.semibold).monospacedDigit())
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.secondary.opacity(colorScheme == .dark ? 0.08 : 0.05))
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.secondary.opacity(0.18))
    }

    // MARK: - Summary Card（带本次任务上下文子选项）

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            OptionCard(
                icon: "doc.text",
                title: "batchAI.options.action.summary",
                subtitle: "batchAI.options.action.summary.desc",
                isSelected: options.actions.contains(.summary),
                onToggle: { toggleAction(.summary) }
            )

            if options.actions.contains(.summary) {
                VStack(spacing: 6) {
                    OptionCard(
                        icon: "chevron.left.forwardslash.chevron.right",
                        title: "ai.assistant.summary.options.codeContext.title",
                        subtitle: "ai.assistant.summary.options.codeContext.subtitle",
                        isSelected: options.codeContextEnabledOverride == true,
                        isDisabled: !canPrepareCodeContext,
                        isNested: true,
                        onToggle: {
                            options.codeContextEnabledOverride = !(options.codeContextEnabledOverride ?? false)
                        }
                    )
                    OptionCard(
                        icon: "network",
                        title: "ai.assistant.summary.options.externalSearch.title",
                        subtitle: hasUsableExternalSearchProvider
                            ? "ai.assistant.summary.options.externalSearch.subtitle"
                            : "ai.assistant.summary.options.externalSearch.unavailable",
                        isSelected: options.externalContextEnabledOverride == true,
                        isDisabled: !hasUsableExternalSearchProvider,
                        isNested: true,
                        onToggle: {
                            options.externalContextEnabledOverride = !(options.externalContextEnabledOverride ?? false)
                        }
                    )
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: options.actions.contains(.summary))
    }

    // MARK: - Auto-apply Card（带子设置：阈值滑条）

    private var autoApplyCard: some View {
        return VStack(alignment: .leading, spacing: 10) {
            OptionCard(
                icon: "checkmark.seal",
                title: "batchAI.options.autoApply",
                subtitle: "batchAI.options.autoApply.desc",
                isSelected: options.autoApplyTags,
                onToggle: {
                    options.autoApplyTags.toggle()
                }
            )

            if options.autoApplyTags {
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

    // MARK: - 辅助

    private var selectedActionCount: Int {
        1 + (options.autoApplyTags ? 1 : 0) + (options.actions.contains(.summary) ? 1 : 0)
    }

    private var estimatedMinutes: Int {
        let seconds = Double(pendingCount) * Self.avgSecondsPerRepo
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    private var scopeTitle: String {
        String.l10n("githubStarLists.aiGrouping.preflight.toAnalyze")
    }

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
/// - disabled：保留选中态视觉但不响应点击，用于表达“生成标签”为必选项
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
    var isNested: Bool = false
    let onToggle: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.starcatReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: isNested ? 10 : 12) {
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
            .padding(isNested ? 9 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(cardBackground)
            .overlay(cardBorder)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isDisabled)
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
        .frame(width: isNested ? 24 : 28, height: isNested ? 24 : 28)
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
