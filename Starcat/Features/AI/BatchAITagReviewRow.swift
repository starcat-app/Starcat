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
    let isExpanded: Bool
    let onToggleExpansion: () -> Void
    let onToggleTag: (String) -> Void
    let onSelectAll: () -> Void
    let onClearSelection: () -> Void
    let onApply: () -> Void
    let onIgnore: () -> Void
    let onRetryGeneration: () -> Void

    @Environment(\.locale) private var locale

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
                    .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var summaryButton: some View {
        Button(action: onToggleExpansion) {
            HStack(alignment: .top, spacing: 10) {
                statusIcon
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: job.repoFullName)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detailText {
                        Text(verbatim: detailText)
                            .font(.caption)
                            .foregroundStyle(detailColor)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if canExpand {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!canExpand)
        .help(job.repoFullName)
    }

    @ViewBuilder
    private var expandedContent: some View {
        if !job.suggestedTags.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                tagGrid
                reviewActions
            }
        } else if let diagnostic = job.errorDiagnostic {
            diagnosticContent(diagnostic)
        }
    }

    private var tagGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(job.suggestedTags) { suggestion in
                let isSelected = job.selectedSuggestedTagIDs.contains(suggestion.id)
                Button {
                    onToggleTag(suggestion.id)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: suggestion.name)
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(verbatim: suggestion.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(
                            suggestion.confidence,
                            format: .percent.precision(.fractionLength(0)).locale(locale)
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.16),
                                lineWidth: 1
                            )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .disabled(!canEditSelection)
                .help(suggestion.reason)
            }
        }
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
