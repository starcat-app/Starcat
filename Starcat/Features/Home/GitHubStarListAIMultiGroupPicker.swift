//
//  GitHubStarListAIMultiGroupPicker.swift
//  Starcat
//
//  AI 仓库分组审核行的多分组选择器。
//
//  GitHub List membership 天然是多选关系。该 Popover 不会在勾选一项后关闭，
//  用户可以连续选择多个分组；已经存在的 membership 不重复显示为待应用选项。
//

import SwiftUI

struct GitHubStarListAIMultiGroupPicker: View {
    let item: GitHubStarListAIReviewItem
    let availableLists: [GitHubStarListAIListDisplay]
    let onToggleList: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("githubStarLists.aiGrouping.action.modifyGroups")
                    .font(.headline)
                Spacer()
                Text(item.selectedListIDs.count, format: .number)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()

            if selectableLists.isEmpty {
                ContentUnavailableView(
                    "githubStarLists.aiGrouping.noAvailableGroups",
                    systemImage: "tray"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(selectableLists) { list in
                            groupButton(list)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var selectableLists: [GitHubStarListAIListDisplay] {
        let currentIDs = Set(item.currentLists.map(\.id))
        return availableLists.filter { !currentIDs.contains($0.id) }
    }

    private func groupButton(_ list: GitHubStarListAIListDisplay) -> some View {
        let isSelected = item.selectedListIDs.contains(list.id)
        let suggestion = item.actionableSuggestions.first { $0.id == list.id }
        return Button {
            onToggleList(list.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Circle()
                    .fill(Color(hex: list.colorHex) ?? .accentColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(verbatim: list.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if let suggestion {
                    Text(suggestion.confidence, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(isSelected
            ? "githubStarLists.aiGrouping.selection.remove"
            : "githubStarLists.aiGrouping.selection.add")
    }
}
