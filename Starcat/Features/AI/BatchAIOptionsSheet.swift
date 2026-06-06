//
//  BatchAIOptionsSheet.swift
//  Starcat
//
//  HOM-52 - 批量整理启动前的操作选择 Sheet。
//
//  模块职责：
//  - 让用户选择本次要跑哪些 AI 子任务（摘要 / 标签）。
//  - 让用户决定是否"自动应用推荐标签"+ 设置置信度阈值。
//  - 显示本次将处理的 repo 数量与简单时长估算。
//
//  关键约束：
//  - 默认值与 dong4j 2026-06-06 评审决议一致：actions=[summary,tags]、autoApply=false、threshold=0.90。
//  - 置信度滑条仅在 autoApplyTags 打开时显示，避免无谓配置项干扰。
//  - 启动按钮在 actions 为空 / repo 数为 0 时禁用，避免误触发。
//

import SwiftUI

struct BatchAIOptionsSheet: View {

    let pendingCount: Int
    @Binding var options: BatchAIQueueOptions
    let onCancel: () -> Void
    let onStart: () -> Void

    /// 平均每 repo 5-10s（依据 RepoAIInsightService 实测），取中位 8s 给用户一个"约 N 分钟"参考。
    /// 实际进度估算由 BatchAIQueueService.estimatedTimeRemaining 接管。
    private static let avgSecondsPerRepo: Double = 8.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            actionsSection

            autoApplySection

            Divider()

            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    // MARK: - 子视图

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                Text("batchAI.options.title")
                    .font(.headline)
            }
            Text(String(format: String(localized: "batchAI.options.subtitleFormat"), pendingCount))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            estimateLabel
        }
    }

    @ViewBuilder
    private var estimateLabel: some View {
        let seconds = Double(pendingCount) * Self.avgSecondsPerRepo
        let minutes = max(1, Int((seconds / 60).rounded(.up)))
        Text(String(format: String(localized: "batchAI.options.estimateFormat"), minutes))
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("batchAI.options.actionsLabel")
                .font(.subheadline.weight(.medium))

            ToggleRow(
                isOn: actionBinding(for: .summary),
                title: "batchAI.options.action.summary",
                subtitle: "batchAI.options.action.summary.desc",
                systemImage: "doc.text"
            )
            ToggleRow(
                isOn: actionBinding(for: .tags),
                title: "batchAI.options.action.tags",
                subtitle: "batchAI.options.action.tags.desc",
                systemImage: "tag"
            )
        }
    }

    @ViewBuilder
    private var autoApplySection: some View {
        let tagsEnabled = options.actions.contains(.tags)

        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $options.autoApplyTags) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("batchAI.options.autoApply")
                        .font(.subheadline.weight(.medium))
                    Text("batchAI.options.autoApply.desc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!tagsEnabled)

            if options.autoApplyTags, tagsEnabled {
                thresholdSlider
            }
        }
    }

    private var thresholdSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("batchAI.options.threshold")
                    .font(.caption)
                Spacer()
                Text(verbatim: percentString(options.confidenceThreshold))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $options.confidenceThreshold, in: 0.5...1.0, step: 0.05)
            Text(String(format: String(localized: "batchAI.options.threshold.hintFormat"), percentString(options.confidenceThreshold)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 28)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("general.cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button {
                onStart()
            } label: {
                Text(String(format: String(localized: "batchAI.options.startFormat"), pendingCount))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!options.isValidForStart || pendingCount == 0)
        }
    }

    // MARK: - 辅助

    /// 把 actions Set 投影成单个 Action 的 Toggle binding。
    /// Toggle 切换时 add/remove 即可，逻辑短小不抽函数。
    private func actionBinding(for action: BatchAIAction) -> Binding<Bool> {
        Binding(
            get: { options.actions.contains(action) },
            set: { newValue in
                if newValue {
                    options.actions.insert(action)
                } else {
                    options.actions.remove(action)
                }
            }
        )
    }

    private func percentString(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}

// MARK: - ToggleRow

/// "操作选择 Sheet"内复用的 Toggle 行：左图标 + 标题 + 副标题 + 右开关。
/// 不外迁到 Components/，因为只在本 sheet 使用且语义紧耦合。
private struct ToggleRow: View {
    let isOn: Binding<Bool>
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String

    var body: some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
    }
}
