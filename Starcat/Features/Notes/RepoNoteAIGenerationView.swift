//
//  RepoNoteAIGenerationView.swift
//  Starcat
//
//  AI 个人笔记的标题行入口、七步跟踪与可折叠草稿确认 UI。
//

import MarkdownUI
import SwiftUI

/// 折叠标题行右侧只保留生成入口。过程信息统一放在输入框下方，避免同一状态重复展示。
struct RepoNoteAIGenerationHeaderControl: View {
    let viewModel: RepoNoteAIGenerationViewModel
    let hasExistingNote: Bool
    let onGenerate: () -> Void

    @ViewBuilder
    var body: some View {
        switch viewModel.phase {
        case .idle, .completed:
            generateButton
        case .running, .awaitingConfirmation, .applying, .failed, .cancelled:
            EmptyView()
        }
    }

    private var generateButton: some View {
        Button(action: onGenerate) {
            Label(generateTitleKey, systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text(generateHelpKey))
        .accessibilityHint(Text(generateHelpKey))
    }

    private var generateTitleKey: LocalizedStringKey {
        hasExistingNote ? "repo.notes.ai.optimize" : "repo.notes.ai.generate"
    }

    private var generateHelpKey: LocalizedStringKey {
        hasExistingNote ? "repo.notes.ai.optimizeHelp" : "repo.notes.ai.generateHelp"
    }
}

/// 展开后的完整跟踪器。草稿始终与正式编辑 buffer 分离，只能通过确认回调应用。
struct RepoNoteAIGenerationPanel: View {
    let viewModel: RepoNoteAIGenerationViewModel
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onDiscard: () -> Void
    let onApply: () -> Void

    @State private var isDraftExpanded: Bool = true

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
                RepoNoteAIDraftDisclosure(
                    markdown: viewModel.draftMarkdown,
                    isExpanded: $isDraftExpanded
                )
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
                // 完成态是明确的成功反馈，按产品要求使用绿色，不作为普通强调色复用。
                .foregroundStyle(.green)
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

/// AI 草稿的可折叠 Markdown 预览。标题整行可点击，符合详情页折叠交互规范。
struct RepoNoteAIDraftDisclosure: View {
    let markdown: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text("repo.notes.ai.draftTitle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            if isExpanded {
                ScrollView {
                    Markdown(markdown)
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
        }
    }
}
