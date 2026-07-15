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
    /// 从提交问题到最后一个 LLM 响应结束的耗时；运行中持续刷新，历史回答保持冻结值。
    let processingDuration: TimeInterval?
    let suggestedActions: [RAGSuggestedQuestionAction]
    let onSelectCitation: (RAGCitation) -> Void
    let onSuggestedAction: (RAGSuggestedQuestionAction) -> Void
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
                if let processingDuration {
                    RAGProcessingDurationLabel(duration: processingDuration)
                }
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
                RAGStableStoredMarkdown(content: content, citations: citations)
                    .equatable()
                    .frame(maxWidth: 900, alignment: .leading)
            }

            if !content.isEmpty, !citations.isEmpty {
                RAGCitationChipsRow(
                    citations: citations,
                    onSelectCitation: onSelectCitation
                )
            }

            if !suggestedActions.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("rag.workspace.guidance.suggestedTitle")
                        .font(interfaceScale.font(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(suggestedActions) { action in
                        Button(action.question) { onSuggestedAction(action) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
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

/// 已落库正文不会随另一条回答的 token 改变。用 Equatable 边界阻止父时间线的流式状态
/// 让历史 MarkdownUI AST 反复重建；字号环境变化仍会使 SwiftUI 正常刷新该子树。
private struct RAGStableStoredMarkdown: View, Equatable {
    let content: String
    let citations: [RAGCitation]

    var body: some View {
        RAGMarkdownText(content: content, citations: citations)
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
    let processingDuration: TimeInterval?

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
                if let processingDuration {
                    RAGProcessingDurationLabel(duration: processingDuration)
                }
                Spacer(minLength: 0)
            }

            if !preparationSteps.isEmpty {
                RAGExecutionTimeline(steps: preparationSteps)
            }

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
                // 这里不能启用 textSelection：macOS 会为每次变化重建 SelectionOverlay，
                // 长回答可能把 SwiftUI 主线程拖入 AttributeGraph livelock。完成态仍可整条复制。
                Text(snapshot.liveTail)
                    .font(interfaceScale.font(RAGConversationTypography.text, weight: .regular))
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

/// RAG 计时标签统一按分:秒显示，避免长任务在消息头中挤占回答阅读宽度。
private struct RAGProcessingDurationLabel: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 3) {
            Text("rag.workspace.message.processingDuration")
            Text(verbatim: RAGProcessingDurationFormatter.string(for: duration))
        }
        .font(interfaceScale.font(.captionSmall, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

/// 用纯格式化逻辑隔离显示，确保运行中和历史消息对同一秒数给出相同结果。
enum RAGProcessingDurationFormatter {
    static func string(for duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
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
