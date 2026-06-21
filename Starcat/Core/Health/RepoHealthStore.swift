//
//  RepoHealthStore.swift
//  Starcat
//
//  Repo Health UI 状态缓存。
//
//  Store 只给 SwiftUI 同步读取 badge，并把异步刷新委托给 RepoHealthService。
//  这样 view body 永远不 await，也不会因为详情页出现而阻塞布局。
//

import Foundation
import Observation

@MainActor
@Observable
final class RepoHealthStore {
    private let service: RepoHealthService
    private(set) var snapshots: [Int64: RepoHealthSnapshot] = [:]
    private var loadingRepoIDs: Set<Int64> = []

    init(service: RepoHealthService) {
        self.service = service
    }

    func badge(for repoId: Int64) -> RepoHealthBadgeData? {
        snapshots[repoId]?.badgeData
    }

    func snapshot(for repoId: Int64) -> RepoHealthSnapshot? {
        snapshots[repoId]
    }

    func isLoading(repoId: Int64) -> Bool {
        loadingRepoIDs.contains(repoId)
    }

    func loadCachedSnapshots(for repoIds: [Int64]) async {
        let missing = repoIds.filter { snapshots[$0] == nil }
        guard !missing.isEmpty else { return }
        do {
            let fetched = try await service.cachedSnapshots(for: missing)
            for (id, snapshot) in fetched {
                snapshots[id] = snapshot
            }
        } catch {
            AppLog.database.warning("RepoHealth cached snapshot load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func prefetchIfNeeded(repo: Repo, force: Bool = false) {
        guard !loadingRepoIDs.contains(repo.id) else { return }
        if let snapshot = snapshots[repo.id],
           !RepoHealthRefreshPolicy.shouldRefresh(snapshot, force: force) {
            return
        }

        loadingRepoIDs.insert(repo.id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingRepoIDs.remove(repo.id) }
            do {
                let snapshot = try await self.service.refreshIfNeeded(repo: repo, force: force)
                self.snapshots[repo.id] = snapshot
            } catch {
                AppLog.general.warning("RepoHealth prefetch failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func refresh(repo: Repo, force: Bool = true) async -> RepoHealthSnapshot? {
        guard !loadingRepoIDs.contains(repo.id) else { return snapshots[repo.id] }
        loadingRepoIDs.insert(repo.id)
        defer { loadingRepoIDs.remove(repo.id) }

        do {
            let snapshot = try await service.refreshIfNeeded(repo: repo, force: force)
            snapshots[repo.id] = snapshot
            return snapshot
        } catch {
            AppLog.general.warning("RepoHealth manual refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return snapshots[repo.id]
        }
    }

    func refreshFromNetwork(repo: Repo) async -> RepoHealthSnapshot? {
        guard !loadingRepoIDs.contains(repo.id) else { return snapshots[repo.id] }
        loadingRepoIDs.insert(repo.id)
        defer { loadingRepoIDs.remove(repo.id) }

        do {
            let snapshot = try await service.refreshWithLatestSignals(repo: repo)
            snapshots[repo.id] = snapshot
            return snapshot
        } catch {
            AppLog.general.warning("RepoHealth network refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return snapshots[repo.id]
        }
    }
}
