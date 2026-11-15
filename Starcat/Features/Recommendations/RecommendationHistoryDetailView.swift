//
//  RecommendationHistoryDetailView.swift
//  Starcat
//
//  历史仅补充推荐事实与反馈，README、Star、洞察继续复用现有探索详情。
//

import SwiftUI

/// 保持中栏历史选择，不通过 openCompanionRepository 跳回星标管理页。
struct RecommendationHistoryDetailView: View {
    let entry: RecommendationHistoryEntry?
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale
    private var explanationIdentity: String {
        "\(dependencies.database.currentUserId ?? 0)|\(dependencies.databaseScopeRevision)|\(entry?.id ?? 0)|\(locale.identifier)|\(dependencies.entitlementGate.isProUser)"
    }

    var body: some View {
        if let entry, let item = entry.item {
            DiscoveryDetailView(
                item: item.historyDiscoveryItem,
                supplementalHeader: AnyView(historyHeader(entry, item: item))
            )
            .task(id: explanationIdentity) {
                guard let accountID = dependencies.database.currentUserId else { return }
                await dependencies.dailyRecommendationExplanationStore.prepare(
                    item: item, accountID: accountID, revision: dependencies.databaseScopeRevision,
                    locale: locale.identifier, isPro: dependencies.entitlementGate.isProUser
                ) { input in
                    try await dependencies.repoAIInsightService.generateRecommendationReason(
                        input: input, outputLanguage: locale.identifier
                    )
                }
            }
        } else if entry != nil {
            ContentUnavailableView("recommendations.history.unavailable", systemImage: "archivebox")
        } else {
            RepoDetailNoSelectionPlaceholder(messageKey: "explore.detail.empty")
        }
    }

    /// 旧导入记录没有理由时明确说明缺失；只解释保存过的类型，不补造个人匹配证据。
    private func historyHeader(_ entry: RecommendationHistoryEntry, item: RepoRecommendationItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.dateText(locale: locale)).foregroundStyle(.secondary)
                Spacer()
                if entry.feedback(starredIDs: dependencies.starredRegistry.ids) == .dismissed {
                    Button("recommendations.history.restore") {
                        Task { await dependencies.dailyRecommendationStore.restoreInterest(entry.id) }
                    }
                } else if !dependencies.starredRegistry.contains(ghRepoId: entry.id) {
                    Button("recommendations.history.dismissed") {
                        Task { await dependencies.dailyRecommendationStore.dismiss(entry.id) }
                    }
                }
            }
            Text("recommendations.daily.reasonTitle").fontWeight(.semibold)
            if let explanation = dependencies.dailyRecommendationExplanationStore.text(
                for: item, locale: locale.identifier, isPro: dependencies.entitlementGate.isProUser
            ) {
                Text("recommendations.daily.aiReasonTitle").font(.caption).foregroundStyle(.secondary)
                Text(verbatim: explanation).fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: item.basicRecommendationReason)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(12)
    }
}

extension RepoRecommendationItem {
    /// 只做 DTO 适配；未提供的公共属性保持缺省，不触发收藏或私有入库。
    var historyDiscoveryItem: DiscoveryRepoDTO {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return DiscoveryRepoDTO(
            repoID: repoID, fullName: fullName, owner: parts.first ?? "",
            name: parts.count == 2 ? parts[1] : "", description: description,
            homepage: nil, language: language, stars: stars, forks: forks,
            watchers: 0, subscribers: 0, openIssues: 0, ownerAvatar: nil,
            defaultBranch: nil, licenseSpdx: nil, topics: [], platforms: [],
            pushedAt: nil, updatedAt: nil, createdAt: nil, isArchived: archived, isFork: false,
            latestReleaseTag: nil, latestReleaseAt: nil, latestReleaseURL: nil,
            releaseDownloadCount: 0, rank: nil, score: nil, reasons: reasons, signals: []
        )
    }
}
