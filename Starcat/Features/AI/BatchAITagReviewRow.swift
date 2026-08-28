//
//  BatchAITagReviewRow.swift
//  Starcat
//
//  批量标签生成窗口中的单仓库审核行。
//
//  关键约束：
//  - 生成、选择和应用必须在同一窗口完成，不能把用户导向仓库详情页；
//  - 标题行整行可点击，chevron 只表达状态；
//  - 同一行只负责展示会话内建议，用户确认后才触发标签与 repo_tags 落库。
//

import SwiftUI

struct BatchAITagReviewRow: View {
    let job: BatchAIJob
    let rowIndex: Int
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    let onToggleTag: (String) -> Void
    let onSelectAll: () -> Void
    let onClearSelection: () -> Void
    let onApply: () -> Void
    let onIgnore: () -> Void
    let onRetryGeneration: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                summaryButton
                if job.status == .failed {
                    Button("batchAI.panel.retry", action: onRetryGeneration)
                        .controlSize(.small)
                }
            }
            if isExpanded {
                expandedContent
                    .padding(.leading, 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.14)) {
                isHovered = hovering
            }
        }
    }

    private var summaryButton: some View {
        Button(action: onToggleExpansion) {
            HStack(alignment: .top, spacing: 10) {
                RemoteAvatar(
                    urlString: resolvedAvatarURL,
                    size: 26,
                    fallbackSymbol: "shippingbox.circle.fill"
                )
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(verbatim: job.repoFullName)
                            .font(interfaceScale.font(.bodyEmphasis, weight: .semibold).monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        statusIcon
                            .frame(width: 16, height: 16)
                            .layoutPriority(1)
                    }
                    if let displayDescription {
                        Text(verbatim: displayDescription)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(displayDescription)
                    }
                    if let detailText {
                        Text(verbatim: detailText)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(detailColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 6)
                if canExpand {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(interfaceScale.font(.captionSmall).bold())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                        .padding(.top, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!canExpand)
        .help(job.repoFullName)
    }

    /// 优先复用同步得到的头像地址；缺失时沿用所有仓库列表共用的 GitHub owner fallback。
    private var resolvedAvatarURL: String {
        if let ownerAvatarURL = job.ownerAvatarURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ownerAvatarURL.isEmpty {
            return ownerAvatarURL
        }
        let owner = job.repoFullName.split(separator: "/", maxSplits: 1).first.map(String.init)
            ?? job.repoFullName
        return RepoAvatarURL.from(owner: owner)
    }

    /// 空白描述不占位；有效描述始终只渲染一行，避免长文本撑高或撑宽窗口。
    private var displayDescription: String? {
        guard let description = job.repoDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty
        else { return nil }
        return description
    }

    /// 斑马纹使用项目既有 4.5% primary；hover 以 accent 覆盖，明暗主题下都保持可辨识。
    private var rowBackground: Color {
        if isHovered {
            return Color.accentColor.opacity(0.10)
        }
        return rowIndex.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.045)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if !job.suggestedTags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                tagChips
                reviewActions
            }
        } else if let diagnostic = job.errorDiagnostic {
            diagnosticContent(diagnostic)
        }
    }

    /// 与 GitHub Lists 推荐分组保持同一套紧凑芯片视觉，只保留选择状态、名称和置信度。
    private var tagChips: some View {
        BatchAITagFlowLayout(spacing: 8) {
            ForEach(job.suggestedTags) { suggestion in
                tagChip(suggestion)
            }
        }
    }

    private func tagChip(_ suggestion: AITagSuggestion) -> some View {
        let isSelected = job.selectedSuggestedTagIDs.contains(suggestion.id)
        let shape = RoundedRectangle(cornerRadius: 6)
        let fill = isSelected
            ? Color.accentColor.opacity(colorScheme == .dark ? 0.34 : 0.18)
            : Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)
        let stroke = isSelected
            ? Color.accentColor.opacity(colorScheme == .dark ? 0.70 : 0.45)
            : Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.12)

        return Button {
            onToggleTag(suggestion.id)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
                Text(verbatim: suggestion.name)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(
                    suggestion.confidence,
                    format: .percent.precision(.fractionLength(0)).locale(locale)
                )
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            .font(interfaceScale.font(.captionStrong))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: shape)
            .overlay(shape.stroke(stroke, lineWidth: isSelected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!canEditSelection)
        .help(suggestion.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var reviewActions: some View {
        switch job.tagReviewState {
        case .pending, .failed:
            HStack(spacing: 8) {
                Button("batchAI.panel.review.selectAll", action: onSelectAll)
                    .controlSize(.small)
                    .disabled(job.selectedSuggestedTagIDs.count == job.suggestedTags.count)
                Button("batchAI.panel.review.clear", action: onClearSelection)
                    .controlSize(.small)
                    .disabled(job.selectedSuggestedTagIDs.isEmpty)
                Spacer()
                Button("batchAI.panel.review.ignore", action: onIgnore)
                    .controlSize(.small)
                Button("batchAI.panel.review.applySelected", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(job.selectedSuggestedTagIDs.isEmpty)
            }
        case .applying:
            Label("batchAI.panel.review.applying", systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .applied:
            Label("batchAI.panel.review.applied", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .ignored:
            Label("batchAI.panel.review.ignored", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notRequired:
            EmptyView()
        }
    }

    private func diagnosticContent(_ diagnostic: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: diagnostic)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            CopyFeedbackButton(
                providesContent: { copyableFailureReport },
                tooltip: "batchAI.panel.row.copyDetails"
            ) { didCopy in
                Label(
                    didCopy ? "batchAI.panel.row.copiedDetails" : "batchAI.panel.row.copyDetails",
                    systemImage: didCopy ? "checkmark.circle.fill" : "doc.on.doc"
                )
                .font(.caption)
                .foregroundStyle(didCopy ? Color.green : .secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if job.tagReviewState == .applying {
            ProgressView()
                .controlSize(.small)
        } else {
            switch job.status {
            case .queued:
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            case .processing:
                ProgressView()
                    .controlSize(.small)
            case .completed:
                Image(systemName: completedStatusSymbol)
                    .foregroundStyle(completedStatusColor)
            case .ignored:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private var detailText: String? {
        switch job.status {
        case .queued:
            nil
        case .processing:
            String.l10n("batchAI.panel.row.processing")
        case .completed:
            completedDetailText
        case .ignored:
            job.ignoredTagsBelowThreshold.prefix(3).map { suggestion in
                "\(suggestion.name)(\(Int((suggestion.confidence * 100).rounded()))%)"
            }.joined(separator: ", ")
        case .failed:
            job.failure?.localizedMessage ?? String.l10n("batchAI.panel.row.failedUnknown")
        }
    }

    private var completedDetailText: String {
        switch job.tagReviewState {
        case .pending:
            return String(
                format: String.l10n("batchAI.panel.review.pendingFormat"),
                locale: locale,
                job.suggestedTags.count
            )
        case .applying:
            return String.l10n("batchAI.panel.review.applying")
        case .failed(let failure):
            return failure.localizedMessage
        case .applied:
            return appliedTagsText
        case .ignored:
            return String.l10n("batchAI.panel.review.ignored")
        case .notRequired:
            if !job.appliedTagNames.isEmpty { return appliedTagsText }
            return job.didGenerateSummary
                ? String.l10n("batchAI.panel.row.summaryOnly")
                : String.l10n("batchAI.panel.row.completedNoTags")
        }
    }

    private var appliedTagsText: String {
        let names = job.appliedTagNames.prefix(5).joined(separator: ", ")
        return String(format: String.l10n("batchAI.panel.row.appliedTagsFormat"), names)
    }

    private var canEditSelection: Bool {
        switch job.tagReviewState {
        case .pending, .failed:
            true
        case .notRequired, .applying, .applied, .ignored:
            false
        }
    }

    private var canExpand: Bool {
        !job.suggestedTags.isEmpty || job.errorDiagnostic != nil
    }

    private var detailColor: Color {
        if job.status == .failed { return .red }
        if case .failed = job.tagReviewState { return .red }
        if job.tagReviewState == .pending { return .accentColor }
        return .secondary
    }

    private var completedStatusSymbol: String {
        switch job.tagReviewState {
        case .pending:
            "sparkles"
        case .applying:
            "arrow.down.circle"
        case .failed:
            "exclamationmark.triangle.fill"
        case .notRequired, .applied, .ignored:
            "checkmark.circle.fill"
        }
    }

    private var completedStatusColor: Color {
        switch job.tagReviewState {
        case .pending:
            .accentColor
        case .failed:
            .red
        case .notRequired, .applying, .applied, .ignored:
            .green
        }
    }

    private var copyableFailureReport: String {
        BatchAIQueueService.copyableFailureReport(
            repoFullName: job.repoFullName,
            message: job.failure?.localizedMessage,
            diagnostic: job.copyDiagnostic ?? job.errorDiagnostic
        )
    }
}
