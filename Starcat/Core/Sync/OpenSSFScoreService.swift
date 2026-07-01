//
//  OpenSSFScoreService.swift
//  Starcat
//
//  OpenSSF Scorecard 刷新协调服务。
//
//  设计约束：
//  - 详情页无缓存时可以触发异步刷新，但调用方不应在主线程同步等待网络。
//  - 后台批处理只处理 starred repos，并用限流器约束到最多 5 req/s。
//  - 同一 repo 的并发刷新复用一个 Task，避免详情页、手动刷新、后台任务同时打同一端点。
//

import Foundation

actor OpenSSFScoreService {
    private let api: OpenSSFScoreAPI
    private let repository: any OpenSSFScoreRepositoryProtocol
    private let healthRefreshHandler: (@Sendable (Repo) async -> Void)?
    private let rateLimiter = OpenSSFScoreRateLimiter(maxRequestsPerSecond: 5)
    private var inFlight: [Int64: Task<OpenSSFScoreRecord, Error>] = [:]

    init(
        api: OpenSSFScoreAPI,
        repository: any OpenSSFScoreRepositoryProtocol,
        healthRefreshHandler: (@Sendable (Repo) async -> Void)? = nil
    ) {
        self.api = api
        self.repository = repository
        self.healthRefreshHandler = healthRefreshHandler
    }

    func cachedRecord(for repoId: Int64) async throws -> OpenSSFScoreRecord? {
        try await repository.record(for: repoId)
    }

    func cachedRecords(for repoIds: [Int64]) async throws -> [Int64: OpenSSFScoreRecord] {
        try await repository.records(for: repoIds)
    }

    func refreshIfNeeded(repo: Repo, force: Bool = false) async throws -> OpenSSFScoreRecord {
        if let existing = try await repository.record(for: repo.id),
           !OpenSSFScoreRefreshPolicy.shouldRefresh(existing, force: force) {
            return existing
        }
        return try await refresh(repo: repo)
    }

    func refresh(repo: Repo) async throws -> OpenSSFScoreRecord {
        if let task = inFlight[repo.id] {
            return try await task.value
        }

        let task = Task<OpenSSFScoreRecord, Error> {
            try await rateLimiter.waitForTurn()
            let now = Date()
            let record: OpenSSFScoreRecord
            do {
                let response = try await api.fetch(owner: repo.owner, repo: repo.name)
                record = .success(
                    repoId: repo.id,
                    payload: response.payload,
                    rawData: response.rawData,
                    fetchedAt: now
                )
            } catch OpenSSFScoreAPIError.notIndexed {
                record = .failure(
                    repoId: repo.id,
                    status: .notIndexed,
                    message: nil,
                    fetchedAt: now
                )
            } catch OpenSSFScoreAPIError.decoding(let message) {
                record = .failure(
                    repoId: repo.id,
                    status: .parseError,
                    message: message,
                    fetchedAt: now
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                record = .failure(
                    repoId: repo.id,
                    status: .networkError,
                    message: error.localizedDescription,
                    fetchedAt: now
                )
            }
            try await repository.upsert(record)
            NotificationCenter.default.post(
                name: .openSSFScoreDidChange,
                object: nil,
                userInfo: ["repoId": record.repoId]
            )
            if record.fetchStatus == .success, let healthRefreshHandler {
                // OpenSSF 是 Health 安全维度的输入。成功写入后异步重算 Health，
                // 让卡片 badge / Health 排序继续走已有 repoHealthSnapshotDidChange 链路。
                Task {
                    await healthRefreshHandler(repo)
                }
            }
            return record
        }

        inFlight[repo.id] = task
        defer { inFlight[repo.id] = nil }
        return try await task.value
    }

    @discardableResult
    func refreshStaleStarredRepos(
        limit: Int = 100,
        progress: (@Sendable (_ processed: Int, _ total: Int) async -> Void)? = nil
    ) async -> Int {
        let candidates: [Repo]
        do {
            candidates = try await repository.staleStarredRepos(now: Date(), limit: limit)
        } catch {
            AppLog.network.warning("OpenSSF stale repo query failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        await progress?(0, candidates.count)
        var refreshed = 0
        var processed = 0
        await withTaskGroup(of: Bool.self) { group in
            var iterator = candidates.makeIterator()

            func enqueueNext() {
                guard let repo = iterator.next() else { return }
                group.addTask { [weak self] in
                    guard let self else { return false }
                    do {
                        _ = try await self.refreshIfNeeded(repo: repo)
                        return true
                    } catch {
                        AppLog.network.warning("OpenSSF background refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return false
                    }
                }
            }

            for _ in 0..<min(3, candidates.count) {
                enqueueNext()
            }
            while let ok = await group.next() {
                processed += 1
                if ok { refreshed += 1 }
                await progress?(processed, candidates.count)
                enqueueNext()
            }
        }
        return refreshed
    }

    func coverageSummary() async throws -> OpenSSFScoreCoverageSummary {
        try await repository.coverageSummary()
    }
}

actor OpenSSFScoreRateLimiter {
    private let interval: TimeInterval
    private var nextAvailableAt: Date = .distantPast

    init(maxRequestsPerSecond: Int) {
        self.interval = 1.0 / Double(max(maxRequestsPerSecond, 1))
    }

    func waitForTurn() async throws {
        let now = Date()
        if nextAvailableAt > now {
            let delay = nextAvailableAt.timeIntervalSince(now)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        nextAvailableAt = max(Date(), nextAvailableAt).addingTimeInterval(interval)
    }
}
