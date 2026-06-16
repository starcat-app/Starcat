//
//  BatchAIUntaggedBanner.swift
//  Starcat
//
//  HOM-52 - Untagged 视图顶部"开始批量 AI 整理"入口横幅。
//
//  模块职责：
//  - 在 RepoListView 的 Untagged 视图顶部展示一个轻量横幅。
//  - 显示当前未分类仓库数 + 启动按钮 / 查看进度按钮。
//  - 与队列服务状态联动：进行中 / 已完成时按钮文案与图标变化。
//
//  关键约束：
//  - 仅在 selection == .untagged 时显示，避免污染其它视图。
//  - 队列已在跑时按钮变为"查看进度"，点击直接打开 panel（不要求重新选择 options）。
//

import SwiftUI

struct BatchAIUntaggedBanner: View {

    let untaggedCount: Int
    @Bindable var service: BatchAIQueueService

    let onStart: () -> Void
    let onShowPanel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String.l10n("batchAI.banner.titleFormat"), untaggedCount))
                    .font(.subheadline.weight(.medium))
                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            actionButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.tint.opacity(0.18))
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var actionButton: some View {
        if service.isRunning || (!service.jobs.isEmpty && !service.isFinished) {
            Button {
                onShowPanel()
            } label: {
                Label("batchAI.banner.viewProgress", systemImage: "rectangle.stack")
            }
            .controlSize(.regular)
        } else {
            Button {
                onStart()
            } label: {
                Label("batchAI.banner.start", systemImage: "play.fill")
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
            .disabled(untaggedCount == 0)
        }
    }

    /// 副标题：未运行时给提示，运行 / 完成时显示当前状态摘要。
    private var secondaryText: String {
        if service.isRunning {
            if service.isPaused {
                return String(format: String.l10n("batchAI.banner.runningPausedFormat"), service.finishedCount, service.totalCount)
            }
            return String(format: String.l10n("batchAI.banner.runningFormat"), service.finishedCount, service.totalCount)
        }
        if service.isFinished {
            return String(format: String.l10n("batchAI.banner.finishedFormat"), service.completedCount, service.failedCount)
        }
        return String.l10n("batchAI.banner.hint")
    }
}
