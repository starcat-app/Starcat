//
//  AgentContextPickerRepositoryRow.swift
//  Starcat
//
//  Agent 工作台上下文选择器的轻量、可比较仓库行。
//

import SwiftUI

/// 只接收一行渲染所需的数据，避免行在滚动复用时观察整个 Agent ViewModel。
///
/// `onToggle` 在同一面板生命周期内语义稳定，因此不参与相等判断；候选、来源或选择态
/// 发生变化时仍会正常刷新。
struct AgentContextPickerRepositoryRow: View, Equatable {
    let candidate: RAGMentionCandidate
    let sources: [AgentRepositorySource]
    let isSelected: Bool
    let isHighlighted: Bool
    let isEnabled: Bool
    let selectionLimit: Int
    let onToggle: () -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.candidate == rhs.candidate
            && lhs.sources == rhs.sources
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
                HStack(spacing: 4) {
                    ForEach(sources.prefix(2), id: \.self) { source in
                        Image(systemName: source.systemImage)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .help(source.title)
                    }
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
                        format: String.l10n("agent.workspace.repositoryPicker.selectionLimit"),
                        locale: locale,
                        selectionLimit
                    )
                )
        )
    }
}
