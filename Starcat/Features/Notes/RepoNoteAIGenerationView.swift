//
//  RepoNoteAIGenerationView.swift
//  Starcat
//
//  笔记抽屉内的 AI 生成入口和步骤进度。
//

import SwiftUI

/// 生成入口位于编辑工具栏。启动后，正文区切换到步骤与草稿。
///
/// 视觉对齐 `PillSegmentedControl` compact 选中项（README / Insights）：外框胶囊 +
/// 内嵌选中 pill；悬停时加深内底并加 accent 描边，作为「光标聚焦」反馈（禁用系统蓝框）。
struct RepoNoteAIGenerationHeaderControl: View {
    let viewModel: RepoNoteAIGenerationViewModel
    let hasExistingNote: Bool
    let onGenerate: () -> Void

    /// 与详情页 README / Insights 切换器同密度，避免同屏两套胶囊尺寸。
    private static let pillSize: PillSegmentedControlSize = .compact

    @State private var isHovered = false
    @Environment(\.starcatReduceMotion) private var reduceMotion

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
                .font(.system(size: Self.pillSize.fontSize, weight: .medium))
                .labelStyle(.iconOnly)
                .foregroundStyle(.primary)
                .padding(.horizontal, Self.pillSize.horizontalPadding)
                .padding(.vertical, Self.pillSize.verticalPadding)
                // 常驻「选中 Insights」同款内嵌 pill，不再依赖 hover 才出现底色。
                .background(
                    Color.primary.opacity(isHovered ? 0.16 : 0.10),
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .padding(Self.pillSize.chromePadding)
        .background(Color.secondary.opacity(0.08), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    isHovered
                        ? Color.accentColor.opacity(0.55)
                        : Color.secondary.opacity(0.15),
                    lineWidth: isHovered ? 1 : 0.5
                )
        }
        .pointerStyle(.link)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onDisappear { isHovered = false }
        .help(Text(generateHelpKey))
        .accessibilityLabel(Text(generateTitleKey))
        .accessibilityHint(Text(generateHelpKey))
    }

    private var generateTitleKey: LocalizedStringKey {
        hasExistingNote ? "repo.notes.ai.optimize" : "repo.notes.ai.generate"
    }

    private var generateHelpKey: LocalizedStringKey {
        hasExistingNote ? "repo.notes.ai.optimizeHelp" : "repo.notes.ai.generateHelp"
    }
}

/// 步骤列表本身不滚动，由抽屉的正文区承载步骤与生成中的内容。
struct RepoNoteAIProgress: View {
    let viewModel: RepoNoteAIGenerationViewModel

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(RepoNoteAIGenerationStep.allCases) { step in
                stepRow(step)
            }
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
            stepDuration(step: step, state: state)
            Text(LocalizedStringKey(stateTitleKey(state)))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    /// 只让真正执行任务的 running 行定时刷新。“等待确认”取决于用户操作，
    /// 它的停留时间不是系统耗时，因此保留列宽但不显示任何数值。
    @ViewBuilder
    private func stepDuration(
        step: RepoNoteAIGenerationStep,
        state: RepoNoteAIGenerationStepState
    ) -> some View {
        if step == .awaitingConfirmation {
            Color.clear
                .frame(width: 54, height: 1)
                .accessibilityHidden(true)
        } else if state == .running {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                stepDurationText(for: step)
            }
        } else {
            stepDurationText(for: step)
        }
    }

    private func stepDurationText(for step: RepoNoteAIGenerationStep) -> some View {
        Group {
            if let duration = viewModel.elapsedDuration(for: step) {
                Text(String(
                    format: String.l10n("repo.notes.ai.duration.format"),
                    locale: locale,
                    duration
                ))
            } else {
                // pending / skipped 都没有实际执行时段，用破折号避免伪造 0 秒。
                Text(verbatim: "—")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 54, alignment: .trailing)
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
}
