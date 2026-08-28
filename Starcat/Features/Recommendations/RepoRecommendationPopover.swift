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
//  - 点击交互（v1.1 修订）：所有点击（单击 / Cmd+点击 / 中键）都走 `onOpen`——
//    由 Scaffold 决定是开新 Starcat 窗（已 star）还是开浏览器 GitHub URL（非本地）。
//    早期 Q7 的「单击 in-place / Cmd+开窗」拆分为已废弃，统一行为更简单。
//
//  v1.1 修订（2026-06-29）：
//  - items 改为 `[(item, card, hit)]` 预转换三元组，由 Scaffold 在 popover builder 里
//    用 `StarredRegistry` 一次性转好；popover 不再访问 registry / 不再 `asCardData()` 调用
//  - UnifiedRepoRow 加 `showStarredCheckmark: true` —— 已 star 的推荐项显示绿 ✓（与
//    Trending 列表完全同形）
//  - onOpenInNewWindow 闭包删除（Q3 决策：单击/Cmd/中键 行为统一）
//
//  旧版本的 `RepoRecommendationCard` 自定义 layout 已删除（Q4 + 铁律 #1）。
//

import SwiftUI
import AppKit

/// 推荐卡片 popover 的单个 item 元组（item + 预转换 card + 预转换 hit）。
///
/// 在 Scaffold 的 popover builder 里一次性用 `StarredRegistry` 把 `RepoRecommendationItem`
/// 转成 `RepoCardViewData`（含 `isStarred`），popover 内不再访问 registry / 不再调
/// `asCardData()`，让 popover 保持「无副作用展示」的纯渲染状态。
struct RecommendationCard: Identifiable {
    let item: RepoRecommendationItem
    let card: RepoCardViewData
    let hit: SemanticSearchHit

    var id: Int64 { item.repoID }
}

struct RepoRecommendationPopover: View {
    let items: [RecommendationCard]
    let hasMore: Bool
    let isLoading: Bool
    let isLoadingMore: Bool
    let errorMessage: String?
    let onOpen: (RepoRecommendationItem) -> Void
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
                ForEach(items) { recommendation in
                    cardView(for: recommendation)
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
    private func cardView(for recommendation: RecommendationCard) -> some View {
        Button {
            // v1.1 修订：所有点击（单击 / Cmd / 中键）都走 onOpen。
            // Scaffold 在闭包里决定是开新 Starcat 窗（已 star）还是开浏览器
            // GitHub URL（非本地），与主列表的 Cmd+点击「在系统浏览器打开」分流
            // 在调用层完成，popover 不关心具体路由。
            onOpen(recommendation.item)
        } label: {
            // showStarredCheckmark: true 让 UnifiedRepoRow 在已 star 的推荐项上
            // 渲染绿色 ✓（与 Trending 列表完全同形）
            UnifiedRepoRow(
                card: recommendation.card,
                semanticHit: recommendation.hit,
                semanticScoreFormatKey: "search.detail.score.format",
                showStarredCheckmark: true
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    @ViewBuilder
    private var loadMoreButton: some View {
        HStack {
            Spacer()
            Button(action: onLoadMore) {
                HStack(spacing: 6) {
                    if isLoadingMore {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                    }
                    if isLoadingMore {
                        Text("repo.recommendations.loadingMore")
                    } else {
                        Text("repo.recommendations.more")
                    }
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(isLoadingMore)
            Spacer()
        }
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
