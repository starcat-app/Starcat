//
//  BatchAIQueuePanel.swift
//  Starcat
//
//  HOM-52 - 批量整理进度浮动面板。
//
//  模块职责：
//  - 展示当前批次的总进度、剩余时间、当前 repo、单 job 状态列表（可滚动）。
//  - 提供暂停 / 继续 / 取消 / 单项重试 / 重试全部 控件。
//  - 完成后允许用户关闭并 reset 队列。
//
//  关键约束：
//  - 状态列表用 ScrollView + LazyVStack 强行限定最大高度 320pt，避免"处理 1000 项时 UI 爆炸"
//    （dong4j 2026-06-06 16:13 评审第 3 条）。
//  - 面板用 .sheet 承载：关闭面板不会停止队列（队列继续在后台跑，再开面板可恢复观察），
//    对应"支持后台继续"验收点。
//  - 区分三档终态视觉：completed=绿色 / ignored=灰色 / failed=红色，搭配文字补充原因。
//

import SwiftUI

struct BatchAIQueuePanel: View {

    @Bindable var service: BatchAIQueueService

    /// 调用方提供的关闭回调（关闭 sheet）。
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            progressSummary
            Divider()
            jobList
                .frame(minHeight: 200, maxHeight: 320)
            if service.failedCount > 0 {
                Divider()
                failedFooter
            }
        }
        .frame(width: 520)
        .padding(0)
    }

    // MARK: - 顶部 header（标题 + 操作按钮）

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("batchAI.panel.title")
                .font(.headline)
            Spacer()
            if !service.isFinished, service.isRunning {
                if service.isPaused {
                    Button {
                        service.resume()
                    } label: {
                        Label("batchAI.panel.resume", systemImage: "play.fill")
                            .labelStyle(.iconOnly)
                    }
                    .help("batchAI.panel.resume")
                } else {
                    Button {
                        service.pause()
                    } label: {
                        Label("batchAI.panel.pause", systemImage: "pause.fill")
                            .labelStyle(.iconOnly)
                    }
                    .help("batchAI.panel.pause")
                }
                Button(role: .destructive) {
                    service.cancel()
                } label: {
                    Label("batchAI.panel.cancel", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
                .help("batchAI.panel.cancel")
            }
            Button {
                if service.isFinished {
                    service.reset()
                }
                onClose()
            } label: {
                Label("general.close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .help("general.close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 进度摘要

    private var progressSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text(String(format: String(localized: "batchAI.panel.progressFormat"), service.finishedCount, service.totalCount))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                if service.isPaused {
                    Text("batchAI.panel.paused")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.yellow.opacity(0.2), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let remaining = service.estimatedTimeRemaining, !service.isFinished, remaining > 0 {
                    Label {
                        Text(formattedRemaining(remaining))
                            .font(.caption.monospacedDigit())
                    } icon: {
                        Image(systemName: "clock")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .tint(service.failedCount > 0 ? .orange : .accentColor)
            currentJobLabel
            countersRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var currentJobLabel: some View {
        if let currentId = service.currentJobId,
           let currentJob = service.jobs.first(where: { $0.repoId == currentId }) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(String(format: String(localized: "batchAI.panel.currentFormat"), currentJob.repoFullName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if service.isFinished {
            Label("batchAI.panel.finished", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private var countersRow: some View {
        HStack(spacing: 14) {
            counter(label: "batchAI.panel.counter.completed", count: service.completedCount, color: .green)
            if service.ignoredCount > 0 {
                counter(label: "batchAI.panel.counter.ignored", count: service.ignoredCount, color: .gray)
            }
            if service.failedCount > 0 {
                counter(label: "batchAI.panel.counter.failed", count: service.failedCount, color: .red)
            }
            Spacer()
        }
    }

    private func counter(label: LocalizedStringKey, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption)
            Text(verbatim: "\(count)").font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 状态列表（可滚动）

    private var jobList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(service.jobs) { job in
                    JobRow(job: job, onRetry: {
                        service.retry(jobId: job.repoId)
                    })
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    // MARK: - 失败底栏

    private var failedFooter: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(String(format: String(localized: "batchAI.panel.failedSummaryFormat"), service.failedCount))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("batchAI.panel.retryAll") {
                service.retryAllFailed()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
    }

    // MARK: - 派生

    private var progressFraction: Double {
        guard service.totalCount > 0 else { return 0 }
        return Double(service.finishedCount) / Double(service.totalCount)
    }

    private func formattedRemaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: String(localized: "batchAI.panel.remainingSecondsFormat"), Int(seconds.rounded()))
        }
        let minutes = Int((seconds / 60).rounded())
        return String(format: String(localized: "batchAI.panel.remainingMinutesFormat"), minutes)
    }
}

// MARK: - JobRow

/// 单 job 行：图标 + repo 名 + 状态文本 + 右侧 retry 按钮（仅 failed 显示）。
///
/// 性能：用 LazyVStack 懒加载，行内只渲染轻量元素（无 markdown / 图像）。
/// 大批次（1000+）滚动时也只渲染可视行，不会爆 CPU。
private struct JobRow: View {
    let job: BatchAIJob
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: job.repoFullName)
                    .font(.subheadline.monospaced())
                    .lineLimit(1)
                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 6)

            if job.status == .failed {
                Button {
                    onRetry()
                } label: {
                    Text("batchAI.panel.retry")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case .queued:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .processing:
            ProgressView()
                .controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .ignored:
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.gray)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    /// 副标题：根据状态拼接（已应用标签 / 被忽略的标签 / 错误信息）。
    private var detailText: String? {
        switch job.status {
        case .queued:
            return nil
        case .processing:
            return String(localized: "batchAI.panel.row.processing")
        case .completed:
            if !job.appliedTagNames.isEmpty {
                let tagsStr = job.appliedTagNames.prefix(5).joined(separator: ", ")
                return String(format: String(localized: "batchAI.panel.row.appliedTagsFormat"), tagsStr)
            }
            return job.didGenerateSummary
                ? String(localized: "batchAI.panel.row.summaryOnly")
                : String(localized: "batchAI.panel.row.completedNoTags")
        case .ignored:
            let names = job.ignoredTagsBelowThreshold.prefix(3).map { suggestion in
                "\(suggestion.name)(\(Int((suggestion.confidence * 100).rounded()))%)"
            }.joined(separator: ", ")
            return String(format: String(localized: "batchAI.panel.row.ignoredFormat"), names)
        case .failed:
            return job.errorMessage ?? String(localized: "batchAI.panel.row.failedUnknown")
        }
    }
}
