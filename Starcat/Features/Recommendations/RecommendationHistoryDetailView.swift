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
                supplementalHeader: AnyView(historyHeader(entry, item: item)),
                requiresCompleteMetadata: true
            )
            .task(id: explanationIdentity) {
                guard let accountID = dependencies.database.currentUserId else { return }
                await dependencies.dailyRecommendationExplanationStore.loadSaved(
                    items: [item], accountID: accountID, revision: dependencies.databaseScopeRevision,
                    locale: locale.identifier, isPro: dependencies.entitlementGate.isProUser
                )
            }
        } else if entry != nil {
            ContentUnavailableView("recommendations.history.unavailable", systemImage: "archivebox")
        } else {
            RepoDetailNoSelectionPlaceholder(messageKey: "explore.detail.empty")
        }
    }

    /// 折叠状态绑定所选项目，切到另一条历史时恢复折叠，把视口留给 README。
    private func historyHeader(_ entry: RecommendationHistoryEntry, item: RepoRecommendationItem) -> some View {
        RecommendationEvidenceHeader(entry: entry, item: item)
            .id(entry.id)
    }
}

/// 沿用 Awesome「收录来源」的整行展开交互；反馈按钮独立，不能点击反馈时误展开。
private struct RecommendationEvidenceHeader: View {
    let entry: RecommendationHistoryEntry
    let item: RepoRecommendationItem
    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel
    @Environment(\.locale) private var locale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var openingSourceID: Int64?
    @State private var sourceTask: Task<Void, Never>?
    @State private var sourceError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        BusinessIcon(.recommendations, pointSize: 16).foregroundStyle(.secondary)
                        Text("recommendations.daily.reasonTitle").font(.headline)
                        if let sources = item.matchedSeeds, !sources.isEmpty {
                            Text(sources.count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if !isExpanded, let name = item.matchedSeeds?.first?.fullName {
                            Text(verbatim: name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityValue(Text(LocalizedStringKey(isExpanded ? "settings.general.disclosure.expanded" : "settings.general.disclosure.collapsed")))
                feedbackButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let explanation = dependencies.dailyRecommendationExplanationStore.text(
                        for: item, locale: locale.identifier, isPro: dependencies.entitlementGate.isProUser
                    ) {
                        Text("recommendations.daily.aiReasonTitle").font(.caption).foregroundStyle(.secondary)
                        evidenceText(explanation)
                    } else {
                        evidenceText(item.basicRecommendationReason)
                    }
                    if openingSourceID != nil {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .toast(message: $sourceError, icon: "exclamationmark.triangle")
        .onDisappear { sourceTask?.cancel() }
    }

    /// 复用已有行内头像渲染器，保持正文自然换行；来源只认服务端提供的真实项目。
    private func evidenceText(_ text: String) -> some View {
        RAGMarkdownText(content: RecommendationEvidenceMarkdown.make(text: text, sources: item.matchedSeeds ?? []))
            .environment(\.openURL, OpenURLAction { url in
                guard let source = item.matchedSeeds?.first(where: {
                    url == GitHubURLs.repo(fullName: $0.fullName)
                }) else { return .handled }
                openSource(source)
                return .handled
            })
    }

    /// 查询和公开资料补齐都不改主窗口选择；异步完成后只把 Repo 交给独立窗口。
    private func openSource(_ source: RecommendationSeed) {
        guard openingSourceID == nil else { return }
        let parts = source.fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        openingSourceID = source.repoID
        sourceError = nil
        let revision = dependencies.databaseScopeRevision
        sourceTask = Task {
            defer { openingSourceID = nil }
            do {
                let repo = try await PublicRepoMetadataResolver.resolve(
                    owner: parts[0], name: parts[1],
                    repository: dependencies.repoRepository, apiClient: dependencies.apiClient,
                    isCurrent: { dependencies.databaseScopeRevision == revision }
                )
                try Task.checkCancellation()
                RepoDetailWindowController.show(repo: repo, dependencies: dependencies, homeViewModel: homeViewModel)
            } catch is CancellationError {
                return
            } catch {
                sourceError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var feedbackButton: some View {
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
