//
//  GitHubStarListAIGroupingResultList.swift
//  Starcat
//
//  AI 仓库分组的紧凑审核列表。
//
//  默认只渲染展示缓存给出的首批结果；行内保持单行摘要，只有当前仓库展开判断依据
//  或失败信息。分组选择使用独立 Popover，明确支持一个仓库同时加入多个 List。
//

import SwiftUI

struct GitHubStarListAIGroupingResultList: View {
    let items: [GitHubStarListAIReviewItem]
    let searchText: String
    let availableLists: [GitHubStarListAIListDisplay]
    let onToggleList: (Int64, String) -> Void
    let onSelectAllSuggestions: (Int64) -> Void
    let onClearSelection: (Int64) -> Void
    let onIgnore: (Int64) -> Void
    let onRetryAnalysis: (Int64) -> Void
    let onRetryApply: (Int64) -> Void
    let onLoadMore: () -> Void

    @State private var expandedRepoID: Int64?

    var body: some View {
        if items.isEmpty {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView(
                    "githubStarLists.aiGrouping.results.empty",
                    systemImage: "tray",
                    description: Text("githubStarLists.aiGrouping.results.empty.help")
                )
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            List(items) { item in
                GitHubStarListAIGroupingResultRow(
                    item: item,
                    availableLists: availableLists,
                    isExpanded: expandedRepoID == item.id,
                    onToggleExpansion: { toggleExpansion(for: item) },
                    onToggleList: { onToggleList(item.id, $0) },
                    onSelectAllSuggestions: { onSelectAllSuggestions(item.id) },
                    onClearSelection: { onClearSelection(item.id) },
                    onIgnore: { onIgnore(item.id) },
                    onRetryAnalysis: { onRetryAnalysis(item.id) },
                    onRetryApply: { onRetryApply(item.id) }
                )
                .onAppear {
                    if item.id == items.last?.id {
                        onLoadMore()
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func toggleExpansion(for item: GitHubStarListAIReviewItem) {
        guard item.hasSuggestions || item.applyFailure != nil || item.status == .failed else { return }
        expandedRepoID = expandedRepoID == item.id ? nil : item.id
    }
}

private struct GitHubStarListAIGroupingResultRow: View {
    let item: GitHubStarListAIReviewItem
    let availableLists: [GitHubStarListAIListDisplay]
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    let onToggleList: (String) -> Void
    let onSelectAllSuggestions: () -> Void
    let onClearSelection: () -> Void
    let onIgnore: () -> Void
    let onRetryAnalysis: () -> Void
    let onRetryApply: () -> Void

    @State private var showGroupPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                selectionButton
                summaryButton
                groupPickerButton
            }
            if isExpanded {
                expandedContent
                    .padding(.leading, 30)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var selectionButton: some View {
        if item.hasSelection {
            Button("githubStarLists.aiGrouping.selection.clearRepo", systemImage: "checkmark.square.fill", action: onClearSelection)
                .labelStyle(.iconOnly)
                .foregroundStyle(.tint)
                .buttonStyle(.plain)
                .focusEffectDisabled()
        } else if item.hasActionableSuggestions {
            Button("githubStarLists.aiGrouping.action.acceptAll", systemImage: "square", action: onSelectAllSuggestions)
                .labelStyle(.iconOnly)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .focusEffectDisabled()
        } else {
            statusIcon
                .frame(width: 16)
        }
    }

    private var summaryButton: some View {
        Button(action: onToggleExpansion) {
            HStack(spacing: 10) {
                if item.hasSelection || item.hasActionableSuggestions {
                    statusIcon
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: item.repoFullName)
                        .font(.subheadline.weight(.semibold).monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    summaryLine
                }
                Spacer(minLength: 8)
                statusLabel
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if canExpand {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!canExpand)
        .help(item.repoFullName)
    }

    @ViewBuilder
    private var summaryLine: some View {
        if !selectedGroupDisplays.isEmpty {
            HStack(spacing: 6) {
                Text("githubStarLists.aiGrouping.status.suggested")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(selectedGroupDisplays.prefix(3)) { selection in
                    groupChip(selection)
                }
                if selectedGroupDisplays.count > 3 {
                    Text(verbatim: "+\(selectedGroupDisplays.count - 3)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
        } else if let failure = item.applyFailure {
            Text(verbatim: failure.localizedMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if item.status == .failed {
            Text(verbatim: item.analysisFailureMessage ?? String.l10n("batchAI.panel.row.failedUnknown"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if !item.currentLists.isEmpty {
            Text(String(
                format: String.l10n("githubStarLists.aiGrouping.currentGroupsFormat"),
                item.currentLists.map(\.name).joined(separator: ", ")
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            statusDetail
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func groupChip(_ selection: SelectedGroupDisplay) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: selection.list.colorHex) ?? .accentColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(verbatim: selection.list.name)
            if let confidence = selection.confidence {
                Text(confidence, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var groupPickerButton: some View {
        Button {
            showGroupPicker = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                Text("githubStarLists.aiGrouping.action.modifyGroups")
                if !item.selectedListIDs.isEmpty {
                    Text(item.selectedListIDs.count, format: .number)
                        .monospacedDigit()
                }
            }
        }
        .controlSize(.small)
        .popover(isPresented: $showGroupPicker, arrowEdge: .bottom) {
            GitHubStarListAIMultiGroupPicker(
                item: item,
                availableLists: availableLists,
                onToggleList: onToggleList
            )
            .appLocaleEnvironment()
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let failure = item.applyFailure {
            VStack(alignment: .leading, spacing: 7) {
                Label {
                    Text(verbatim: failure.localizedMessage)
                } icon: {
                    Image(systemName: failure.kind == .organizationOAuthRestriction
                        ? "building.2.crop.circle"
                        : "icloud.slash")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if failure.kind == .organizationOAuthRestriction,
                       let destination = URL(string: "https://github.com/\(item.repoFullName)") {
                        Link("githubStarLists.aiGrouping.applyFailure.openGitHub", destination: destination)
                    }
                    Button("action.retry", action: onRetryApply)
                        .controlSize(.small)
                    Button("githubStarLists.aiGrouping.action.ignore", action: onIgnore)
                        .controlSize(.small)
                }
            }
        } else if item.status == .failed {
            HStack(spacing: 8) {
                Text(verbatim: item.analysisFailureMessage ?? String.l10n("batchAI.panel.row.failedUnknown"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("action.retry", action: onRetryAnalysis)
                    .controlSize(.small)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(item.actionableSuggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(verbatim: suggestion.list.name)
                                .font(.callout.weight(.semibold))
                            Spacer()
                            Text(suggestion.confidence, format: .percent.precision(.fractionLength(0)))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.tint)
                        }
                        if !suggestion.reason.isEmpty {
                            Text(verbatim: suggestion.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !suggestion.list.instruction.isEmpty {
                            Text(verbatim: suggestion.list.instruction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button("githubStarLists.aiGrouping.action.acceptAll", action: onSelectAllSuggestions)
                        .controlSize(.small)
                    Button("githubStarLists.aiGrouping.action.ignore", action: onIgnore)
                        .controlSize(.small)
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if item.isApplying {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("githubStarLists.aiGrouping.applying")
        } else if item.isApplied {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("githubStarLists.aiGrouping.status.applied")
        } else if item.applyFailure != nil || item.status == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("githubStarLists.aiGrouping.status.failed")
        } else if item.status == .analyzing {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("githubStarLists.aiGrouping.status.processing")
        } else if item.hasActionableSuggestions {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .accessibilityLabel("githubStarLists.aiGrouping.status.suggested")
        } else if item.isNoMatch {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("githubStarLists.aiGrouping.status.noMatch")
        } else {
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("githubStarLists.aiGrouping.status.queued")
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if item.isApplying {
            Text("githubStarLists.aiGrouping.applying")
        } else if item.isApplied {
            Text("githubStarLists.aiGrouping.status.applied")
        } else if item.applyFailure != nil {
            Text("githubStarLists.aiGrouping.filter.applyFailed")
        } else if item.status == .failed {
            Text("githubStarLists.aiGrouping.filter.analysisFailed")
        } else if item.status == .analyzing {
            Text("githubStarLists.aiGrouping.status.processing")
        } else if item.hasActionableSuggestions {
            Text("githubStarLists.aiGrouping.status.suggested")
        } else if item.isNoMatch {
            Text("githubStarLists.aiGrouping.status.noMatch")
        }
    }

    @ViewBuilder
    private var statusDetail: some View {
        if item.status == .analyzing {
            Text("githubStarLists.aiGrouping.status.processing")
        } else if item.status == .queued || item.status == .stopped {
            Text(item.status == .stopped
                ? LocalizedStringKey("batchAI.panel.paused")
                : LocalizedStringKey("githubStarLists.aiGrouping.status.queued"))
        } else if item.isNoMatch {
            Text("githubStarLists.aiGrouping.noMatch.detail")
        }
    }

    private var canExpand: Bool {
        item.hasSuggestions || item.applyFailure != nil || item.status == .failed
    }

    private var selectedGroupDisplays: [SelectedGroupDisplay] {
        let listsByID = Dictionary(uniqueKeysWithValues: availableLists.map { ($0.id, $0) })
        let suggestionsByID = Dictionary(uniqueKeysWithValues: item.actionableSuggestions.map { ($0.id, $0) })
        return item.selectedListIDs.compactMap { listID in
            guard let list = listsByID[listID] else { return nil }
            return SelectedGroupDisplay(list: list, confidence: suggestionsByID[listID]?.confidence)
        }
        .sorted { $0.list.name < $1.list.name }
    }

    private struct SelectedGroupDisplay: Identifiable {
        var id: String { list.id }
        let list: GitHubStarListAIListDisplay
        let confidence: Double?
    }
}
