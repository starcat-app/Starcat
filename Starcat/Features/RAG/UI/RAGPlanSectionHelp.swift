//
//  RAGPlanSectionHelp.swift
//  Starcat
//
//  计划 tab 各分组的 info 入口与结构化说明 Popover。
//  文案解释「这一组展示什么 / 数据从哪来」，帮助用户区分 Planner 计划与执行回放。
//

import SwiftUI

/// 计划 Inspector 中可展开说明的分组；与 `planSection` 标题一一对应。
enum RAGPlanSectionHelpTopic: String, Identifiable {
    case questionUnderstanding
    case executionStrategy
    case networkPlan
    case retrievalFunnel
    case contextBudget

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .questionUnderstanding: return "text.magnifyingglass"
        case .executionStrategy: return "slider.horizontal.3"
        case .networkPlan: return "network"
        case .retrievalFunnel: return "line.3.horizontal.decrease.circle.fill"
        case .contextBudget: return "gauge.with.dots.needle.33percent"
        }
    }

    var tint: Color {
        switch self {
        case .questionUnderstanding: return .accentColor
        case .executionStrategy: return .purple
        case .networkPlan: return .cyan
        case .retrievalFunnel: return .orange
        case .contextBudget: return .green
        }
    }

    var openHelpKey: String { "rag.workspace.inspector.plan.help.\(rawValue).open" }
    var titleKey: String { "rag.workspace.inspector.plan.help.\(rawValue).title" }
    var definitionTitleKey: String { "rag.workspace.inspector.plan.help.\(rawValue).definition.title" }
    var definitionBodyKey: String { "rag.workspace.inspector.plan.help.\(rawValue).definition.body" }
    var fieldsTitleKey: String { "rag.workspace.inspector.plan.help.\(rawValue).fields.title" }

    /// 本节常见行含义；按产品展示顺序排列，便于与 Inspector 正文对照。
    var fieldKeys: [String] {
        switch self {
        case .questionUnderstanding:
            return [
                "rag.workspace.inspector.plan.help.questionUnderstanding.field.originalQuestion",
                "rag.workspace.inspector.plan.help.questionUnderstanding.field.semanticQuery",
                "rag.workspace.inspector.plan.help.questionUnderstanding.field.planningNotes",
            ]
        case .executionStrategy:
            return [
                "rag.workspace.inspector.plan.help.executionStrategy.field.mode",
                "rag.workspace.inspector.plan.help.executionStrategy.field.filters",
                "rag.workspace.inspector.plan.help.executionStrategy.field.sort",
                "rag.workspace.inspector.plan.help.executionStrategy.field.candidateLimit",
                "rag.workspace.inspector.plan.help.executionStrategy.field.analytics",
            ]
        case .networkPlan:
            return [
                "rag.workspace.inspector.plan.help.networkPlan.field.liveEvidence",
                "rag.workspace.inspector.plan.help.networkPlan.field.remoteContext",
                "rag.workspace.inspector.plan.help.networkPlan.field.webSearch",
            ]
        case .retrievalFunnel:
            return [
                "rag.workspace.inspector.plan.help.retrievalFunnel.field.candidates",
                "rag.workspace.inspector.plan.help.retrievalFunnel.field.keyword",
                "rag.workspace.inspector.plan.help.retrievalFunnel.field.vector",
                "rag.workspace.inspector.plan.help.retrievalFunnel.field.fusion",
                "rag.workspace.inspector.plan.help.retrievalFunnel.field.rerank",
                "rag.workspace.inspector.plan.help.retrievalFunnel.field.result",
                "rag.workspace.inspector.plan.help.retrievalFunnel.field.outcome",
            ]
        case .contextBudget:
            return [
                "rag.workspace.inspector.plan.help.contextBudget.field.segments",
                "rag.workspace.inspector.plan.help.contextBudget.field.reservedOutput",
                "rag.workspace.inspector.plan.help.contextBudget.field.window",
            ]
        }
    }
}

/// 计划分组标题旁的 info.circle；每个实例独立管理 popover 显隐。
struct RAGPlanSectionInfoButton: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let topic: RAGPlanSectionHelpTopic
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(iconFont(size: 12, scale: interfaceScale, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(LocalizedStringKey(topic.openHelpKey))
        .popover(isPresented: $isPresented, arrowEdge: .leading) {
            RAGPlanSectionHelpPopover(topic: topic)
                .appLocaleEnvironment()
        }
    }
}

/// 结构化说明：定义 → 本节字段 →（上下文预算额外附与 Composer 占用的对比）。
struct RAGPlanSectionHelpPopover: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let topic: RAGPlanSectionHelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                definitionBlock
                fieldsBlock
                if topic == .contextBudget {
                    contextBudgetCompareSection
                    footnote("rag.workspace.context.budget.help.footnote")
                }
            }
            .padding(16)
        }
        .frame(width: 360 * interfaceScale.multiplier, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: topic.systemImage)
                .font(iconFont(size: 12, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(topic.tint)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(topic.titleKey))
                .font(ragFont(.headline, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    private var definitionBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(topic.definitionTitleKey))
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)
            Text(LocalizedStringKey(topic.definitionBodyKey))
                .font(ragFont(.caption, scale: interfaceScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fieldsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(topic.fieldsTitleKey))
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(topic.fieldKeys, id: \.self) { key in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(topic.tint)
                            .padding(.top, 5)
                            .accessibilityHidden(true)
                        Text(LocalizedStringKey(key))
                            .font(ragFont(.caption2, scale: interfaceScale))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var contextBudgetCompareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("rag.workspace.context.budget.help.compare.title")
                .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.primary)

            contextBudgetCompareBlock(
                label: "rag.workspace.context.budget.help.compare.timing.label",
                budget: "rag.workspace.context.budget.help.compare.timing.budget",
                usage: "rag.workspace.context.budget.help.compare.timing.usage"
            )
            contextBudgetCompareBlock(
                label: "rag.workspace.context.budget.help.compare.segments.label",
                budget: "rag.workspace.context.budget.help.compare.segments.budget",
                usage: "rag.workspace.context.budget.help.compare.segments.usage"
            )
            contextBudgetCompareBlock(
                label: "rag.workspace.context.budget.help.compare.purpose.label",
                budget: "rag.workspace.context.budget.help.compare.purpose.budget",
                usage: "rag.workspace.context.budget.help.compare.purpose.usage"
            )
        }
    }

    private func contextBudgetCompareBlock(
        label: LocalizedStringKey,
        budget: LocalizedStringKey,
        usage: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(ragFont(.caption2, scale: interfaceScale, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                contextBudgetCompareColumn(
                    title: "rag.workspace.context.budget.help.compare.budget",
                    body: budget,
                    tint: .green
                )
                contextBudgetCompareColumn(
                    title: "rag.workspace.context.budget.help.compare.usage",
                    body: usage,
                    tint: .accentColor
                )
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func contextBudgetCompareColumn(
        title: LocalizedStringKey,
        body: LocalizedStringKey,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(ragFont(.caption2, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Text(body)
                .font(ragFont(.caption2, scale: interfaceScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func footnote(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(ragFont(.caption2, scale: interfaceScale))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
