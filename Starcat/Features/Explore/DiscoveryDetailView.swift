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
    let supplementalHeader: AnyView?

    init(item: DiscoveryRepoDTO?, supplementalHeader: AnyView? = nil) {
        self.item = item
        self.supplementalHeader = supplementalHeader
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let item {
                DiscoveryScaffoldShell(item: item, supplementalHeader: supplementalHeader)
                    // 同一仓库刷新后 repoID 不变，但 description 和 GitHub 时间可能补齐；
                    // 完整快照作为 identity 可重建内部 @State，避免继续显示旧的空元数据。
                    .id(item)
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
    let supplementalHeader: AnyView?

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
        // 同一仓库的 Awesome 缓存刷新只会改变 description / createdAt / updatedAt 等元数据，
        // repoID 不变；任务必须跟随完整快照，否则 @State 会继续展示刷新前的空字段。
        .task(id: item) {
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
                VStack(spacing: 0) {
                    if let supplementalHeader {
                        supplementalHeader
                        Divider()
                    }
                    DiscoveryReadmeContent(repo: repo, onScrollReport: onScrollReport)
                        .environment(readmeVM)
                }
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
        // Discovery 详情必须以服务端最新公共元数据为准。若先返回本地 starred 缓存，
        // 老记录中缺失的 subscribers / created_at / updated_at 会永久遮蔽 API 真值。
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

        await homeViewModel.refreshAfterExternalStarChange()
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
