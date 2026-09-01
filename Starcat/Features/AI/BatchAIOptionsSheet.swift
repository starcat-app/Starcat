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
//  - 自动应用属于结果处理策略，不计入 AI 操作数量；统一放在右侧"本次整理"卡中，
//    使用与 AI 仓库分组相同的紧凑开关、阈值和结果去向说明。
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

    /// 紧凑开关的状态动画在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

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
                .font(interfaceScale.font(.iconMedium, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(verbatim: value)
                    .font(interfaceScale.font(.panelTitle).monospacedDigit())
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
                .font(interfaceScale.font(.panelTitle))

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
        VStack(alignment: .leading, spacing: 8) {
            Text("githubStarLists.aiGrouping.preflight.session")
                .font(interfaceScale.font(.panelTitle))

            sessionFact(
                title: scopeTitle,
                value: pendingCount.formatted(.number.locale(locale)),
                icon: "magnifyingglass"
            )
            sessionFact(
                title: String.l10n("batchAI.options.tagsPerRepository"),
                value: "3–8",
                icon: "tag"
            )
            sessionFact(
                title: String.l10n("batchAI.options.selectedActions"),
                value: selectedActionCount.formatted(.number.locale(locale)),
                icon: "checklist"
            )
            sessionFact(
                title: String.l10n("batchAI.options.estimatedTime"),
                value: String(
                    format: String.l10n("batchAI.options.estimatedMinutesFormat"),
                    locale: locale,
                    estimatedMinutes
                ),
                icon: "clock"
            )

            Divider()

            // 自动应用是结果处理策略，不是 AI 要执行的任务；放在本次整理摘要中，
            // 与仓库分组预检页保持相同的信息层级和紧凑开关样式。
            Toggle(isOn: $options.autoApplyTags) {
                HStack(spacing: 8) {
                    Text("batchAI.options.autoApply")

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(options.autoApplyTags ? Color.accentColor : Color.secondary.opacity(0.36))

                        Circle()
                            .fill(.white)
                            .overlay {
                                Circle()
                                    .stroke(.black.opacity(0.08), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                            .padding(2)
                            .offset(x: options.autoApplyTags ? 20 : 0)
                    }
                    .frame(width: 44, height: 24)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: options.autoApplyTags)
                    .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .font(interfaceScale.font(.caption))

            Toggle(isOn: $options.autoCreateMissingTags) {
                HStack(spacing: 8) {
                    Text("batchAI.options.autoCreateMissingTags")

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(options.autoCreateMissingTags ? Color.accentColor : Color.secondary.opacity(0.36))

                        Circle()
                            .fill(.white)
                            .overlay {
                                Circle()
                                    .stroke(.black.opacity(0.08), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                            .padding(2)
                            .offset(x: options.autoCreateMissingTags ? 20 : 0)
                    }
                    .frame(width: 44, height: 24)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: options.autoCreateMissingTags)
                    .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .font(interfaceScale.font(.caption))
            .padding(.leading, 16)
            .disabled(!options.autoApplyTags)

            // 阈值始终可见，关闭自动应用时只禁用 Slider，避免开关导致卡片内容跳动。
            thresholdSlider

            VStack(alignment: .leading, spacing: 8) {
                if skippedTaggedCount > 0 {
                    sessionNote(String(
                        format: String.l10n("batchAI.selection.skippedTaggedFormat"),
                        locale: locale,
                        skippedTaggedCount
                    ))
                }

                if options.actions.contains(.summary) {
                    sessionNote(String.l10n("batchAI.options.summaryStoredLocallyCompact"))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 280, height: 424, alignment: .topLeading)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    private func sessionNote(_ title: String) -> some View {
        Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(interfaceScale.font(.caption))
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nestedPanelFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sessionFact(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: value)
                .font(interfaceScale.font(.bodyEmphasis).monospacedDigit())
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                colorScheme == .dark
                    ? Color(red: 44 / 255, green: 44 / 255, blue: 46 / 255)
                    : Color(nsColor: .controlBackgroundColor)
            )
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.85 : 0.45))
    }

    private var nestedPanelFill: Color {
        colorScheme == .dark
            ? Color(red: 58 / 255, green: 58 / 255, blue: 60 / 255)
            : Color.primary.opacity(0.04)
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

            // 摘要上下文选项始终展开；摘要未开启时只禁用，不再改变左侧布局高度。
            VStack(spacing: 6) {
                OptionCard(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "ai.assistant.summary.options.codeContext.title",
                    subtitle: "ai.assistant.summary.options.codeContext.subtitle",
                    isSelected: options.actions.contains(.summary)
                        && options.codeContextEnabledOverride == true,
                    isDisabled: !options.actions.contains(.summary) || !canPrepareCodeContext,
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
                    isSelected: options.actions.contains(.summary)
                        && options.externalContextEnabledOverride == true,
                    isDisabled: !options.actions.contains(.summary) || !hasUsableExternalSearchProvider,
                    isNested: true,
                    onToggle: {
                        options.externalContextEnabledOverride = !(options.externalContextEnabledOverride ?? false)
                    }
                )
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var thresholdSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("batchAI.options.threshold")
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: percentString(options.confidenceThreshold))
                    .font(interfaceScale.font(.captionStrong).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .foregroundStyle(.tint)
            }

            Slider(value: $options.confidenceThreshold, in: 0.5...1.0, step: 0.05)
                .controlSize(.mini)
                .tint(.accentColor)
                .disabled(!options.autoApplyTags)

            // 阈值仅控制自动应用；低于阈值的有效建议必须明确告知用户仍需人工确认。
            Text(String(
                format: String.l10n("batchAI.options.autoApplyEnabledCompactFormat"),
                locale: locale,
                percentString(options.confidenceThreshold)
            ))
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 辅助

    private var selectedActionCount: Int {
        // 自动应用只是建议落库策略，不应计入 AI 实际执行的任务数量。
        1 + (options.actions.contains(.summary) ? 1 : 0)
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
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: isNested ? 10 : 12) {
                iconBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(interfaceScale.font(.rowTitle))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(interfaceScale.font(.caption))
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
                .font(interfaceScale.font(.iconMedium, weight: .semibold))
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
