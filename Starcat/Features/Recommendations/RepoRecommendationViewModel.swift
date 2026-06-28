//
//  RepoRecommendationViewModel.swift
//  Starcat
//
//  仓库详情页相似推荐状态机。
//
//  关键约束：
//  - 推荐是详情页的附加能力，加载失败不能影响 README / notes / release 等主内容。
//  - 点击本地已 star repo 时切到 Manage 的 All Stars 并选中该 repo，保证能打开本地详情；
//    未命中本地 starred repo 时才打开 GitHub 页面。
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class RepoRecommendationViewModel {
    private(set) var items: [RepoRecommendationItem] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    private(set) var hasMore = false

    private var loadedRepoID: Int64?
    private var nextOffset: Int?
    private let pageSize = 10

    var hasItems: Bool { !items.isEmpty }

    func loadInitial(repoID: Int64, api: RecommendAPI) async {
        guard repoID > 0 else {
            reset()
            return
        }
        guard loadedRepoID != repoID else { return }

        loadedRepoID = repoID
        items = []
        hasMore = false
        nextOffset = nil
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await api.fetchRecommendations(repoID: repoID, limit: pageSize, offset: 0)
            guard loadedRepoID == repoID else { return }
            items = page.items
            hasMore = page.hasMore
            nextOffset = page.nextOffset
        } catch is CancellationError {
            // SwiftUI 快速切换 repo 时取消旧任务是正常路径。
        } catch {
            guard loadedRepoID == repoID else { return }
            errorMessage = error.localizedDescription
            AppLog.network.warning("recommend: load failed for repo \(repoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadMore(api: RecommendAPI) async {
        guard let repoID = loadedRepoID, let nextOffset, hasMore, !isLoadingMore else { return }

        isLoadingMore = true
        errorMessage = nil
        defer { isLoadingMore = false }

        do {
            let page = try await api.fetchRecommendations(repoID: repoID, limit: pageSize, offset: nextOffset)
            guard loadedRepoID == repoID else { return }
            items.append(contentsOf: page.items)
            hasMore = page.hasMore
            self.nextOffset = page.nextOffset
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
            AppLog.network.warning("recommend: load more failed for repo \(repoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func open(
        _ item: RepoRecommendationItem,
        repoRepository: any RepoRepositoryProtocol,
        homeViewModel: HomeViewModel
    ) async {
        do {
            if let localRepo = try await repoRepository.findById(item.repoID), localRepo.isStarred {
                homeViewModel.selection = .allStars
                homeViewModel.shouldScrollSelectedRepoIntoView = true
                homeViewModel.selectedRepoID = localRepo.id
                homeViewModel.ensureRepoVisible(repoId: localRepo.id)
                return
            }
        } catch {
            AppLog.database.warning("recommend: local repo lookup failed for \(item.repoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        if let url = item.githubURL {
            NSWorkspace.shared.open(url)
        }
    }

    private func reset() {
        loadedRepoID = nil
        nextOffset = nil
        items = []
        hasMore = false
        errorMessage = nil
        isLoading = false
        isLoadingMore = false
    }
}
