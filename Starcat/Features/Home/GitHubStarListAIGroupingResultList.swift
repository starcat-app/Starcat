//
//  GitHubStarListAIGroupingResultList.swift
//  Starcat
//
//  AI 仓库分组的紧凑审核列表。
//
//  默认只渲染展示缓存给出的首批结果；行内保持单行摘要，展开后用芯片墙改分组。
//  一个仓库可以同时加入多个 List；已有 membership 不能从这里移除。
//

import SwiftUI

struct GitHubStarListAIGroupingResultList: View {
    let items: [GitHubStarListAIReviewItem]
    let searchText: String
    let filter: GitHubStarListAIResultFilter
    let availableLists: [GitHubStarListAIListDisplay]
    let hasMore: Bool
    let onToggleList: (Int64, String) -> Void
    let onSelectAllSuggestions: (Int64) -> Void
    let onClearSelection: (Int64) -> Void
    let onApply: (Int64) -> Void
    let onIgnore: (Int64) -> Void
    let onRetryAnalysis: (Int64) -> Void
    let onRetryApply: (Int64) -> Void
    let onLoadMore: () -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var expandedRepoID: Int64?

    var body: some View {
        VStack(spacing: 0) {
            if filter == .automaticallyIgnored {
                autoIgnoredExplanation
                Divider()
            }
            ZStack {
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
                    List(Array(items.enumerated()), id: \.element.id) { index, item in
                        GitHubStarListAIGroupingResultRow(
                            item: item,
                            availableLists: availableLists,
                            isExpanded: expandedRepoID == item.id,
                            onToggleExpansion: { toggleExpansion(for: item) },
                            onToggleList: { onToggleList(item.id, $0) },
                            onSelectAllSuggestions: { onSelectAllSuggestions(item.id) },
                            onClearSelection: { onClearSelection(item.id) },
                            onApply: { onApply(item.id) },
                            onIgnore: { onIgnore(item.id) },
                            onRetryAnalysis: { onRetryAnalysis(item.id) },
                            onRetryApply: { onRetryApply(item.id) }
                        )
                        .equatable()
                        .automaticListPagination(
                            appearingIndex: index,
                            visibleItemCount: items.count,
                            loadedItemCount: items.count,
                            hasMore: hasMore,
                            isLoading: false,
                            identity: "github-list-ai-\(filter.rawValue)-\(searchText)"
                        ) {
                            onLoadMore()
                        }
                    }
                    .listStyle(.inset)
                }
            }
            // 空态和列表态共享完全相同的剩余空间，切换任意 Tab 都不会重新分配工具栏高度。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 组织 OAuth 限制说明固定在自动忽略面板顶部，有没有仓库都要看见。
    private var autoIgnoredExplanation: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(interfaceScale.font(.iconMedium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("githubStarLists.aiGrouping.filter.automaticallyIgnored.reason")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleExpansion(for item: GitHubStarListAIReviewItem) {
        guard item.automaticallyIgnoredFailure != nil
                || item.applyFailure != nil
                || item.status == .failed
        else { return }
        expandedRepoID = expandedRepoID == item.id ? nil : item.id
    }
}

private struct GitHubStarListAIGroupingResultRow: View, Equatable {
    let item: GitHubStarListAIReviewItem
    let availableLists: [GitHubStarListAIListDisplay]
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    let onToggleList: (String) -> Void
    let onSelectAllSuggestions: () -> Void
    let onClearSelection: () -> Void
    let onApply: () -> Void
    let onIgnore: () -> Void
    let onRetryAnalysis: () -> Void
    let onRetryApply: () -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale

    /// 复选框 16 + 间距 8 + Logo 26 + 间距 10，确保建议与操作始终从状态文案列开始。
    private let contentColumnLeadingInset: CGFloat = 60

    /// 行操作始终绑定同一个 Sheet 会话，真正影响渲染的只有数据、分组配置和展开态。
    /// 忽略每次父视图刷新都会重建的闭包，避免一个仓库进度变化让其它可见行重复计算 body。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.availableLists == rhs.availableLists
            && lhs.isExpanded == rhs.isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                selectionButton
                    .frame(width: 16, height: 22)
                summaryButton
            }
            if item.canReviewSuggestions {
                suggestionReviewContent
                    .padding(.leading, contentColumnLeadingInset)
            }
            if isExpanded, canExpand {
                diagnosticContent
                    .padding(.leading, contentColumnLeadingInset)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var selectionButton: some View {
        // 左侧只留勾选列，状态图标跟在仓库名后面，logo 和名称才能跨行对齐。
        if item.canReviewSuggestions {
            if item.hasSelection {
                Button("githubStarLists.aiGrouping.selection.clearRepo", systemImage: "checkmark.square.fill", action: onClearSelection)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
            } else {
                Button("githubStarLists.aiGrouping.action.acceptAll", systemImage: "square", action: onSelectAllSuggestions)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
            }
        } else {
            Color.clear
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var summaryButton: some View {
        if canExpand {
            Button(action: onToggleExpansion) {
                summaryContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(item.repoFullName)
        } else {
            summaryContent
                .help(item.repoFullName)
        }
    }

    private var summaryContent: some View {
        HStack(alignment: .top, spacing: 10) {
            RemoteAvatar(
                urlString: item.repo.ownerAvatar ?? RepoAvatarURL.from(owner: item.repo.owner),
                size: 26,
                fallbackSymbol: "shippingbox.circle.fill"
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: item.repoFullName)
                        .font(interfaceScale.font(.rowTitle))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    statusIcon
                        .frame(width: 16, height: 16)
                        .layoutPriority(1)
                }
                if let description = item.repoDescription {
                    Text(verbatim: description)
                        .font(interfaceScale.font(.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(description)
                }
                summaryLine
            }
            Spacer(minLength: 8)
            statusLabel
                .font(interfaceScale.font(.caption))
                .foregroundStyle(statusLabelColor)
            if canExpand {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var summaryLine: some View {
        if !item.selectedGroupSummaries.isEmpty {
            groupSummaryLine(
                prefix: "githubStarLists.aiGrouping.suggestJoinPrefix",
                groups: item.selectedGroupSummaries,
                fallbackColor: .accentColor
            )
        } else if let failure = item.automaticallyIgnoredFailure ?? item.applyFailure {
            Text(verbatim: failure.localizedMessage)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if item.isIgnoredByUser {
            Text("githubStarLists.aiGrouping.status.ignored")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        } else if item.status == .failed {
            Text(verbatim: item.analysisFailureMessage ?? String.l10n("batchAI.panel.row.failedUnknown"))
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.red)
                .lineLimit(1)
        } else if item.isApplied, !item.appliedGroupSummaries.isEmpty {
            groupSummaryLine(
                prefix: "githubStarLists.aiGrouping.appliedJoinPrefix",
                groups: item.appliedGroupSummaries,
                fallbackColor: .green
            )
        } else if item.hasActionableSuggestions {
            // 用户取消全部勾选后只保留“待确认”状态，不能继续展示任何未选中的分组。
            Text("githubStarLists.aiGrouping.status.suggested")
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        } else if !item.currentLists.isEmpty {
            Text(String(
                format: String.l10n("githubStarLists.aiGrouping.currentGroupsFormat"),
                locale: locale,
                item.currentLists.map(\.name).joined(separator: ", ")
            ))
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        } else {
            statusDetail
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
        }
    }

    /// 摘要必须完整反映芯片墙的多选集合；置信度只说明 AI 判断，不参与挑选主分组。
    private func groupSummaryLine(
        prefix: LocalizedStringKey,
        groups: [GitHubStarListAIGroupSummaryDisplay],
        fallbackColor: Color
    ) -> some View {
        let firstGroupID = groups.first?.id
        return HStack(spacing: 4) {
            Text(prefix)
                .foregroundStyle(.secondary)
            ForEach(groups) { group in
                if group.id != firstGroupID {
                    Text(verbatim: "·")
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: group.list.name)
                    .foregroundStyle(Color(hex: group.list.colorHex) ?? fallbackColor)
                    .fontWeight(.semibold)
                if let confidence = group.confidence {
                    Text(confidence, format: .percent.precision(.fractionLength(0)).locale(locale))
                        .foregroundStyle(confidenceColor(confidence))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
            }
        }
        .font(interfaceScale.font(.caption))
        .lineLimit(1)
    }

    @ViewBuilder
    private var diagnosticContent: some View {
        if let failure = item.automaticallyIgnoredFailure {
            failureBox {
                VStack(alignment: .leading, spacing: 7) {
                    Text(verbatim: failure.localizedMessage)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                    if let destination = URL(string: "https://github.com/\(item.repoFullName)") {
                        Link("githubStarLists.aiGrouping.applyFailure.openGitHub", destination: destination)
                            .font(interfaceScale.font(.caption))
                    }
                }
            }
        } else if let failure = item.applyFailure {
            failureBox {
                VStack(alignment: .leading, spacing: 7) {
                    Text(verbatim: failure.localizedMessage)
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if failure.kind == .organizationOAuthRestriction,
                           let destination = URL(string: "https://github.com/\(item.repoFullName)") {
                            Link("githubStarLists.aiGrouping.applyFailure.openGitHub", destination: destination)
                                .font(interfaceScale.font(.caption))
                        }
                        if failure.isRetryable {
                            Button("action.retry", action: onRetryApply)
                                .controlSize(.small)
                        }
                    }
                }
            }
        } else if item.status == .failed {
            failureBox {
                HStack(spacing: 8) {
                    Text(verbatim: item.analysisFailureMessage ?? String.l10n("batchAI.panel.row.failedUnknown"))
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("action.retry", action: onRetryAnalysis)
                        .controlSize(.small)
                }
            }
        }
    }

    private var suggestionReviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            GitHubStarListAIGroupingChipBar(
                lists: availableLists,
                item: item,
                onToggleList: onToggleList
            )
            HStack(spacing: 8) {
                Button("batchAI.panel.review.selectAll", action: onSelectAllSuggestions)
                    .controlSize(.small)
                    .disabled(hasSelectedAllSuggestions || item.isApplying)
                Button("batchAI.panel.review.clear", action: onClearSelection)
                    .controlSize(.small)
                    .disabled(!item.hasSelection || item.isApplying)
                Spacer()
                Button("batchAI.panel.review.ignore", action: onIgnore)
                    .controlSize(.small)
                    .disabled(item.isApplying)
                Button("action.apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!item.hasSelection || item.isApplying)
            }
        }
    }

    /// “全选”只覆盖 AI 本次生成且尚未属于当前仓库的候选分组，与标签审核行的语义保持一致。
    private var hasSelectedAllSuggestions: Bool {
        item.actionableSuggestions.allSatisfy { item.selectedListIDs.contains($0.id) }
    }

    private func failureBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
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
        } else if item.automaticallyIgnoredFailure != nil {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("githubStarLists.aiGrouping.filter.automaticallyIgnored")
        } else if item.isIgnored {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("githubStarLists.aiGrouping.status.ignored")
        } else if item.applyFailure != nil || item.status == .failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("githubStarLists.aiGrouping.status.failed")
        } else if item.status == .analyzing {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
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
        } else if item.automaticallyIgnoredFailure != nil {
            Text("githubStarLists.aiGrouping.filter.automaticallyIgnored")
        } else if item.isIgnored {
            Text("githubStarLists.aiGrouping.status.ignored")
        } else if item.applyFailure != nil {
            Text("githubStarLists.aiGrouping.filter.applyFailed")
        } else if item.status == .failed {
            Text("githubStarLists.aiGrouping.filter.analysisFailed")
        } else if item.status == .analyzing {
            Text("githubStarLists.aiGrouping.status.processing")
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
        item.automaticallyIgnoredFailure != nil
            || item.applyFailure != nil
            || item.status == .failed
    }

    private var statusLabelColor: Color {
        if item.applyFailure != nil || item.status == .failed {
            .red
        } else if item.canReviewSuggestions {
            .accentColor
        } else {
            .secondary
        }
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.9 { .green }
        else if confidence >= 0.7 { .accentColor }
        else { .orange }
    }
}

/// 审核展开区的分组芯片墙：默认只露出一行，溢出才出现「显示更多」。
private struct GitHubStarListAIGroupingChipBar: View {
    let lists: [GitHubStarListAIListDisplay]
    let item: GitHubStarListAIReviewItem
    let onToggleList: (String) -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsAllRows = false
    @State private var fullHeight: CGFloat = 0

    private let rowHeight: CGFloat = 32
    private var hasOverflow: Bool { fullHeight > rowHeight + 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                chipFlow
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                chipFlow
                    .frame(
                        maxHeight: showsAllRows || !hasOverflow ? nil : rowHeight,
                        alignment: .top
                    )
                    .clipped()
            }
            .onPreferenceChange(GitHubStarListAIGroupingChipHeightKey.self) { fullHeight = $0 }

            if hasOverflow {
                Button {
                    showsAllRows.toggle()
                } label: {
                    Text(showsAllRows
                         ? "githubStarLists.aiGrouping.showLess"
                         : "githubStarLists.aiGrouping.showMore")
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .font(interfaceScale.font(.captionStrong))
                .foregroundStyle(.tint)
            }
        }
    }

    private var chipFlow: some View {
        GitHubStarListAIGroupingFlowLayout(spacing: 8) {
            ForEach(lists) { list in
                chip(list)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: GitHubStarListAIGroupingChipHeightKey.self,
                    value: proxy.size.height
                )
            }
        )
    }

    private func chip(_ list: GitHubStarListAIListDisplay) -> some View {
        let groupColor = Color(hex: list.colorHex) ?? .accentColor
        let isLocked = item.currentLists.contains { $0.id == list.id }
        let isSelected = isLocked || item.selectedListIDs.contains(list.id)
        let suggestion = item.actionableSuggestions.first { $0.id == list.id }
        // 选中靠勾 + 分组淡底 + 主色文字；未选靠灰底 + 次要文字。不用铺满高饱和色。
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let fill: Color = isSelected
            ? groupColor.opacity(colorScheme == .dark ? 0.34 : 0.18)
            : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)
        let stroke: Color = isSelected
            ? groupColor.opacity(colorScheme == .dark ? 0.70 : 0.45)
            : Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12)

        return Button {
            guard !isLocked else { return }
            onToggleList(list.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(groupColor)
                    .accessibilityHidden(true)
                Text(verbatim: list.name)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                if let suggestion {
                    Text(suggestion.confidence, format: .percent.precision(.fractionLength(0)).locale(locale))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(interfaceScale.font(.captionStrong))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: shape)
            .overlay(shape.stroke(stroke, lineWidth: isSelected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isLocked)
        .help(list.name)
        .accessibilityLabel(isSelected
            ? "githubStarLists.aiGrouping.selection.remove"
            : "githubStarLists.aiGrouping.selection.add")
    }
}

private struct GitHubStarListAIGroupingChipHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 横向自动换行。只给分组芯片墙用，避免把设置页 FlowLayout 抽成共享依赖。
private struct GitHubStarListAIGroupingFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(in: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        let maxWidth = max(width, 1)

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return (origins, CGSize(width: maxWidth, height: y + rowHeight))
    }
}
