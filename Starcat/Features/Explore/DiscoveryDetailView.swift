//
//  DiscoveryDetailView.swift
//  Starcat
//
//  探索页右栏详情。
//
//  设计意图：
//  - Discovery 列表来自公共探索后端，详情页不直接写入本地 repos 主表；
//  - README 渲染复用 owner/repo 维度的公共缓存链路，与 Trending 语义一致；
//  - Star 行为仍复用 StarActionService，成功后由 GitHub 真值写入本地数据库。
//

import SwiftUI

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
    @State private var readmeVM: ReadmeViewModel?

    var body: some View {
        Group {
            if let displayRepo, let readmeVM {
                scaffold(for: displayRepo, readmeVM: readmeVM)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.repoID) {
            await resolveRepo()
            loadReadmeIfNeeded()
        }
    }

    private func scaffold(for repo: Repo, readmeVM: ReadmeViewModel) -> some View {
        RepoDetailScaffold(
            repo: repo,
            viewData: RepoDetailViewData(
                hero: RepoDetailHero(repo: repo),
                trailingActions: trailingActions(for: repo),
                translation: repo.id != 0 ? ReadmeTranslationContext(fullName: repo.fullName) : nil,
                backendHint: nil
            ),
            starHelpKey: repo.isStarred ? "repo.unstar" : "repo.star",
            onStarTapped: {
                try await handleStarTapped(repo: repo)
            },
            body: { onScrollReport in
                DiscoveryReadmeContent(repo: repo, onScrollReport: onScrollReport)
                    .environment(readmeVM)
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
        loadReadmeIfNeeded()
    }

    private func ensureReadmeViewModel() -> ReadmeViewModel {
        if let readmeVM {
            return readmeVM
        }
        let model = ReadmeViewModel(
            api: dependencies.readmeAPI,
            availability: dependencies.readmeAvailability
        )
        readmeVM = model
        return model
    }

    private func loadReadmeIfNeeded() {
        guard let repo = displayRepo else {
            readmeVM?.reset()
            return
        }
        ensureReadmeViewModel().loadTrending(
            owner: repo.owner,
            repo: repo.name,
            isLoggedIn: authSession.state.isAuthenticated
        )
    }
}

private struct DiscoveryReadmeContent: View {

    let repo: Repo
    let onScrollReport: (RepoDetailScrollReport) -> Void

    @Environment(ReadmeViewModel.self) private var readmeVM
    @Environment(ReadmeTranslationViewModel.self) private var translationVM
    @Environment(AppSettings.self) private var settings
    @Environment(AuthSession.self) private var authSession

    var body: some View {
        ReadmeStateView(
            state: readmeVM.state,
            contentScope: .trending(owner: repo.owner, repo: repo.name),
            baseURL: URL(string: repo.htmlUrl).map(ReadmeWebView.repositoryContentBaseURL),
            onScrollReportChange: onScrollReport,
            // Discovery repo 是公共探索快照，README 缓存必须按 owner/repo 走 trending 路径。
            // 翻译缓存已经是磁盘 owner/repo 维度，和未 star 的公开 repo 语义一致。
            translationControl: repo.id != 0 ? ReadmeTranslationControl(
                repo: repo,
                translationVM: translationVM,
                settings: settings
            ) : nil
        ) {
            readmeVM.loadTrending(
                owner: repo.owner,
                repo: repo.name,
                isLoggedIn: authSession.state.isAuthenticated,
                forceRefresh: true
            )
        } onLogin: {
            authSession.requestLoginSheet()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
