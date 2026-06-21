//
//  RepoHealthService.swift
//  Starcat
//
//  Repo Health 刷新协调服务。
//
//  自动刷新只聚合已有本地缓存：Repo 元数据、Release 缓存、OpenSSF 缓存。
//  这能让后台任务批量计算且不消耗额外 GitHub REST 配额。
//
//  用户主动点击 Health 面板刷新时例外：先拉取最新 Release 首页和 OpenSSF Scorecard，
//  写入各自缓存后再计算快照。这样“主动刷新”有真实网络含义，同时不污染 Release
//  订阅游标和未读通知。
//

import Foundation

actor RepoHealthService {
    private let repository: any RepoHealthRepositoryProtocol
    private let releaseRepository: any ReleaseRepositoryProtocol
    private let openSSFRepository: any OpenSSFScoreRepositoryProtocol
    private let apiClient: any GitHubAPIClientProtocol
    private let openSSFService: OpenSSFScoreService
    private var inFlight: [Int64: Task<RepoHealthSnapshot, Error>] = [:]

    init(
        repository: any RepoHealthRepositoryProtocol,
        releaseRepository: any ReleaseRepositoryProtocol,
        openSSFRepository: any OpenSSFScoreRepositoryProtocol,
        apiClient: any GitHubAPIClientProtocol,
        openSSFService: OpenSSFScoreService
    ) {
        self.repository = repository
        self.releaseRepository = releaseRepository
        self.openSSFRepository = openSSFRepository
        self.apiClient = apiClient
        self.openSSFService = openSSFService
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

    /// 用户主动刷新入口：直接走网络更新 Release / OpenSSF 缓存，然后重算 Health。
    ///
    /// Release 这里按“健康度信号刷新”处理，新插入的 release 直接标已读，避免用户只是
    /// 看健康度却在 Release 时间线里看到未读 badge。真正的未读通知仍由 ReleaseMonitor
    /// 维护，它有独立的订阅游标和轮询语义。
    func refreshWithLatestSignals(repo: Repo) async throws -> RepoHealthSnapshot {
        async let latestRelease = refreshLatestReleaseSignal(repo: repo)
        async let openSSF = refreshOpenSSFSignal(repo: repo)

        let snapshot = RepoHealthCalculator.makeSnapshot(
            repo: repo,
            latestRelease: await latestRelease,
            openSSF: await openSSF
        )
        try await repository.upsert(snapshot)
        return snapshot
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

    private func refreshOpenSSFSignal(repo: Repo) async -> OpenSSFScoreRecord? {
        do {
            return try await openSSFService.refresh(repo: repo)
        } catch {
            AppLog.general.warning("RepoHealth OpenSSF signal refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return try? await openSSFRepository.record(for: repo.id)
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
