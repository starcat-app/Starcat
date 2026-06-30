//
//  DiscoveryDetailView.swift
//  Starcat
//
//  探索页右栏详情。
//
//  设计意图：
//  - Discovery 列表来自公共探索后端，不直接复用 Trending README 缓存路径；
//  - 右栏先展示可解释信息：推荐原因、平台/主题、Release、关键指标；
//  - Star 行为仍复用 StarActionService，成功后由 GitHub 真值写入本地数据库。
//

import SwiftUI
import AppKit

struct DiscoveryDetailView: View {

    let item: DiscoveryRepoDTO?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let item {
                DiscoveryScaffoldShell(item: item)
                    .id(item.repoID)
                    .detailContentTransition()
            } else {
                RepoDetailNoSelectionPlaceholder(messageKey: "explore.detail.empty")
                    .id("explore-empty")
                    .detailContentTransition()
            }
        }
    }
}

private struct DiscoveryScaffoldShell: View {

    let item: DiscoveryRepoDTO

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel

    @State private var displayRepo: Repo?

    var body: some View {
        Group {
            if let displayRepo {
                scaffold(for: displayRepo)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.repoID) {
            await resolveRepo()
        }
    }

    private func scaffold(for repo: Repo) -> some View {
        RepoDetailScaffold(
            repo: repo,
            viewData: RepoDetailViewData(
                hero: RepoDetailHero(repo: repo),
                trailingActions: trailingActions(for: repo),
                translation: nil,
                backendHint: nil
            ),
            starHelpKey: repo.isStarred ? "repo.unstar" : "repo.star",
            onStarTapped: {
                try await handleStarTapped(repo: repo)
            },
            body: { onScrollReport in
                DiscoveryDetailContent(item: item, onScrollReport: onScrollReport)
            }
        )
    }

    private func trailingActions(for repo: Repo) -> [RepoDetailAction] {
        guard authSession.state.isAuthenticated, repo.isStarred else {
            return []
        }
        return [.share, .ai]
    }

    private func resolveRepo() async {
        do {
            if let local = try await dependencies.repoRepository.findByOwnerName(
                owner: item.owner,
                name: item.name
            ) {
                displayRepo = local
                return
            }
        } catch {
            AppLog.sync.error("discovery: local repo lookup failed: \(error.localizedDescription, privacy: .public)")
        }

        let isStarred = dependencies.starredRegistry.contains(ghRepoId: item.repoID)
        displayRepo = item.toEphemeralRepo(isStarred: isStarred)
    }

    private func handleStarTapped(repo: Repo) async throws {
        guard authSession.state.isAuthenticated else {
            authSession.requestLoginSheet()
            return
        }
        try await dependencies.starActionService.toggle(repo: repo)

        var updated = repo
        updated.isStarred = dependencies.starredRegistry.contains(ghRepoId: repo.id)
        displayRepo = updated

        await homeViewModel.refreshSidebar()
        await homeViewModel.reloadItems(forceRefresh: true)
        await resolveRepo()
    }
}

private struct DiscoveryDetailContent: View {

    let item: DiscoveryRepoDTO
    let onScrollReport: (RepoDetailScrollReport) -> Void

    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !item.reasons.isEmpty {
                    detailSection(title: "explore.detail.reasons", systemImage: "sparkles") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(item.reasons, id: \.self) { reason in
                                Label {
                                    Text(verbatim: reason)
                                        .fixedSize(horizontal: false, vertical: true)
                                } icon: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }

                if !item.signals.isEmpty {
                    detailSection(title: "explore.detail.signals", systemImage: "waveform.path.ecg") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(item.signals, id: \.code) { signal in
                                signalCard(signal)
                            }
                        }
                    }
                }

                if !item.platforms.isEmpty || !item.topics.isEmpty {
                    detailSection(title: "explore.detail.taxonomy", systemImage: "square.grid.2x2") {
                        VStack(alignment: .leading, spacing: 12) {
                            if !item.platforms.isEmpty {
                                chipCloud(items: item.platforms, systemImage: "desktopcomputer")
                            }
                            if !item.topics.isEmpty {
                                chipCloud(items: item.topics, systemImage: "number")
                            }
                        }
                    }
                }

                if item.latestReleaseTag != nil || item.releaseDownloadCount > 0 {
                    detailSection(title: "explore.detail.release", systemImage: "shippingbox") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                if let tag = item.latestReleaseTag {
                                    MetaBadge(systemImage: "tag", text: tag, tint: .secondary)
                                }
                                if let date = item.latestReleaseDate {
                                    MetaBadge(
                                        systemImage: "clock",
                                        text: RelativeTimeText.pastEvent(date, locale: locale),
                                        tint: .secondary
                                    )
                                }
                                if item.releaseDownloadCount > 0 {
                                    MetaBadge(
                                        systemImage: "arrow.down.circle",
                                        text: item.releaseDownloadCount.formattedShort,
                                        tint: .secondary
                                    )
                                }
                            }

                            if let url = item.latestReleaseWebURL {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label("explore.detail.openRelease", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.borderless)
                                .focusEffectDisabled()
                            }
                        }
                    }
                }

                detailSection(title: "explore.detail.metrics", systemImage: "chart.bar") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], alignment: .leading, spacing: 10) {
                        metricCard(title: "repo.stats.stars", value: item.stars.formattedShort, systemImage: "star.fill")
                        metricCard(title: "repo.stats.forks", value: item.forks.formattedShort, systemImage: "tuningfork")
                        metricCard(title: "repo.stats.watchers", value: item.watchers.formattedShort, systemImage: "eye")
                        metricCard(title: "repo.stats.issues", value: item.openIssues.formattedShort, systemImage: "exclamationmark.circle")
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
        .detailScrollViewStyle()
        .onScrollGeometryChange(for: RepoDetailScrollReport.self) { geometry in
            let overflow = max(0, geometry.contentSize.height - geometry.containerSize.height)
            return RepoDetailScrollReport(
                offsetY: max(0, geometry.contentOffset.y),
                scrollOverflow: overflow
            )
        } action: { _, report in
            onScrollReport(report)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailSection<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func signalCard(_ signal: DiscoverySignalDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: signal.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: signal.value ?? "—")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func chipCloud(items: [String], systemImage: String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Label {
                    Text(verbatim: item)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: systemImage)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: Capsule(style: .continuous))
            }
        }
    }

    private func metricCard(title: LocalizedStringKey, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
