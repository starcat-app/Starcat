//
//  RAGContextUsagePopover.swift
//  Starcat
//
//  Composer 的 Context Window 占用入口与明细 Popover。
//
//  显示的是 `KnowledgeRAGPromptBuilder` 给出的同一份预算快照里的**输入分段**；
//  输出预留只在构建期扣预算，不在此展示，避免「预留回答空间」被读成已消耗内容。
//

import SwiftUI

// MARK: - 分段配色

extension RAGContextUsageSegmentKind {
    /// 分段色与进度条色块一一对应；用系统语义色适配明暗主题。
    var usageSegmentColor: Color {
        switch self {
        case .system: return Color(nsColor: .systemGray)
        case .historySummary: return Color(nsColor: .systemGreen)
        case .recentMessages: return Color(nsColor: .systemOrange)
        case .question: return Color(nsColor: .systemBlue)
        case .evidence: return Color(nsColor: .systemPink)
        case .repoContext: return Color(nsColor: .systemIndigo)
        case .remoteContext: return Color(nsColor: .systemPurple)
        case .attachments: return Color(nsColor: .systemYellow)
        case .reservedOutput: return Color(nsColor: .systemTeal)
        }
    }
}

// MARK: - 分色堆叠条（预算 / 占用共用渲染，语义由外层承载）

/// 上下文预算与上下文占用的展示变体。
/// 两者共用分色堆叠条，但图例样式、是否展示预留输出、无障碍文案不同。
enum RAGContextWindowBreakdownVariant {
    /// Inspector Plan：本轮计划与检索完成后的实际快照，单独列出预留输出。
    case budget
    /// Composer：输入期实时预览，只展示输入分段。
    case usage
}

/// Context Window 分色堆叠条 + 图例。不含标题，由外层 planSection / Popover 提供。
struct RAGContextWindowBreakdownView: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

    let usage: RAGContextUsage
    let variant: RAGContextWindowBreakdownVariant

    /// 只列出已装进 Prompt 的输入分段；预留输出仅在 budget 变体的图例中单独展示。
    private var activeSegments: [RAGContextUsageSegmentKind] {
        RAGContextUsageSegmentKind.allCases.filter {
            $0 != .reservedOutput && usage.tokenCount(for: $0) > 0
        }
    }

    private var showsReservedOutput: Bool {
        variant == .budget
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(percentFullText)
                    .font(ragFont(.caption, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(tokensSummaryText)
                    .font(ragFont(.caption, scale: interfaceScale).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            segmentedUsageBar

            VStack(spacing: 8) {
                ForEach(activeSegments) { kind in
                    segmentLegendRow(kind: kind, tokens: usage.tokenCount(for: kind))
                }
                if showsReservedOutput, usage.reservedOutputTokens > 0 {
                    segmentLegendRow(
                        kind: .reservedOutput,
                        tokens: usage.reservedOutputTokens
                    )
                }
            }
        }
    }

    /// 整窗宽为 Context Window。
    /// - budget：输入分色实块 + 半透明虚线 teal 预留区 + 灰轨剩余空位；占比仍只算输入。
    /// - usage：仅输入分色实块 + 灰轨剩余空位。
    private var segmentedUsageBar: some View {
        GeometryReader { proxy in
            let total = CGFloat(max(usage.windowTokens, 1))
            let spacing: CGFloat = 1.5
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                HStack(spacing: spacing) {
                    ForEach(activeSegments) { kind in
                        let raw = proxy.size.width * CGFloat(usage.tokenCount(for: kind)) / total
                        let width = max(raw, 2)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(kind.usageSegmentColor)
                            .frame(width: width)
                    }
                    if showsReservedOutput, usage.reservedOutputTokens > 0 {
                        let raw = proxy.size.width * CGFloat(usage.reservedOutputTokens) / total
                        reservedOutputBarSegment(width: max(raw, 2))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityTitleKey))
        .accessibilityValue(Text(percentFullText))
    }

    /// 预算横条中的预留输出区：半透明 teal 底 + 虚线描边，与输入实色块区分。
    private func reservedOutputBarSegment(width: CGFloat) -> some View {
        let tint = RAGContextUsageSegmentKind.reservedOutput.usageSegmentColor
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(tint.opacity(0.32))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .frame(width: width)
    }

    /// 图例色块：预留输出用与横条一致的虚线框，输入分段用实心块。
    private func segmentLegendSwatch(for kind: RAGContextUsageSegmentKind) -> some View {
        Group {
            if kind == .reservedOutput, variant == .budget {
                let tint = kind.usageSegmentColor
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(0.32))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(tint.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                    }
            } else {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(kind.usageSegmentColor)
            }
        }
        .frame(width: 10, height: 10)
    }

    private var accessibilityTitleKey: LocalizedStringKey {
        switch variant {
        case .budget: return "rag.workspace.inspector.plan.contextBudget"
        case .usage: return "rag.workspace.context.title"
        }
    }

    private func segmentLegendRow(
        kind: RAGContextUsageSegmentKind,
        tokens: Int
    ) -> some View {
        HStack(spacing: 10) {
            segmentLegendSwatch(for: kind)
            Text(LocalizedStringKey(kind.displayKey))
                .font(ragFont(.caption, scale: interfaceScale))
                .foregroundStyle(variant == .budget ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Self.tokenText(tokens, locale: locale))
                .font(
                    ragFont(
                        .caption,
                        scale: interfaceScale,
                        weight: variant == .budget ? .semibold : .regular
                    )
                    .monospacedDigit()
                )
                .foregroundStyle(variant == .budget ? .primary : .secondary)
        }
    }

    private var percentFullText: String {
        let percent = Int((usage.usageRatio * 100).rounded())
        return String(format: String.l10n("rag.workspace.context.percentFull"), locale: locale, percent)
    }

    private var tokensSummaryText: String {
        String(
            format: String.l10n("rag.workspace.context.tokensSummary"),
            locale: locale,
            Self.tokenText(usage.inputTokens, locale: locale),
            Self.tokenText(usage.windowTokens, locale: locale)
        )
    }

    static func tokenText(_ tokens: Int, locale: Locale) -> String {
        if tokens >= 1_000 {
            let value = Double(tokens) / 1_000
            return value.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + "K"
        }
        return tokens.formatted(.number.locale(locale))
    }
}

// MARK: - Composer 入口

struct RAGContextUsageButton: View {
    let usage: RAGContextUsage
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            // 输入条附属指示器，保持比模型选择器更克制；过大易抢视觉权重。
            // 纯进度环不带数字：底轨用弱化灰，进度弧用 .primary 做黑白主题自适应
            //（浅色黑 / 深色白），避免固定蓝色在某一主题下抢视觉或对比不足。
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: usage.usageRatio)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            // 描边 Circle 只有那圈细线可点，中间是空的（去掉数字后更明显）。
            // 用一个透明矩形把整块区域变成可点热区，并对齐右侧图标按钮的 24×24 尺寸。
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("rag.workspace.context.open")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            // popover 是独立环境树，必须挂 locale，否则 Text("key") 可能退回 key 原文。
            RAGContextUsagePopover(usage: usage)
                .appLocaleEnvironment()
        }
    }
}

struct RAGContextUsagePopover: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let usage: RAGContextUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(iconFont(size: 12, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text("rag.workspace.context.title")
                    .font(ragFont(.callout, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
            }

            RAGContextWindowBreakdownView(usage: usage, variant: .usage)
        }
        .padding(16)
        .frame(width: 320 * interfaceScale.multiplier)
        .focusEffectDisabled()
    }
}
