//
//  InitialRepoWarmupCoordinator.swift
//  Starcat
//
//  新用户首次数据预热协调器。
//
//  模块级说明：
//  - 等 starred 全量同步完成后，再启动 README 预拉与 Repo Health 首次计算；
//  - 作业状态持久化到 `initial_warmup_jobs`，应用关闭、崩溃、限流后可恢复；
//  - 不保存 repo 队列，每批从 SQLite 重新查询候选，确保清理缓存或同步新增后状态真实；
//  - 周期性 poller 仍保留为兜底，本 coordinator 只负责首次 warmup。
//

import Foundation
import Observation

@MainActor
@Observable
final class InitialRepoWarmupCoordinator {
    nonisolated static let defaultInitialDelay: TimeInterval = 5 * 60
    nonisolated static let defaultReadmeBatchDelay: TimeInterval = 5
    nonisolated static let defaultFallbackRetryDelay: TimeInterval = 15 * 60
    nonisolated static let defaultHealthBatchLimit = 100
    nonisolated static let defaultHealthDelayBetweenRepos: TimeInterval = 1

    private let jobRepository: InitialWarmupJobRepository
    private let readmePrefetchRepository: ReadmePrefetchRepository
    private let readmePrefetchService: ReadmePrefetchService
    private let repoHealthService: RepoHealthService

    private var activeTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?

    private(set) var job: InitialWarmupJobRecord?
    private(set) var isRunning = false

    init(
        jobRepository: InitialWarmupJobRepository,
        readmePrefetchRepository: ReadmePrefetchRepository,
        readmePrefetchService: ReadmePrefetchService,
        repoHealthService: RepoHealthService
    ) {
        self.jobRepository = jobRepository
        self.readmePrefetchRepository = readmePrefetchRepository
        self.readmePrefetchService = readmePrefetchService
        self.repoHealthService = repoHealthService
    }

    var isActive: Bool {
        guard let job else { return isRunning }
        return isRunning || job.phase == .waiting || job.phase == .readme || job.phase == .health || job.phase == .paused
    }

    var isCompleted: Bool {
        job?.phase == .completed
    }

    /// stars 全量同步完成后的入口。调用方负责保证已登录与测试 host 门控。
    func startAfterStarsSyncIfNeeded(userID: Int64, isEnabled: Bool) async {
        guard isEnabled else {
            await disable(userID: userID)
            return
        }

        do {
            var record = try await loadOrCreateJob(userID: userID)
            guard record.phase != .completed else {
                job = record
                return
            }

            if record.phase == .disabled {
                record.phase = .waiting
                record.scheduledAt = nil
            }

            if record.phase == .waiting, record.scheduledAt == nil {
                record.scheduledAt = Self.string(from: Date().addingTimeInterval(Self.defaultInitialDelay))
                record.updatedAt = Self.string(from: Date())
                try await save(record)
            } else {
                job = record
            }

            scheduleOrRun(userID: userID)
        } catch {
            AppLog.general.warning("Initial warmup start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 设置页“立即补齐 README”入口：只跑 README，不触发 Repo Health。
    func runReadmeNow(userID: Int64) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        while !Task.isCancelled {
            let processed = await readmePrefetchService.runBatch(respectRetryCooldown: true)
            await refreshReadmeCoverageIfJobExists(userID: userID)

            if case .coolingDown = readmePrefetchService.status { return }
            if case .waitingForRetry = readmePrefetchService.status { return }
            guard processed >= ReadmePrefetchService.defaultBatchLimit else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.defaultReadmeBatchDelay * 1_000_000_000))
        }
    }

    func disable(userID: Int64) async {
        cancel()
        do {
            var record = try await loadOrCreateJob(userID: userID)
            guard record.phase != .completed else {
                job = record
                return
            }
            record.phase = .disabled
            record.updatedAt = Self.string(from: Date())
            try await save(record)
        } catch {
            AppLog.general.warning("Initial warmup disable failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancel() {
        scheduledTask?.cancel()
        scheduledTask = nil
        activeTask?.cancel()
        activeTask = nil
        isRunning = false
    }

    private func scheduleOrRun(userID: Int64) {
        guard !isRunning else { return }
        scheduledTask?.cancel()
        scheduledTask = nil

        let scheduledDate = job?.scheduledAt.flatMap(Self.date(from:))
        let retryDate = job?.nextRetryAt.flatMap(Self.date(from:))
        let targetDate = [scheduledDate, retryDate]
            .compactMap { $0 }
            .filter { $0 > Date() }
            .min()

        if let targetDate {
            scheduledTask = Task { @MainActor [weak self] in
                let delay = max(0, targetDate.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.runFullWarmup(userID: userID)
            }
        } else {
            activeTask = Task { @MainActor [weak self] in
                await self?.runFullWarmup(userID: userID)
            }
        }
    }

    private func runFullWarmup(userID: Int64) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        await runReadmePhase(userID: userID)
        guard !Task.isCancelled, job?.phase != .paused, job?.phase != .disabled else { return }
        await runHealthPhase(userID: userID)
    }

    private func runReadmePhase(userID: Int64) async {
        do {
            var record = try await loadOrCreateJob(userID: userID)
            record.phase = .readme
            record.startedAt = record.startedAt ?? Self.string(from: Date())
            record.scheduledAt = nil
            record.nextRetryAt = nil
            record.lastErrorKind = nil
            record.updatedAt = Self.string(from: Date())
            record = try await applyingReadmeCoverage(to: record)
            try await save(record)
        } catch {
            AppLog.general.warning("Initial warmup README phase init failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        while !Task.isCancelled {
            guard let current = job, current.phase == .readme else { return }
            if current.readmeTotal == 0 || current.readmeCovered >= current.readmeTotal {
                await finishReadmePhase(userID: userID)
                return
            }

            let processed = await readmePrefetchService.runBatch(respectRetryCooldown: true)
            await refreshReadmeCoverage(userID: userID)

            if case .coolingDown(let until) = readmePrefetchService.status {
                await pause(userID: userID, until: until, reason: "rateLimited")
                return
            }
            if case .waitingForRetry = readmePrefetchService.status {
                await pauseToNextReadmeRetry(userID: userID, reason: "waitingForRetry")
                return
            }
            if processed == 0 {
                if let current = job, current.readmeCovered >= current.readmeTotal {
                    await finishReadmePhase(userID: userID)
                } else {
                    await pauseToNextReadmeRetry(userID: userID, reason: "noRunnableReadmeCandidates")
                }
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(Self.defaultReadmeBatchDelay * 1_000_000_000))
        }
    }

    private func runHealthPhase(userID: Int64) async {
        do {
            var record = try await loadOrCreateJob(userID: userID)
            record.phase = .health
            record.nextRetryAt = nil
            record.lastErrorKind = nil
            record.updatedAt = Self.string(from: Date())
            record = try await applyingHealthCoverage(to: record)
            try await save(record)
        } catch {
            AppLog.general.warning("Initial warmup Health phase init failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        while !Task.isCancelled {
            guard let current = job, current.phase == .health else { return }
            if current.healthTotal == 0 || current.healthCovered >= current.healthTotal {
                await complete(userID: userID)
                return
            }

            let refreshed = await repoHealthService.refreshMissingSnapshotStarredRepos(
                limit: Self.defaultHealthBatchLimit,
                delayBetweenRepos: Self.defaultHealthDelayBetweenRepos
            )
            await refreshHealthCoverage(userID: userID)

            if refreshed == 0 {
                if let current = job, current.healthCovered >= current.healthTotal {
                    await complete(userID: userID)
                } else {
                    await pause(userID: userID, until: Date().addingTimeInterval(Self.defaultFallbackRetryDelay), reason: "healthRetry")
                }
                return
            }
        }
    }

    private func finishReadmePhase(userID: Int64) async {
        do {
            var record = try await loadOrCreateJob(userID: userID)
            record = try await applyingReadmeCoverage(to: record)
            record.phase = .health
            record.updatedAt = Self.string(from: Date())
            try await save(record)
        } catch {
            AppLog.general.warning("Initial warmup README phase finish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func complete(userID: Int64) async {
        do {
            var record = try await loadOrCreateJob(userID: userID)
            record = try await applyingReadmeCoverage(to: record)
            record = try await applyingHealthCoverage(to: record)
            record.phase = .completed
            record.completedAt = Self.string(from: Date())
            record.nextRetryAt = nil
            record.lastErrorKind = nil
            record.updatedAt = record.completedAt ?? Self.string(from: Date())
            try await save(record)
            AppLog.general.info("Initial warmup completed for userID=\(userID, privacy: .public)")
        } catch {
            AppLog.general.warning("Initial warmup complete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func pauseToNextReadmeRetry(userID: Int64, reason: String) async {
        let now = Date()
        let fallback = now.addingTimeInterval(Self.defaultFallbackRetryDelay)
        let nextRetry: Date
        do {
            let retry = try await readmePrefetchRepository.nextRetryForPendingCandidates(
                now: now,
                htmlStaleBefore: now.addingTimeInterval(-ReadmeAPI.softTtl)
            )
            nextRetry = retry ?? fallback
        } catch {
            nextRetry = fallback
        }
        await pause(userID: userID, until: nextRetry, reason: reason)
    }

    private func pause(userID: Int64, until: Date, reason: String) async {
        do {
            var record = try await loadOrCreateJob(userID: userID)
            record.phase = .paused
            record.nextRetryAt = Self.string(from: until)
            record.lastErrorKind = reason
            record.updatedAt = Self.string(from: Date())
            try await save(record)
            scheduleWake(userID: userID, at: until)
        } catch {
            AppLog.general.warning("Initial warmup pause failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshReadmeCoverage(userID: Int64) async {
        do {
            var record = try await loadOrCreateJob(userID: userID)
            record = try await applyingReadmeCoverage(to: record)
            record.updatedAt = Self.string(from: Date())
            try await save(record)
        } catch {
            AppLog.general.warning("Initial warmup README coverage refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshReadmeCoverageIfJobExists(userID: Int64) async {
        do {
            guard var record = try await jobRepository.job(userId: userID) else { return }
            record = try await applyingReadmeCoverage(to: record)
            record.updatedAt = Self.string(from: Date())
            try await save(record)
        } catch {
            AppLog.general.warning("Initial warmup manual README coverage refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshHealthCoverage(userID: Int64) async {
        do {
            var record = try await loadOrCreateJob(userID: userID)
            record = try await applyingHealthCoverage(to: record)
            record.updatedAt = Self.string(from: Date())
            try await save(record)
        } catch {
            AppLog.general.warning("Initial warmup Health coverage refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadOrCreateJob(userID: Int64) async throws -> InitialWarmupJobRecord {
        if let existing = try await jobRepository.job(userId: userID) {
            job = existing
            return existing
        }

        let now = Self.string(from: Date())
        let record = InitialWarmupJobRecord(
            userId: userID,
            phase: .waiting,
            scheduledAt: nil,
            startedAt: nil,
            completedAt: nil,
            nextRetryAt: nil,
            lastErrorKind: nil,
            readmeCovered: 0,
            readmeTotal: 0,
            healthCovered: 0,
            healthTotal: 0,
            updatedAt: now
        )
        try await jobRepository.upsert(record)
        job = record
        return record
    }

    private func applyingReadmeCoverage(to record: InitialWarmupJobRecord) async throws -> InitialWarmupJobRecord {
        var updated = record
        let summary = try await readmePrefetchRepository.coverageSummary()
        updated.readmeCovered = summary.prefetchedTotal
        updated.readmeTotal = summary.starredTotal
        return updated
    }

    private func applyingHealthCoverage(to record: InitialWarmupJobRecord) async throws -> InitialWarmupJobRecord {
        var updated = record
        let summary = try await repoHealthService.coverageSummary()
        updated.healthCovered = summary.snapshotTotal
        updated.healthTotal = summary.starredTotal
        return updated
    }

    private func save(_ record: InitialWarmupJobRecord) async throws {
        try await jobRepository.upsert(record)
        job = record
    }

    private func scheduleWake(userID: Int64, at date: Date) {
        scheduledTask?.cancel()
        scheduledTask = Task { @MainActor [weak self] in
            let delay = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.runFullWarmup(userID: userID)
        }
    }

    private static func string(from date: Date) -> String {
        ISO8601DateFormatter.shared.string(from: date)
    }

    private static func date(from string: String) -> Date? {
        ISO8601DateFormatter.shared.date(from: string)
    }
}
