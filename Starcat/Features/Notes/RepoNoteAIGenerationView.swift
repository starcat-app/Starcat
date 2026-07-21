//
//  RepoNoteAIGenerationView.swift
//  Starcat
//
//  AI 个人笔记的折叠标题行进度与展开后的七步跟踪 / 草稿确认 UI。
//

import MarkdownUI
import SwiftUI

/// 折叠标题行右侧的紧凑控件。与整行展开 Button 是 ZStack 兄弟，禁止嵌套 Button。
struct RepoNoteAIGenerationHeaderControl: View {
    let viewModel: RepoNoteAIGenerationViewModel
    let onGenerate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            switch viewModel.phase {
            case .idle:
                generateButton
            case .running:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                stepMarkers
                compactProgress
                cancelButton
            case .awaitingConfirmation:
                stepMarkers
                compactProgress
            case .applying:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                stepMarkers
                compactProgress
            case .completed:
                stepMarkers
                Text("\(viewModel.resolvedStepCount)/\(RepoNoteAIGenerationStep.allCases.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            case .failed:
                stepMarkers
                compactProgress
            case .cancelled:
                stepMarkers
                compactProgress
            }
        }
    }

    private var generateButton: some View {
        Button(action: onGenerate) {
            Label("repo.notes.ai.generate", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("repo.notes.ai.generateHelp"))
        .accessibilityHint(Text("repo.notes.ai.generateHelp"))
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text("repo.notes.ai.cancel"))
        .accessibilityLabel(Text("repo.notes.ai.cancel"))
    }

    private var compactProgress: some View {
        HStack(spacing: 4) {
            if let current = viewModel.currentStep {
                Text(LocalizedStringKey(current.titleKey))
                    .lineLimit(1)
            } else if let key = viewModel.errorMessageKey {
                Text(LocalizedStringKey(key))
                    .lineLimit(1)
            }
            Text("\(viewModel.resolvedStepCount)/\(RepoNoteAIGenerationStep.allCases.count)")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
        .frame(maxWidth: 120, alignment: .trailing)
    }

    /// 七个固定状态点让折叠状态也能区分 README 下载是完成、跳过还是失败。
    /// 图标使用固定 frame，避免从空心圆切换到 checkmark 时挤动标题内容。
    private var stepMarkers: some View {
        HStack(spacing: 2) {
            ForEach(RepoNoteAIGenerationStep.allCases) { step in
                marker(for: viewModel.stepStates[step] ?? .pending)
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 9, height: 11)
                    .accessibilityLabel(
                        Text(LocalizedStringKey(step.titleKey))
                            + Text(", ")
                            + Text(LocalizedStringKey(stateTitleKey(viewModel.stepStates[step] ?? .pending)))
                    )
            }
        }
    }

    @ViewBuilder
    private func marker(for state: RepoNoteAIGenerationStepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .running:
            Image(systemName: "circle.fill")
                .foregroundStyle(.primary)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.primary)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.primary)
        case .cancelled:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func stateTitleKey(_ state: RepoNoteAIGenerationStepState) -> String {
        switch state {
        case .pending: "repo.notes.ai.state.pending"
        case .running: "repo.notes.ai.state.running"
        case .completed: "repo.notes.ai.state.completed"
        case .skipped: "repo.notes.ai.state.skipped"
        case .failed: "repo.notes.ai.state.failed"
        case .cancelled: "repo.notes.ai.state.cancelled"
        }
    }
}

/// 展开后的完整跟踪器。草稿始终与正式编辑 buffer 分离，只能通过确认回调应用。
struct RepoNoteAIGenerationPanel: View {
    let viewModel: RepoNoteAIGenerationViewModel
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onDiscard: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("repo.notes.ai.progressTitle", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(viewModel.resolvedStepCount)/\(RepoNoteAIGenerationStep.allCases.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Label("repo.notes.ai.privacyNotice", systemImage: "lock.shield")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(RepoNoteAIGenerationStep.allCases) { step in
                    stepRow(step)
                }
            }

            if let key = viewModel.errorMessageKey {
                errorBanner(key: key)
            }

            if !viewModel.draftMarkdown.isEmpty {
                Divider()
                Text("repo.notes.ai.draftTitle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                ScrollView {
                    Markdown(viewModel.draftMarkdown)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 260)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.2))
                }
            }

            actionRow
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.14))
        }
        .accessibilityElement(children: .contain)
    }

    private func stepRow(_ step: RepoNoteAIGenerationStep) -> some View {
        let state = viewModel.stepStates[step] ?? .pending
        return HStack(spacing: 8) {
            stepIcon(state)
                .frame(width: 14)
            Text(LocalizedStringKey(step.titleKey))
                .font(.caption)
                .foregroundStyle(state == .running ? .primary : .secondary)
            Spacer()
            Text(LocalizedStringKey(stateTitleKey(state)))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stepIcon(_ state: RepoNoteAIGenerationStepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.primary)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.primary)
        case .cancelled:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func stateTitleKey(_ state: RepoNoteAIGenerationStepState) -> String {
        switch state {
        case .pending: "repo.notes.ai.state.pending"
        case .running: "repo.notes.ai.state.running"
        case .completed: "repo.notes.ai.state.completed"
        case .skipped: "repo.notes.ai.state.skipped"
        case .failed: "repo.notes.ai.state.failed"
        case .cancelled: "repo.notes.ai.state.cancelled"
        }
    }

    private func errorBanner(key: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(key))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                if let detail = viewModel.errorDetail,
                   detail != String.l10n(key) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            Spacer()
            switch viewModel.phase {
            case .running:
                Button("repo.notes.ai.cancel", action: onCancel)
                    .buttonStyle(.bordered)
            case .awaitingConfirmation:
                Button("repo.notes.ai.discard", action: onDiscard)
                    .buttonStyle(.bordered)
                Button("repo.notes.ai.regenerate", action: onRetry)
                    .buttonStyle(.bordered)
                Button("repo.notes.ai.apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canApplyDraft)
            case .applying:
                ProgressView()
                    .controlSize(.small)
                Text("repo.notes.ai.saving")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed, .cancelled:
                Button("repo.notes.ai.discard", action: onDiscard)
                    .buttonStyle(.bordered)
                Button("repo.notes.ai.retry", action: onRetry)
                    .buttonStyle(.borderedProminent)
            case .completed:
                Button("repo.notes.ai.done", action: onDiscard)
                    .buttonStyle(.bordered)
                Button("repo.notes.ai.regenerate", action: onRetry)
                    .buttonStyle(.borderedProminent)
            case .idle:
                EmptyView()
            }
        }
        .controlSize(.small)
    }
}
