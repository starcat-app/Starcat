//
//  RAGExecutionTimeline.swift
//  Starcat
//
//  RAG 回答前后的紧凑步骤轨迹。
//

import SwiftUI

/// RAG 回答前后的紧凑步骤轨迹。
///
/// 当前运行步骤自动展开；前序步骤完成后自动折叠为摘要。用户可重新展开已完成步骤，
/// 但生成回答是最终阅读上下文，始终展开而不会被折叠逻辑收起。该组件只渲染脱敏的
/// `RAGExecutionStep`，不能读取 Debug trace。
struct RAGExecutionTimeline: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    let steps: [RAGExecutionStep]
    @State private var manuallyExpanded: Set<RAGExecutionStepKind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(steps) { step in
                executionStep(step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func executionStep(_ step: RAGExecutionStep) -> some View {
        let isExpanded = step.state == .running
            || manuallyExpanded.contains(step.kind)
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    if isExpanded {
                        manuallyExpanded.remove(step.kind)
                    } else {
                        manuallyExpanded.insert(step.kind)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    stepStatusIcon(step)
                        .frame(width: 15, height: 15)
                    Text(titleKey(for: step.kind))
                        .font(interfaceScale.font(.body, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if !isExpanded, let summary = step.summary, !summary.isEmpty {
                        Text(summary)
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(step.details, id: \.self) { detail in
                        Label(detail, systemImage: "minus")
                            .font(interfaceScale.font(.caption))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    if let summary = step.summary, !summary.isEmpty {
                        Text(summary)
                            .font(interfaceScale.font(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 23)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func stepStatusIcon(_ step: RAGExecutionStep) -> some View {
        if step.state == .running {
            ProgressView()
                .controlSize(.mini)
        } else {
            Image(systemName: step.state == .skipped ? "arrowshape.turn.up.right" : "checkmark.circle.fill")
                .font(interfaceScale.font(size: 14, weight: .semibold))
                .foregroundStyle(step.state == .skipped ? Color.secondary : Color.green)
        }
    }

    private func titleKey(for kind: RAGExecutionStepKind) -> LocalizedStringKey {
        switch kind {
        case .thinking: return "rag.workspace.execution.thinking.title"
        case .retrieval: return "rag.workspace.execution.retrieval.title"
        case .remoteContext: return "rag.workspace.execution.remote.title"
        case .generation: return "rag.workspace.execution.generation.title"
        }
    }
}
