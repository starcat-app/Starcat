//
//  BatchStarConfirmSheet.swift
//  Starcat
//
//  批量 star / unstar 的确认 sheet（W12 toolbar 专项 PR-3）。
//
//  触发条件：批量操作 **> 5 条** 时强制弹出确认 sheet，让用户：
//  - 看到完整的目标 repo 列表（owner/name）；
//  - 看到预计跳过条数（已是目标态）；
//  - 看到预计耗时（每条 200ms 节流 + 网络 RTT 估算）；
//  - 决定确认 / 取消。
//
//  关键约束：
//  - 仅作 UI 容器，不做业务执行：用户点确认后通过回调 `onConfirm` 通知调用方启动
//    `BatchStarService.enqueue(...)`；
//  - 跳过 / 耗时是「预估值」：用 registry 当前状态算 skipped 预估，可能与实际执行时
//    不完全一致（用户操作期间 star 状态可能变），但对用户决策已足够准确。
//

import SwiftUI

/// 批量 star / unstar 确认 sheet。
struct BatchStarConfirmSheet: View {

    /// 操作类型，影响标题 / 按钮颜色与文案。
    let action: BatchStarService.Action
    /// 目标列表（W12 PR-4 改用 `BatchStarTarget`，与 BatchStarService 入参对齐）。
    let targets: [BatchStarTarget]
    /// 跳过预估（已是目标态的条数）。
    let estimatedSkipped: Int
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// 节流 + 网络 RTT 简单估算：每条 200ms 节流 + 250ms RTT 兜底。
    private var estimatedSeconds: Int {
        let effectiveCount = max(targets.count - estimatedSkipped, 0)
        let perItemMs = 200 + 250
        return max(Int((Double(effectiveCount) * Double(perItemMs)) / 1000.0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                summaryRow(label: "batch.confirm.targets", value: "\(targets.count)")
                if estimatedSkipped > 0 {
                    summaryRow(label: "batch.confirm.estSkipped", value: "\(estimatedSkipped)")
                }
                summaryRow(label: "batch.confirm.estDuration", value: String(format: String.l10n("batch.confirm.estDurationSecondsFormat"), estimatedSeconds))
            }
            .font(.subheadline)

            repoListPreview

            Divider()

            HStack {
                Spacer()
                Button("general.cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)

                Button {
                    onConfirm()
                } label: {
                    Label(confirmLabelKey, systemImage: confirmIconName)
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .tint(action == .unstar ? .red : .accentColor)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleKey)
                .font(.headline)
            Text(subtitleKey)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 最多展示前 10 个 repo，超过时折叠为「... 还有 N 个」。
    private var repoListPreview: some View {
        let previewCount = 10
        let preview = targets.prefix(previewCount)
        let remaining = max(targets.count - previewCount, 0)

        return ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(preview) { target in
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 4))
                            .foregroundStyle(.tertiary)
                        Text(verbatim: target.fullName)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if remaining > 0 {
                    Text(String(format: String.l10n("batch.confirm.moreReposFormat"), remaining))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: 180)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private func summaryRow(label: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value)
                .monospacedDigit()
        }
    }

    // MARK: - 文案派生

    private var titleKey: LocalizedStringKey {
        switch action {
        case .star:   return "batch.confirm.starTitle"
        case .unstar: return "batch.confirm.unstarTitle"
        }
    }

    private var subtitleKey: LocalizedStringKey {
        switch action {
        case .star:   return "batch.confirm.starSubtitle"
        case .unstar: return "batch.confirm.unstarSubtitle"
        }
    }

    private var confirmLabelKey: LocalizedStringKey {
        switch action {
        case .star:   return "batch.star"
        case .unstar: return "batch.unstar"
        }
    }

    private var confirmIconName: String {
        switch action {
        case .star:   return "star.fill"
        case .unstar: return "star.slash.fill"
        }
    }
}
