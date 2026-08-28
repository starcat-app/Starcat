//
//  GitHubStarListUngroupedBanner.swift
//  Starcat
//
//  未分组视图顶部「开始 AI 分组整理」入口横幅。
//
//  模块职责：
//  - 在 RepoListView 选中「未分组」时，于中栏列表顶部展示与未分类横幅同构的入口。
//  - 展示未分组仓库总量 +「开始整理」按钮；点击后由 HomeView 打开现有分组审核 sheet。
//
//  关键约束：
//  - 只负责入口外观与点击转发，不持有 sheet / 付费墙状态。
//  - 数量用侧栏同源的 ungrouped 总量，而不是当前列表 items.count，避免搜索过滤把入口语义缩小。
//  - 数量为 0 或未登录时按钮灰掉，横幅仍显示，方便用户理解这个分类可以做什么。
//

import SwiftUI

struct GitHubStarListUngroupedBanner: View {

    let ungroupedCount: Int
    let isLoggedIn: Bool
    let onStart: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String.l10n("githubStarLists.ungroupedBanner.titleFormat"), ungroupedCount))
                    .font(.subheadline.weight(.medium))
                Text("githubStarLists.ungroupedBanner.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                onStart()
            } label: {
                Label("batchAI.banner.start", systemImage: "play.fill")
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
            .disabled(!canStart)
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

    /// 没有可整理对象，或还没登录 GitHub，点下去也打不开有效分组流程。
    private var canStart: Bool {
        ungroupedCount > 0 && isLoggedIn
    }
}
