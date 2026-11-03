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
//  - 常规任务在 AI 配置不可用时禁用；空标签库会切到纯本地体系引导，不要求 AI Key。
//
//  展示约束：四项操作按设计图平铺；代码上下文和外部搜索仍依赖摘要，不能因平铺解除门控。
//  自动应用属于结果处理策略，不计入 AI 操作数量；重置只恢复打开本页时的配置快照。
//

import SwiftUI

struct BatchAIOptionsSheet: View {

    let pendingCount: Int
    let skippedTaggedCount: Int
    @Binding var options: BatchAIQueueOptions
    let canPrepareCodeContext: Bool
    let hasUsableExternalSearchProvider: Bool
    let requiresTaxonomyBootstrap: Bool

    /// 平均每 repo 5-10s（依据 RepoAIInsightService 实测），取中位 8s 给用户一个"约 N 分钟"参考。
    /// 实际进度估算由 BatchAIQueueService.estimatedTimeRemaining 接管。
    private static let avgSecondsPerRepo: Double = 8.0

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Environment(AppSettings.self) private var settings
    @State private var initialOptions: BatchAIQueueOptions?
    @State private var initialTagCounts: (minimum: Int, maximum: Int)?

    private var tagSuggestionRangeText: String {
        AITagSuggestionCountPolicy.displayRange(
            minimum: settings.aiTagSuggestionMinCount,
            maximum: settings.aiTagSuggestionMaxCount
        )
    }

    private var tagsActionDescription: String {
        String(
            format: String.l10n("batchAI.generateTags.action.tags.descFormat"),
            locale: locale,
            settings.clampedAITagSuggestionCounts.minimum,
            settings.clampedAITagSuggestionCounts.maximum
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AIOrganizationLayout.gap) {
            summaryCards

            HStack(alignment: .top, spacing: AIOrganizationLayout.gap) {
                actionsPanel
                sessionPanel
            }
            .frame(width: AIOrganizationLayout.innerWidth, height: AIOrganizationLayout.panelHeight, alignment: .top)
        }
        .padding(AIOrganizationLayout.padding)
        .frame(width: AIOrganizationLayout.windowSize.width, height: AIOrganizationLayout.contentHeight, alignment: .topLeading)
    }

    private var summaryCards: some View {
        HStack(spacing: 8) {
            summaryCard(
                title: scopeTitle,
                value: pendingCount.formatted(.number.locale(locale)),
                icon: "shippingbox",
                tint: .purple
            )
            summaryCard(
                title: String.l10n("batchAI.generateTags.action.tags"),
                value: tagSuggestionRangeText,
                icon: "tag",
                tint: .blue
            )
            summaryCard(
                title: String.l10n("batchAI.options.selectedActions"),
                value: selectedActionCount.formatted(.number.locale(locale)),
                icon: "checklist",
                tint: .green
            )
            summaryCard(
                title: requiresTaxonomyBootstrap
                    ? String.l10n("batchAI.taxonomy.metric.mode")
                    : String.l10n("batchAI.options.estimatedTime"),
                value: requiresTaxonomyBootstrap
                    ? String.l10n("search.footer.source.local")
                    : String(format: String.l10n("batchAI.options.estimatedMinutesFormat"), locale: locale, estimatedMinutes),
                icon: requiresTaxonomyBootstrap ? "desktopcomputer" : "clock",
                tint: .orange
            )
        }
        .frame(width: AIOrganizationLayout.innerWidth, height: AIOrganizationLayout.summaryHeight)
    }

    private func summaryCard(title: String, value: String, icon: String, tint: Color) -> some View {
        AIOrganizationSummaryCard(title: title, value: value, symbol: icon, tint: tint)
    }

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("batchAI.options.actionsLabel")
                .font(interfaceScale.font(.body, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 8) {
                    OptionCard(
                        icon: "tag",
                        tint: .blue,
                        title: "batchAI.generateTags.action.tags",
                        subtitle: tagsActionDescription,
                        // 与 options.actions 对齐；写死 true 会掩盖「标签未进 actions」的预检异常。
                        isSelected: options.actions.contains(.tags),
                        isDisabled: true,
                        onToggle: {}
                    )
                    summaryCard
                }
            }
        }
        .padding(10)
        .frame(width: AIOrganizationLayout.leadingPanelWidth, height: AIOrganizationLayout.panelHeight, alignment: .top)
        .background(panelBackground)
        .overlay(panelBorder)
        .onAppear(perform: prepareForPresentation)
    }

    private var sessionPanel: some View {
        ScrollView {
            sessionContents
        }
        .padding(10)
        .frame(width: AIOrganizationLayout.sessionPanelWidth, height: AIOrganizationLayout.panelHeight, alignment: .topLeading)
        .background(panelBackground)
        .overlay(panelBorder)
    }

    /// 长翻译、大字号或附加提示在右栏内滚动，不再把固定窗口内容裁掉。
    private var sessionContents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("githubStarLists.aiGrouping.preflight.session")
                    .font(interfaceScale.font(.body, weight: .semibold))
                Spacer(minLength: 4)
                ResetIconButton(help: Text("settings.general.reset"), font: interfaceScale.font(.iconMedium)) {
                    restoreOpeningOptions()
                }
            }
            sessionFact(
                title: scopeTitle,
                value: pendingCount.formatted(.number.locale(locale)),
                icon: "magnifyingglass"
            )
            tagSuggestionCountEditor
            sessionFact(
                title: String.l10n("batchAI.options.selectedActions"),
                value: selectedActionCount.formatted(.number.locale(locale)),
                icon: "checklist"
            )
            sessionFact(
                title: requiresTaxonomyBootstrap
                    ? String.l10n("batchAI.taxonomy.metric.mode")
                    : String.l10n("batchAI.options.estimatedTime"),
                value: requiresTaxonomyBootstrap
                    ? String.l10n("search.footer.source.local")
                    : String(
                        format: String.l10n("batchAI.options.estimatedMinutesFormat"),
                        locale: locale,
                        estimatedMinutes
                    ),
                icon: requiresTaxonomyBootstrap ? "desktopcomputer" : "clock"
            )

            Divider()

            // 自动应用是结果处理策略，不是 AI 要执行的任务；右对齐 Settings 行与 sessionFact 一致。
            CompactSettingsToggleRow(
                title: "batchAI.options.autoApply",
                isOn: $options.autoApplyTags
            )
            .disabled(requiresTaxonomyBootstrap)
            // “允许新增”只打开整批概念发现：Jev 首轮未覆盖的仓库汇总后调用一次 LLM，
            // 候选仍需确认并重新归类，与是否自动应用现有标签正交。
            CompactSettingsToggleRow(
                title: "batchAI.options.allowVocabularyExpansion",
                isOn: $options.autoCreateMissingTags
            )
            .disabled(requiresTaxonomyBootstrap)

            Divider()
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

                if requiresTaxonomyBootstrap {
                    sessionNote(String.l10n("batchAI.taxonomy.summaryAfterSetup"))
                } else if options.autoCreateMissingTags {
                    sessionNote(String.l10n("batchAI.expansion.optionNote"))
                }

                if options.actions.contains(.summary) {
                    sessionNote(String.l10n("batchAI.options.summaryStoredLocallyCompact"))
                }
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(interfaceScale.font(.iconSmall))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(Text(verbatim: title))
            Spacer(minLength: 4)
            Text(verbatim: value)
                .font(interfaceScale.font(.caption).weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    /// 右侧「每仓库标签」区间：短芯片 + popover，即时写回 Settings，与标签分类设置同源。
    private var tagSuggestionCountEditor: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(interfaceScale.font(.iconSmall))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text("settings.autoTidy.tagSuggestionCount")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("settings.autoTidy.tagSuggestionCount")
                .layoutPriority(1)
            Spacer(minLength: 4)
            AITagSuggestionCountRangeControl(
                minimum: settings.aiTagSuggestionMinCount,
                maximum: settings.aiTagSuggestionMaxCount,
                style: .compact
            ) { minimum, maximum in
                settings.applyAITagSuggestionCounts(minimum: minimum, maximum: maximum)
            }
            .layoutPriority(0)
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

    // MARK: - 摘要及其上下文操作

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            OptionCard(
                icon: "doc.text",
                tint: .purple,
                title: "batchAI.options.action.summary",
                subtitle: String.l10n("batchAI.options.action.summary.desc"),
                isSelected: options.actions.contains(.summary),
                isDisabled: requiresTaxonomyBootstrap,
                onToggle: { toggleAction(.summary) }
            )

            // 视觉上与主操作同级；执行上仍是摘要子选项，保持原有启用条件。
            OptionCard(
                icon: "chevron.left.forwardslash.chevron.right",
                tint: .green,
                title: "ai.assistant.summary.options.codeContext.title",
                subtitle: String.l10n("ai.assistant.summary.options.codeContext.subtitle"),
                isSelected: options.actions.contains(.summary)
                    && options.codeContextEnabledOverride == true,
                isDisabled: requiresTaxonomyBootstrap
                    || !options.actions.contains(.summary)
                    || !canPrepareCodeContext,
                onToggle: {
                    options.codeContextEnabledOverride = !(options.codeContextEnabledOverride ?? false)
                }
            )
            OptionCard(
                icon: "globe",
                tint: .orange,
                title: "ai.assistant.summary.options.externalSearch.title",
                subtitle: String.l10n(
                    hasUsableExternalSearchProvider
                        ? "ai.assistant.summary.options.externalSearch.subtitle"
                        : "ai.assistant.summary.options.externalSearch.unavailable"
                ),
                isSelected: options.actions.contains(.summary)
                    && options.externalContextEnabledOverride == true,
                isDisabled: requiresTaxonomyBootstrap
                    || !options.actions.contains(.summary)
                    || !hasUsableExternalSearchProvider,
                onToggle: {
                    options.externalContextEnabledOverride = !(options.externalContextEnabledOverride ?? false)
                }
            )
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
                .disabled(requiresTaxonomyBootstrap || !options.autoApplyTags)

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
        options.selectedOperationStepCount
    }

    private var estimatedMinutes: Int {
        let seconds = Double(pendingCount) * Self.avgSecondsPerRepo
        return max(1, Int((seconds / 60).rounded(.up)))
    }

    private var scopeTitle: String {
        String.l10n("githubStarLists.aiGrouping.preflight.toAnalyze")
    }

    private func toggleAction(_ action: BatchAIAction) {
        // 生成标签是手动批量整理的固定主任务，不允许从 actions 里摘掉。
        guard action != .tags else {
            ensureTagsActionSelected()
            return
        }
        // 显式 copy-assign：Binding 嵌套 Set 的 in-place mutate 在部分宿主下可能丢写回。
        var actions = options.actions
        if actions.contains(action) {
            actions.remove(action)
        } else {
            actions.insert(action)
        }
        actions.insert(.tags)
        options.actions = actions
    }

    /// 打开配置页时保证 `.tags` 在预检集合里，与「标签固定开启」的产品语义一致。
    private func ensureTagsActionSelected() {
        guard !options.actions.contains(.tags) else { return }
        var actions = options.actions
        actions.insert(.tags)
        options.actions = actions
    }

    /// 空词表引导只建立本地标签体系；摘要与自动应用留到体系建立后的常规任务。
    /// 每次进入预检都清理上一轮残留选项，避免界面显示禁用但参数仍为 true。
    private func prepareForPresentation() {
        ensureTagsActionSelected()
        if requiresTaxonomyBootstrap {
            options.actions.remove(.summary)
            options.autoApplyTags = false
            options.autoCreateMissingTags = false
            options.codeContextEnabledOverride = false
            options.externalContextEnabledOverride = false
        }
        if initialOptions == nil {
            initialOptions = options
            initialTagCounts = (
                settings.clampedAITagSuggestionCounts.minimum,
                settings.clampedAITagSuggestionCounts.maximum
            )
        }
    }

    /// 恢复本页打开时的有效选项，不清理词表、不改队列，也不重置其它 AI 设置。
    private func restoreOpeningOptions() {
        if let initialOptions { options = initialOptions }
        if let initialTagCounts {
            settings.applyAITagSuggestionCounts(
                minimum: initialTagCounts.minimum, maximum: initialTagCounts.maximum
            )
        }
    }

    private func percentString(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}

// MARK: - OptionCard

/// 四项操作共用的紧凑整行按钮。颜色标识功能，蓝色边框和方形勾选框表达选择状态；
/// 必选标签即使不可切换也保留清晰选中态，不能灰化成“该功能不可用”。
private struct OptionCard: View {

    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let subtitle: String
    let isSelected: Bool
    var isDisabled: Bool = false
    let onToggle: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 10) {
                iconBadge
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(interfaceScale.font(.bodyEmphasis))
                        .foregroundStyle(.primary)
                    Text(verbatim: subtitle)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                checkmark
            }
            .padding(10)
            .frame(minHeight: 62)
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
        AIOrganizationIconBadge(symbol: icon, tint: tint)
    }

    @ViewBuilder
    private var checkmark: some View {
        if isSelected {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
        } else {
            RoundedRectangle(cornerRadius: 4)
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
