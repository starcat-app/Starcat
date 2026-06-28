//
//  RepoRecommendationPopover.swift
//  Starcat
//
//  相似仓库推荐列表 popover。
//
//  设计契约（Q4 决策）：
//  - 卡片层 100% 复用 `UnifiedRepoRow` + `RepoCardViewData`，与主 repo 列表视觉完全同形
//  - 分数走 `SemanticScoreBadge`（Q5 决策），通过 `RepoRecommendationItem.asSemanticSearchHit()`
//    适配层构造 `SemanticSearchHit`
//  - 容器高度自适应（Q6 决策）：固定宽度 400pt，垂直方向 idealHeight 500pt / maxHeight 600pt
//  - 顶部安静 header（Q8 决策）：图标 + 标题 + count 数字
//  - empty/loading 跟主列表看齐（Q10 决策）：skeleton 用 `RepoRowSkeletonView`
//  - 点击交互（Q7 决策）：单击替换详情，Cmd+点击打开 GitHub URL 在系统浏览器
//
//  旧版本的 `RepoRecommendationCard` 自定义 layout 已删除（Q4 + 铁律 #1）。
//

import SwiftUI
import AppKit

struct RepoRecommendationPopover: View {
    let items: [RepoRecommendationItem]
    let hasMore: Bool
    let isLoading: Bool
    let isLoadingMore: Bool
    let errorMessage: String?
    let onOpen: (RepoRecommendationItem) -> Void
    let onOpenInNewWindow: (RepoRecommendationItem) -> Void
    let onLoadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 400)
        .frame(minHeight: 200, idealHeight: 500)
        .frame(maxHeight: 600)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("repo.recommendations.title")
                .font(.headline)
            Spacer()
            Text(String(format: String.l10n("repo.recommendations.countFormat"), items.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            // items 为空：要么是 loading（skeleton），要么是空态
            if isLoading {
                skeletonList
            } else {
                emptyState
            }
        } else {
            cardList
        }
    }

    @ViewBuilder
    private var skeletonList: some View {
        // 与主 repo 列表 skeleton 完全同形（5 行），保证 loading → list 切换无视觉跳变
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<5, id: \.self) { _ in
                RepoRowSkeletonView()
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var cardList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(items) { item in
                    cardView(for: item)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }

                if hasMore {
                    loadMoreButton
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func cardView(for item: RepoRecommendationItem) -> some View {
        let card = item.asCardData()
        let hit = item.asSemanticSearchHit()

        Button {
            // Cmd+点击 = 新窗口（用系统浏览器打开 GitHub URL，与主列表的 Cmd+点击行为一致）
            // 单击 = 替换当前详情（用 ViewModel.open 走「本地 starred → 切 Manage / 其它 → 浏览器」流程）
            if NSEvent.modifierFlags.contains(.command) {
                onOpenInNewWindow(item)
            } else {
                onOpen(item)
            }
        } label: {
            UnifiedRepoRow(card: card, semanticHit: hit)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var loadMoreButton: some View {
        Button(action: onLoadMore) {
            HStack(spacing: 6) {
                if isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                }
                Text(LocalizedStringKey(isLoadingMore ? "repo.recommendations.loadingMore" : "repo.recommendations.more"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isLoadingMore)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        // Q10 决策：与主列表同形态——「暂无推荐」+ ⓘ hover 说明
        VStack(spacing: 10) {
            Text("repo.recommendations.empty.title")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(Text("repo.recommendations.empty.info"))
                Text("repo.recommendations.empty.info")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }
}
