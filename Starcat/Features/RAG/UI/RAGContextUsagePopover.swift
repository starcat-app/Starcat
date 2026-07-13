//
//  RAGContextUsagePopover.swift
//  Starcat
//
//  Composer 的 Context Window 占用入口与明细 Popover。
//
//  显示的是 `KnowledgeRAGPromptBuilder` 给出的同一份预算快照，而不是根据 UI 状态另算，
//  因此用户看到的用量、输出预留与实际模型请求保持一致。
//

import SwiftUI

struct RAGContextUsageButton: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let usage: RAGContextUsage
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: usage.usageRatio)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((usage.usageRatio * 100).rounded()))")
                    .font(ragFont(.caption2, scale: interfaceScale, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("rag.workspace.context.open")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            RAGContextUsagePopover(usage: usage)
        }
    }
}

struct RAGContextUsagePopover: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let usage: RAGContextUsage
    @State private var isPromptPreviewExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("rag.workspace.context.title")
                    .font(ragFont(.callout, scale: interfaceScale, weight: .semibold))
                Spacer()
                Text(tokenText(usage.usedTokens) + " / " + tokenText(usage.windowTokens))
                    .font(ragFont(.caption, scale: interfaceScale).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: usage.usageRatio)
                .tint(Color.accentColor)

            VStack(spacing: 7) {
                ForEach(RAGContextUsageSegmentKind.allCases) { kind in
                    let tokens = usage.tokenCount(for: kind)
                    if tokens > 0 {
                        HStack(spacing: 8) {
                            Text(kind.displayKey)
                                .font(ragFont(.caption, scale: interfaceScale))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(tokenText(tokens))
                                .font(ragFont(.caption, scale: interfaceScale).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()
            DisclosureGroup("rag.workspace.context.promptPreview", isExpanded: $isPromptPreviewExpanded) {
                ScrollView {
                    Text(usage.promptPreview.isEmpty ? String.l10n("rag.workspace.context.emptyPreview") : usage.promptPreview)
                        .font(.system(size: 11 * interfaceScale.multiplier, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180 * interfaceScale.multiplier)
                .padding(.top, 6)
            }
            .font(ragFont(.caption, scale: interfaceScale))
        }
        .padding(16)
        .frame(width: 360 * interfaceScale.multiplier)
        .focusEffectDisabled()
    }

    private func tokenText(_ tokens: Int) -> String {
        tokens >= 1_000
            ? "\((Double(tokens) / 1_000).formatted(.number.precision(.fractionLength(1))))K"
            : "\(tokens)"
    }
}
