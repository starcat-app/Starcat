//
//  ActivityReleaseDetailScaffoldShell.swift
//  Starcat
//
//  活动页「发行版」详情的 repo-backed 外壳。
//
//  设计约束：
//  - 上半部分必须复用 `RepoDetailScaffold` / `RepoMetadataHeaderView`，与活动页
//    星标 / 仓库 / 建议三个 repo-backed 分类保持同一套数据、样式、折叠和入场动画。
//  - 本文件只替换 body slot：README WebView 换成该 repo 的 Release notes Markdown 时间线。
//  - Release 列表首帧来自 `ActivityItem.releases`，随后按 repoId 从本地缓存刷新一次，
//    避免详情页打开时出现空白或额外网络等待。
//

import SwiftUI

struct ActivityReleaseDetailScaffoldShell: View {

    let item: ActivityItem

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(HomeViewModel.self) private var homeViewModel

    @State private var displayRepo: Repo?
    @State private var releases: [ReleaseRecord]
    @State private var isRefreshing = false

    init(item: ActivityItem) {
        self.item = item
        _releases = State(initialValue: item.releases)
    }

    var body: some View {
        Group {
            if let displayRepo {
                scaffold(repo: displayRepo)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.id) {
            displayRepo = item.repo
            releases = item.releases
            await reloadReleases()
        }
        .starcatRefreshCommand(
            pane: .detail,
            identity: "activity-release-\(item.id)-\(isRefreshing)",
            title: String.l10n("commands.actions.refreshCurrentDetail"),
            isEnabled: !isRefreshing && item.repo != nil
        ) {
            refreshReleaseDetail()
        }
    }

    @ViewBuilder
    private func scaffold(repo: Repo) -> some View {
        RepoDetailScaffold(
            repo: repo,
            viewData: RepoDetailViewData(
                hero: RepoDetailHero(repo: repo),
                trailingActions: trailingActions(for: repo),
                translation: nil,
                backendHint: nil,
                headerSourceBadge: latestReleaseBadge
            ),
            fallbackAccentColor: item.category.iconColor,
            starHelpKey: repo.isStarred ? "repo.unstar" : "repo.star",
            onStarTapped: {
                try await handleStarTapped(repo: repo)
            }
        ) { onScrollReport in
            ActivityReleaseDetailContent(
                repo: repo,
                releases: releases,
                onScrollReport: onScrollReport
            )
        }
    }

    private var latestReleaseBadge: RepoDetailHeaderSourceBadge? {
        guard let latest = releases.first,
              let date = Self.releaseDate(latest) else { return nil }
        return RepoDetailHeaderSourceBadge(
            systemImage: "calendar",
            label: Self.absoluteDate(date),
            url: URL(string: latest.htmlUrl),
            help: String.l10n("activity.release.latestPublishedAt")
        )
    }

    private func trailingActions(for repo: Repo) -> [RepoDetailAction] {
        guard repo.isStarred else {
            return []
        }
        // v2.0（2026-06-16, dong4j）：OpenSSF 入口迁移到 hero `full_name` 同行，
        // 不再放在 trailing actions 数组里。
        var actions: [RepoDetailAction] = []
        if authSession.state.isAuthenticated {
            actions.append(.share)
            actions.append(.ai)
        }
        return actions
    }

    private func reloadReleases() async {
        guard let repo = item.repo else { return }
        do {
            releases = try await dependencies.releaseRepository.fetch(forRepo: repo.id, limit: 200)
        } catch {
            AppLog.database.error("ActivityReleaseDetail: load releases failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Release 详情没有 README 状态栏，单独把当前仓库的本地 Release 时间线接入 `⌘R`。
    private func refreshReleaseDetail() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await reloadReleases()
            isRefreshing = false
        }
    }

    private func handleStarTapped(repo: Repo) async throws {
        guard authSession.state.isAuthenticated else {
            // 2026-06-29：只弹登录 sheet，不强制走 Device Flow
            authSession.requestLoginSheet()
            return
        }
        try await dependencies.starActionService.toggle(repo: repo)

        let nowStarred = dependencies.starredRegistry.contains(ghRepoId: repo.id)
        var updated = repo
        updated.isStarred = nowStarred
        displayRepo = updated

        await homeViewModel.refreshAfterExternalStarChange()
    }

    static func releaseDate(_ release: ReleaseRecord) -> Date? {
        ISO8601DateFormatter.shared.date(from: release.publishedAt ?? "")
            ?? ISO8601DateFormatter.shared.date(from: release.createdAtRemote ?? "")
            ?? ISO8601DateFormatter.shared.date(from: release.fetchedAt)
    }

    static func absoluteDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
