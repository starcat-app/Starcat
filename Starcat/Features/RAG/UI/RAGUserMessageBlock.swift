//
//  RAGUserMessageBlock.swift
//  Starcat
//
//  知识库 RAG 用户消息气泡与编辑交互。
//

import AppKit
import SwiftUI

/// 用户气泡：头像与气泡垂直居中；底部操作为悬停行（左时间戳 / 右复制），预留占位防跳动。
/// 停止且无 AI 输出时，复制（回填输入框）+ 编辑常显，时间戳仍在左侧。
struct RAGUserMessageBlock: View {
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    let message: RAGStoredMessage
    let avatarURL: String?
    let isEditing: Bool
    let showsPendingActions: Bool
    @Binding var editingDraft: String
    let onCopyToComposer: () -> Bool
    let onBeginEdit: () -> Void
    let onCancelEdit: () -> Void
    let onSubmitEdit: () -> Void
    let timeLabel: String

    @State private var isHovered = false
    @State private var isCopyFeedbackPinned = false
    @State private var copyFeedbackPinTask: Task<Void, Never>?

    private var areHoverActionsRevealed: Bool {
        isHovered || isCopyFeedbackPinned
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                if isEditing {
                    HStack(alignment: .center, spacing: 8) {
                        userMessageEditor
                        messageAvatar
                    }
                } else {
                    // 头像只与问题气泡垂直居中，footer 单独铺在气泡下方。
                    HStack(alignment: .center, spacing: 8) {
                        Text(message.content)
                            .font(interfaceScale.font(RAGConversationTypography.text, weight: .regular))
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: 680, alignment: .trailing)
                        messageAvatar
                    }
                    userFooter
                        .frame(maxWidth: 680)
                        // 给右侧头像让出宽度，让时间戳贴齐气泡左缘。
                        .padding(.trailing, RAGMessageAvatarMetrics.size + 8)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard !isEditing, !showsPendingActions else { return }
            isHovered = hovering
        }
        .onDisappear {
            copyFeedbackPinTask?.cancel()
            copyFeedbackPinTask = nil
        }
    }

    private var messageAvatar: some View {
        RemoteAvatar(
            urlString: avatarURL,
            size: RAGMessageAvatarMetrics.size,
            showBorder: false
        )
    }

    private var userMessageEditor: some View {
        VStack(alignment: .trailing, spacing: 10) {
            TextEditor(text: $editingDraft)
                .font(interfaceScale.font(RAGConversationTypography.text, weight: .regular))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 72, maxHeight: 220)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )

            HStack(spacing: 8) {
                Button("rag.workspace.message.editCancel", action: onCancelEdit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("rag.workspace.message.editSend", action: onSubmitEdit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(editingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: 680, alignment: .trailing)
    }

    private var userFooter: some View {
        // 右对齐：时间戳紧挨复制图标左侧，不要被 Spacer 甩到最左边。
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if !timeLabel.isEmpty {
                Text(timeLabel)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }
            if showsPendingActions {
                CopyFeedbackButton(
                    performCopy: {
                        let ok = onCopyToComposer()
                        if ok { pinActionsForCopyFeedback() }
                        return ok
                    },
                    tooltip: "rag.workspace.message.copyQuestion"
                ) { didCopy in
                    copyIcon(didCopy: didCopy)
                }
                Button(action: onBeginEdit) {
                    Image(systemName: "pencil")
                        .font(interfaceScale.font(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("rag.workspace.message.editQuestion")
            } else {
                CopyFeedbackButton(
                    performCopy: {
                        let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return false }
                        NSPasteboard.general.clearContents()
                        let ok = NSPasteboard.general.setString(trimmed, forType: .string)
                        if ok { pinActionsForCopyFeedback() }
                        return ok
                    },
                    tooltip: "rag.workspace.message.copyQuestion.clipboard"
                ) { didCopy in
                    copyIcon(didCopy: didCopy)
                }
            }
        }
        // 停止态常显；普通态整行随悬停显隐，避免时间戳一直挂在下一条消息上方。
        .opacity(showsPendingActions || areHoverActionsRevealed ? 1 : 0)
        .allowsHitTesting(showsPendingActions || areHoverActionsRevealed)
        .accessibilityHidden(!(showsPendingActions || areHoverActionsRevealed))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: areHoverActionsRevealed)
    }

    private func copyIcon(didCopy: Bool) -> some View {
        Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
            .font(interfaceScale.font(size: 12, weight: .medium))
            .foregroundStyle(didCopy ? Color.green : .secondary)
            .frame(width: 20, height: 20)
    }

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
