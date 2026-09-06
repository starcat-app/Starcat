//
//  RAGContextPickerRepositoryRow.swift
//  Starcat
//
//  RAG 上下文选择器的轻量、可比较仓库行。
//

import SwiftUI

/// 把候选快照与选择状态收敛为不可变输入，隔离工作台消息流、搜索框和面板状态更新。
///
/// 闭包绑定同一个面板会话，不参与相等判断；真正决定视觉的候选与布尔状态变化时，
/// SwiftUI 才需要重新计算行内容。
struct RAGContextPickerRepositoryRow: View, Equatable {
    let candidate: RAGMentionCandidate
    let isSelected: Bool
    let isHighlighted: Bool
    let isEnabled: Bool
    let selectionLimit: Int
    let onToggle: () -> Void

    @Environment(\.locale) private var locale

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.candidate == rhs.candidate
            && lhs.isSelected == rhs.isSelected
            && lhs.isHighlighted == rhs.isHighlighted
            && lhs.isEnabled == rhs.isEnabled
            && lhs.selectionLimit == rhs.selectionLimit
    }

    var body: some View {
        Button(action: onToggle) {
            UnifiedCompactRepoRow(
                fullName: candidate.fullName,
                owner: candidate.owner,
                ownerAvatarURL: candidate.ownerAvatar,
                language: candidate.language,
                starsCount: candidate.starsCount,
                isChecked: isSelected,
                isHighlighted: isHighlighted,
                isEnabled: isEnabled
            ) {
                // 索引侧元数据属于 RAG，不下沉进共享 Row 的仓库身份模型。
                if candidate.chunkCount > 0 {
                    MetaBadge(
                        systemImage: "square.stack.3d.up",
                        text: candidate.chunkCount.formattedShort,
                        tint: .secondary
                    )
                    .help(
                        Text(
                            String(
                                format: String.l10n("rag.workspace.mention.badge.chunks"),
                                locale: locale,
                                candidate.chunkCount
                            )
                        )
                    )
                }
                if candidate.hasAISummary {
                    MetaBadge(
                        systemImage: "sparkles",
                        text: "",
                        tint: .accentColor,
                        iconOnly: true,
                        accessibilityLabel: "rag.workspace.mention.badge.aiSummary"
                    )
                    .help("rag.workspace.mention.badge.aiSummary")
                }
                if candidate.hasPrivateNote {
                    MetaBadge(
                        systemImage: "note.text",
                        text: "",
                        tint: .orange,
                        iconOnly: true,
                        accessibilityLabel: "rag.workspace.mention.badge.privateNote"
                    )
                    .help("rag.workspace.mention.badge.privateNote")
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isEnabled)
        .help(
            isEnabled
                ? Text(candidate.fullName)
                : Text(
                    String(
                        format: String.l10n("rag.workspace.mention.selectionLimit"),
                        locale: locale,
                        selectionLimit
                    )
                )
        )
    }
}
