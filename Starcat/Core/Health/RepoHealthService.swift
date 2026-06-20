//
//  RepoHealthService.swift
//  Starcat
//
//  Repo Health 刷新协调服务。
//
//  第一版只聚合已有本地缓存：Repo 元数据、Release 缓存、OpenSSF 缓存。
//  这能让后台任务批量计算且不消耗额外 GitHub REST 配额；未来若新增 issue / PR /
//  commit 细粒度指标，应先落缓存层，再接入这里。
//

import Foundation

actor RepoHealthService {
    private let repository: any RepoHealthRepositoryProtocol
    private let releaseRepository: any ReleaseRepositoryProtocol
    private let openSSFRepository: any OpenSSFScoreRepositoryProtocol
    private var inFlight: [Int64: Task<RepoHealthSnapshot, Error>] = [:]

    init(
        repository: any RepoHealthRepositoryProtocol,
        releaseRepository: any ReleaseRepositoryProtocol,
        openSSFRepository: any OpenSSFScoreRepositoryProtocol
    ) {
        self.repository = repository
        self.releaseRepository = releaseRepository
        self.openSSFRepository = openSSFRepository
    }

    func cachedSnapshot(for repoId: Int64) async throws -> RepoHealthSnapshot? {
        try await repository.snapshot(for: repoId)
    }

    func cachedSnapshots(for repoIds: [Int64]) async throws -> [Int64: RepoHealthSnapshot] {
        try await repository.snapshots(for: repoIds)
    }

    func refreshIfNeeded(repo: Repo, force: Bool = false) async throws -> RepoHealthSnapshot {
        if !force,
           let existing = try await repository.snapshot(for: repo.id),
           !RepoHealthRefreshPolicy.shouldRefresh(existing) {
            return existing
        }
        return try await refresh(repo: repo)
    }

    func refresh(repo: Repo) async throws -> RepoHealthSnapshot {
        if let existing = inFlight[repo.id] {
            return try await existing.value
        }

        let task = Task<RepoHealthSnapshot, Error> {
            let latestRelease = try? await releaseRepository.latest(forRepo: repo.id)
            let openSSF = try? await openSSFRepository.record(for: repo.id)
            let snapshot = RepoHealthCalculator.makeSnapshot(
                repo: repo,
                latestRelease: latestRelease,
                openSSF: openSSF
            )
            try await repository.upsert(snapshot)
            return snapshot
        }

        inFlight[repo.id] = task
        defer { inFlight[repo.id] = nil }
        return try await task.value
    }

    func refreshStaleStarredRepos(limit: Int) async -> Int {
        do {
            let repos = try await repository.staleStarredRepos(now: Date(), limit: limit)
            var refreshed = 0
            for repo in repos {
                do {
                    _ = try await refreshIfNeeded(repo: repo)
                    refreshed += 1
                } catch {
                    AppLog.general.warning("RepoHealth background refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            return refreshed
        } catch {
            AppLog.general.warning("RepoHealth stale repo query failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}

enum RepoHealthRefreshPolicy {
    static func shouldRefresh(_ snapshot: RepoHealthSnapshot?, now: Date = Date(), force: Bool = false) -> Bool {
        guard !force else { return true }
        guard let snapshot, let staleDate = snapshot.staleDate else { return true }
        return now >= staleDate
    }
}

