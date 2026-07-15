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

struct RAGContextUsageButton: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let usage: RAGContextUsage
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            // 输入条附属指示器，保持比模型选择器更克制；过大易抢视觉权重。
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: usage.usageRatio)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((usage.usageRatio * 100).rounded()))")
                    .font(.system(size: 8 * interfaceScale.multiplier, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(width: 18, height: 18)
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
    @Environment(\.locale) private var locale

    let usage: RAGContextUsage

    /// 只列出已装进 Prompt 的输入分段；故意跳过 reservedOutput。
    private var activeSegments: [RAGContextUsageSegmentKind] {
        RAGContextUsageSegmentKind.allCases.filter {
            $0 != .reservedOutput && usage.tokenCount(for: $0) > 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 与 Inspector「上下文预算」planSection 同款前缀图标，便于两处扫读时建立视觉关联。
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(iconFont(size: 12, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text("rag.workspace.context.title")
                    .font(ragFont(.callout, scale: interfaceScale, weight: .semibold))
                    .foregroundStyle(.primary)
            }

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
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(segmentColor(kind))
                            .frame(width: 10, height: 10)
                        // displayKey 是 String，必须包成 LocalizedStringKey，否则会当原文画出 key。
                        Text(LocalizedStringKey(kind.displayKey))
                            .font(ragFont(.caption, scale: interfaceScale))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(tokenText(usage.tokenCount(for: kind)))
                            .font(ragFont(.caption, scale: interfaceScale).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320 * interfaceScale.multiplier)
        .focusEffectDisabled()
    }

    /// 整窗宽为 Context Window；已用输入分段按 token 比例着色，剩余留灰轨。
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
                            .fill(segmentColor(kind))
                            .frame(width: width)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("rag.workspace.context.title"))
        .accessibilityValue(Text(percentFullText))
    }

    private var percentFullText: String {
        let percent = Int((usage.usageRatio * 100).rounded())
        return String(format: String.l10n("rag.workspace.context.percentFull"), locale: locale, percent)
    }

    private var tokensSummaryText: String {
        String(
            format: String.l10n("rag.workspace.context.tokensSummary"),
            locale: locale,
            tokenText(usage.inputTokens),
            tokenText(usage.windowTokens)
        )
    }

    private func tokenText(_ tokens: Int) -> String {
        if tokens >= 1_000 {
            let value = Double(tokens) / 1_000
            return value.formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + "K"
        }
        return "\(tokens)"
    }

    /// 分段色与进度条色块一一对应；用系统语义色适配明暗主题。
    private func segmentColor(_ kind: RAGContextUsageSegmentKind) -> Color {
        switch kind {
        case .system: return Color(nsColor: .systemGray)
        case .historySummary: return Color(nsColor: .systemGreen)
        case .recentMessages: return Color(nsColor: .systemOrange)
        case .question: return Color(nsColor: .systemBlue)
        case .evidence: return Color(nsColor: .systemPurple)
        case .remoteContext: return Color(nsColor: .systemPink)
        case .attachments: return Color(nsColor: .systemYellow)
        case .reservedOutput: return Color(nsColor: .systemTeal) // UI 已过滤，保留穷尽分支
        }
    }
}
