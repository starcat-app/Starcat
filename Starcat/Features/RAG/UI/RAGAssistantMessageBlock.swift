//
//  RAGAssistantMessageBlock.swift
//  Starcat
//
//  知识库 RAG 助手回答块与悬停操作。
//

import AppKit
import SwiftUI

/// 助手回答块：底部悬停行（左复制/导出，右时间戳）预留占位，避免布局跳动。
/// 复制反馈播放期间强制保持可见，避免鼠标移开后看不到绿色 ✓。
struct RAGAssistantMessageBlock: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    let content: String
    let citations: [RAGCitation]
    let createdAtLabel: String?
    let showsActions: Bool
    /// 执行轨迹属于本轮 assistant 消息，不允许在消息块之外另起视觉容器。
    let executionTrace: [RAGExecutionStep]
    /// 仅用于“正在生成回答”或步骤尚未建立的短暂过渡；回答正文始终不折叠。
    let activityLabel: String?
    let onSelectCitation: (RAGCitation) -> Void
    let onExport: () -> Void

    @State private var isHovered = false
    /// 与 `CopyFeedbackButton` 的 1.5s 反馈窗口对齐：反馈未结束前不因失悬停而隐藏。
    @State private var isCopyFeedbackPinned = false
    @State private var copyFeedbackPinTask: Task<Void, Never>?

    private var areActionsRevealed: Bool {
        isHovered || isCopyFeedbackPinned
    }

    private var preparationSteps: [RAGExecutionStep] {
        // 生成步骤的可见内容就是下方回答正文，不能把正文再包进一个可折叠步骤。
        executionTrace.filter { $0.kind != .generation }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                // AI 侧用 Starcat App Icon，与用户头像同尺寸。
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: RAGMessageAvatarMetrics.size, height: RAGMessageAvatarMetrics.size)
                    .clipShape(RoundedRectangle(cornerRadius: RAGMessageAvatarMetrics.cornerRadius, style: .continuous))
                Text("rag.workspace.message.assistant")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if !preparationSteps.isEmpty {
                RAGExecutionTimeline(steps: preparationSteps)
            }

            if let activityLabel, !activityLabel.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(activityLabel)
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            if !content.isEmpty {
                RAGMarkdownText(content: content, citations: citations)
                    .font(interfaceScale.font(.body))
                    .textSelection(.enabled)
                    .frame(maxWidth: 900, alignment: .leading)
            }

            if !content.isEmpty, !citations.isEmpty {
                RAGCitationChipsRow(
                    citations: citations,
                    onSelectCitation: onSelectCitation
                )
            }

            // 底部悬停行：复制/导出与时间戳紧挨成组（时间在图标右侧），不要 Spacer 拉开。
            if showsActions {
                HStack(spacing: 10) {
                    CopyFeedbackButton(
                        performCopy: {
                            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return false }
                            NSPasteboard.general.clearContents()
                            let ok = NSPasteboard.general.setString(trimmed, forType: .string)
                            if ok { pinActionsForCopyFeedback() }
                            return ok
                        },
                        tooltip: "rag.workspace.answer.copy"
                    ) { didCopy in
                        Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                            .font(interfaceScale.font(size: 12, weight: .medium))
                            .foregroundStyle(didCopy ? Color.green : .secondary)
                            .frame(width: 20, height: 20)
                    }
                    Button(action: onExport) {
                        Image(systemName: "square.and.arrow.up")
                            .font(interfaceScale.font(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("rag.workspace.answer.export")

                    if let createdAtLabel, !createdAtLabel.isEmpty {
                        Text(createdAtLabel)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .opacity(areActionsRevealed ? 1 : 0)
                .allowsHitTesting(areActionsRevealed)
                .accessibilityHidden(!areActionsRevealed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: areActionsRevealed)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard showsActions else { return }
            isHovered = hovering
        }
        .onDisappear {
            copyFeedbackPinTask?.cancel()
            copyFeedbackPinTask = nil
        }
    }

    /// 钉住动作条直到复制反馈结束（与 CopyFeedbackButton 1.5s 窗口一致）。
    private func pinActionsForCopyFeedback() {
        isCopyFeedbackPinned = true
        copyFeedbackPinTask?.cancel()
        copyFeedbackPinTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            isCopyFeedbackPinned = false
        }
    }
}

/// 流式回答专用展示块。
///
/// 已冻结段落通过 Equatable 包装后不再重复解析；尚未闭合的尾部暂以 Text 展示。最终回答
/// 落库后会回到 `RAGAssistantMessageBlock` 的完整 Markdown 与 citation 展示，不改变结果语义。
struct RAGStreamingAssistantMessageBlock: View {
    let snapshot: StreamingMarkdownSnapshot
    let executionTrace: [RAGExecutionStep]
    let activityLabel: String?

    @Environment(\.starcatInterfaceScale) private var interfaceScale

    private var preparationSteps: [RAGExecutionStep] {
        executionTrace.filter { $0.kind != .generation }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: RAGMessageAvatarMetrics.size, height: RAGMessageAvatarMetrics.size)
                    .clipShape(RoundedRectangle(cornerRadius: RAGMessageAvatarMetrics.cornerRadius, style: .continuous))
                Text("rag.workspace.message.assistant")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if !preparationSteps.isEmpty { RAGExecutionTimeline(steps: preparationSteps) }

            if let activityLabel, !activityLabel.isEmpty, snapshot.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(activityLabel)
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(snapshot.stableMarkdownChunks.indices, id: \.self) { index in
                RAGStableStreamingMarkdownChunk(markdown: snapshot.stableMarkdownChunks[index])
                    .equatable()
            }

            if !snapshot.liveTail.isEmpty {
                // 尾部可能仍补全列表、强调或代码围栏；中间态不解析它，保证流式帧率。
                Text(snapshot.liveTail)
                    .font(interfaceScale.font(.body))
                    .textSelection(.enabled)
                    .frame(maxWidth: 900, alignment: .leading)
            }

            if !snapshot.isEmpty, let activityLabel, !activityLabel.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(activityLabel)
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// frozen chunk 输入永不变化，阻止父级 revision 更新时重复构建 MarkdownUI AST。
private struct RAGStableStreamingMarkdownChunk: View, Equatable {
    let markdown: String

    var body: some View {
        RAGMarkdownText(content: markdown)
            .frame(maxWidth: 900, alignment: .leading)
    }
}
