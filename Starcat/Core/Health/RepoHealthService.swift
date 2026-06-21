//
//  RepoHealthService.swift
//  Starcat
//
//  Repo Health 刷新协调服务。
//
//  自动刷新只聚合已有本地缓存：Repo 元数据、Release 缓存、OpenSSF 缓存。
//  这能让后台任务批量计算且不消耗额外 GitHub REST 配额。
//
//  用户主动点击 Health 面板刷新时例外：拉取最新 Release + `/repos/{owner}/{repo}`
//  刷新 pushed_at 等维护/质量信号，然后重算 Health。OpenSSF 仍读本地缓存。
//

import Foundation

actor RepoHealthService {
    private let repository: any RepoHealthRepositoryProtocol
    private let releaseRepository: any ReleaseRepositoryProtocol
    private let openSSFRepository: any OpenSSFScoreRepositoryProtocol
    private let apiClient: any GitHubAPIClientProtocol
    private var inFlight: [Int64: Task<RepoHealthSnapshot, Error>] = [:]

    init(
        repository: any RepoHealthRepositoryProtocol,
        releaseRepository: any ReleaseRepositoryProtocol,
        openSSFRepository: any OpenSSFScoreRepositoryProtocol,
        apiClient: any GitHubAPIClientProtocol
    ) {
        self.repository = repository
        self.releaseRepository = releaseRepository
        self.openSSFRepository = openSSFRepository
        self.apiClient = apiClient
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
            try await self.makeAndPersistSnapshot(repo: repo)
        }

        inFlight[repo.id] = task
        defer { inFlight[repo.id] = nil }
        return try await task.value
    }

    /// 用户主动刷新入口：走网络更新 Release + repo 元数据缓存，然后重算 Health。
    ///
    /// Release 这里按“健康度信号刷新”处理，新插入的 release 直接标已读，避免用户只是
    /// 看健康度却在 Release 时间线里看到未读 badge。真正的未读通知仍由 ReleaseMonitor
    /// 维护，它有独立的订阅游标和轮询语义。
    ///
    /// repo 元数据(`/repos/{owner}/{repo}`)同步刷新 pushed_at / archived / open issues 等
    /// 字段——仅用于本次算分,不写回 repos 表(dong4j 2026-06-21:修复刷新后 push 仍未知)。
    ///
    /// OpenSSF 刻意只读本地库：大多数 repo 没有 Scorecard 数据，前台刷新直接打
    /// OpenSSF 会放大 Health sheet 卡顿；后台 `OpenSSFScorePoller` 已负责慢速补齐。
    func refreshWithLatestSignals(repo: Repo) async throws -> RepoHealthSnapshot {
        async let latestRelease = refreshLatestReleaseSignal(repo: repo)
        async let openSSF = openSSFRepository.record(for: repo.id)
        async let freshRepo = refreshRepoMetadataSignal(repo: repo)

        let snapshot = RepoHealthCalculator.makeSnapshot(
            repo: await freshRepo,
            latestRelease: await latestRelease,
            openSSF: try? await openSSF
        )
        try await repository.upsert(snapshot)
        return snapshot
    }

    func refreshStaleStarredRepos(limit: Int, delayBetweenRepos: TimeInterval = 0) async -> Int {
        do {
            let repos = try await repository.staleStarredRepos(now: Date(), limit: limit)
            var refreshed = 0
            for (index, repo) in repos.enumerated() {
                guard !Task.isCancelled else { break }
                do {
                    _ = try await refreshIfNeeded(repo: repo)
                    refreshed += 1
                } catch {
                    AppLog.general.warning("RepoHealth background refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }

                if index < repos.count - 1, delayBetweenRepos > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayBetweenRepos * 1_000_000_000))
                }
            }
            return refreshed
        } catch {
            AppLog.general.warning("RepoHealth stale repo query failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    private func makeAndPersistSnapshot(repo: Repo) async throws -> RepoHealthSnapshot {
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

    private func refreshLatestReleaseSignal(repo: Repo) async -> ReleaseRecord? {
        do {
            let response = try await apiClient.releases(owner: repo.owner, repo: repo.name, perPage: 100)
            let nowISO = ISO8601DateFormatter.shared.string(from: Date())
            let records = response.value.map { dto in
                ReleaseRecord(
                    id: dto.id,
                    repoId: repo.id,
                    tagName: dto.tagName,
                    name: dto.name,
                    bodyMarkdown: dto.body,
                    htmlUrl: dto.htmlUrl,
                    isPrerelease: dto.prerelease,
                    isDraft: dto.draft,
                    publishedAt: dto.publishedAt,
                    createdAtRemote: dto.createdAt,
                    assetsJson: ReleaseAssetCodec.encode(dto.assets?.map(Self.dtoToAsset)),
                    isRead: true,
                    fetchedAt: nowISO
                )
            }
            try await releaseRepository.upsertMany(records, isReadDefault: true)
        } catch NetworkError.notFound {
            // GitHub 用 404 表示没有 release。Health 只把它视为缺失信号，不升级为失败。
        } catch {
            AppLog.general.warning("RepoHealth release signal refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        return try? await releaseRepository.latest(forRepo: repo.id)
    }

    /// 拉取 `/repos/{owner}/{repo}` 刷新 Health 算分用的 repo 信号字段。
    private func refreshRepoMetadataSignal(repo: Repo) async -> Repo {
        do {
            let dto = try await apiClient.repo(owner: repo.owner, repo: repo.name)
            let cachedAt = ISO8601DateFormatter.shared.string(from: Date())
            return GRDBRepoRepository.repoFromDTO(
                dto,
                starredAt: repo.starredAt,
                cachedAt: cachedAt,
                isStarred: repo.isStarred
            )
        } catch {
            AppLog.general.warning("RepoHealth repo metadata refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return repo
        }
    }

    private static func dtoToAsset(_ dto: GitHubReleaseAssetDTO) -> ReleaseAsset {
        ReleaseAsset(
            id: dto.id,
            name: dto.name,
            contentType: dto.contentType,
            size: dto.size,
            browserDownloadUrl: dto.browserDownloadUrl,
            apiUrl: dto.url,
            downloadCount: dto.downloadCount,
            createdAt: dto.createdAt
        )
    }
}

enum RepoHealthRefreshPolicy {
    static func shouldRefresh(_ snapshot: RepoHealthSnapshot?, now: Date = Date(), force: Bool = false) -> Bool {
        guard !force else { return true }
        guard let snapshot, let staleDate = snapshot.staleDate else { return true }
        return now >= staleDate
    }
}
