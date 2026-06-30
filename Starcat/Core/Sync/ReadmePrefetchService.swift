//
//  ReadmePrefetchService.swift
//  Starcat
//
//  README 后台预拉协调服务。
//
//  模块级说明：
//  - 低优先级、串行、限量地补齐已 star 仓库的 README HTML 与 raw Markdown；
//  - 复用 `ReadmeAPI` 的 ETag / SWR / in-flight 去重能力，避免与详情页或向量索引重复拉取；
//  - 单仓库失败只记录冷却，不影响 Starcat 前台操作，也不阻断后续仓库。
//

import Foundation

/// README 后台预拉服务的可观察状态。
enum ReadmePrefetchServiceStatus: Equatable, Sendable {
    case idle
    case running
    case coolingDown(until: Date)
    case waitingForRetry
    case completed(processed: Int, total: Int)
    case allPrefetched(total: Int)
    case noStarredRepos
    case disabled
}

/// README 后台预拉协调服务。
///
/// 使用 `@MainActor` 的原因：状态面板与设置页直接订阅进度字段；网络和 SQLite 调用本身仍是
/// async，不会阻塞主线程。每轮只串行处理小批量仓库，并在仓库之间 sleep，避免资源尖刺。
@MainActor
@Observable
final class ReadmePrefetchService {

    nonisolated static let defaultBatchLimit = 50
    nonisolated static let defaultDelayBetweenRepos: TimeInterval = 3
    nonisolated static let notFoundRetryDelay: TimeInterval = 7 * 24 * 60 * 60

    private(set) var status: ReadmePrefetchServiceStatus = .idle
    private(set) var processed: Int = 0
    private(set) var total: Int = 0
    private(set) var htmlUpdated: Int = 0
    private(set) var htmlSkipped: Int = 0
    private(set) var markdownUpdated: Int = 0
    private(set) var notFound: Int = 0
    private(set) var failures: Int = 0
    private(set) var lastRunAt: Date?
    /// 仅用于日志 / 诊断排查的错误类别，不允许直接展示到用户界面。
    /// 底层错误可能包含 SQL、路径、HTTP 细节；UI 只能展示固定的用户态状态文案。
    private(set) var lastFailureKind: String?

    private let repository: ReadmePrefetchRepository
    private let readmeRepository: ReadmeRepository
    private let readmeAPI: ReadmeAPI

    init(
        repository: ReadmePrefetchRepository,
        readmeRepository: ReadmeRepository,
        readmeAPI: ReadmeAPI
    ) {
        self.repository = repository
        self.readmeRepository = readmeRepository
        self.readmeAPI = readmeAPI
    }

    /// 跑一轮温和预拉。返回本轮实际遍历的 repo 数。
    @discardableResult
    func runBatch(
        limit: Int = ReadmePrefetchService.defaultBatchLimit,
        delayBetweenRepos: TimeInterval = ReadmePrefetchService.defaultDelayBetweenRepos
    ) async -> Int {
        guard !isRunning else { return 0 }

        let now = Date()
        let staleBefore = now.addingTimeInterval(-ReadmeAPI.softTtl)
        let candidates: [Repo]
        do {
            candidates = try await repository.fetchCandidates(now: now, htmlStaleBefore: staleBefore, limit: limit)
        } catch {
            failures += 1
            status = .waitingForRetry
            lastFailureKind = Self.errorKind(error)
            AppLog.network.warning("README prefetch candidate query failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }

        resetRunCounters(total: candidates.count)
        guard !candidates.isEmpty else {
            await updateEmptyCandidateStatus()
            lastRunAt = Date()
            return 0
        }

        status = .running
        for (index, repo) in candidates.enumerated() {
            guard !Task.isCancelled else { break }
            let shouldContinue = await prefetch(repo)
            processed += 1
            if !shouldContinue { break }

            if index < candidates.count - 1, delayBetweenRepos > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delayBetweenRepos * 1_000_000_000))
            }
        }

        if case .running = status {
            status = .completed(processed: processed, total: total)
        }
        lastRunAt = Date()
        return processed
    }

    func markDisabled() {
        status = .disabled
    }

    func markIdleIfDisabled() {
        if case .disabled = status {
            status = .idle
        }
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private func resetRunCounters(total: Int) {
        self.processed = 0
        self.total = total
        htmlUpdated = 0
        htmlSkipped = 0
        markdownUpdated = 0
        notFound = 0
        failures = 0
        lastFailureKind = nil
    }

    /// 空候选项需要二次确认覆盖率。
    ///
    /// 候选为空并不等于“本轮检查 0/0”：也可能是所有 Star 仓库都已经具备 HTML + Markdown
    /// 缓存。这里补一次轻量聚合查询，让手动“立即拉取”在全量完成时给出明确结果。
    private func updateEmptyCandidateStatus() async {
        do {
            let summary = try await repository.coverageSummary()
            processed = summary.prefetchedTotal
            total = summary.starredTotal

            if summary.starredTotal == 0 {
                status = .noStarredRepos
            } else if summary.isAllPrefetched {
                status = .allPrefetched(total: summary.starredTotal)
            } else {
                status = .completed(processed: summary.prefetchedTotal, total: summary.starredTotal)
            }
        } catch {
            failures += 1
            status = .waitingForRetry
            lastFailureKind = Self.errorKind(error)
            AppLog.network.warning("README prefetch coverage query failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 处理单个 repo。
    ///
    /// 返回 false 表示遇到 rate limit / unauthorized 这类全局错误，本轮应提前停止。
    private func prefetch(_ repo: Repo) async -> Bool {
        let now = Date()
        let htmlResult = await refreshHTMLIfNeeded(repo: repo, now: now)

        switch htmlResult {
        case .succeeded, .skipped:
            return await refreshMarkdownIfNeeded(repo: repo, htmlStatus: htmlResult.persistedStatus, now: now)
        case .notFound:
            notFound += 1
            await persist(
                repoId: repo.id,
                htmlStatus: .notFound,
                markdownStatus: .skipped,
                now: now,
                nextRetryAt: now.addingTimeInterval(Self.notFoundRetryDelay),
                failureCount: 0,
                errorKind: "notFound"
            )
            return true
        case .failed(let error):
            return await persistFailure(repoId: repo.id, htmlStatus: .failed, markdownStatus: .skipped, error: error, now: now)
        }
    }

    private func refreshHTMLIfNeeded(repo: Repo, now: Date) async -> StepResult {
        do {
            if let cached = try await readmeRepository.find(repoId: repo.id),
               ReadmeAPI.isWithinSoftTtl(cachedAt: cached.cachedAt, now: now, softTtl: ReadmeAPI.softTtl) {
                htmlSkipped += 1
                return .skipped
            }
        } catch {
            return .failed(error)
        }

        switch await readmeAPI.refreshReadme(for: repo) {
        case .updated:
            htmlUpdated += 1
            return .succeeded
        case .notModified:
            htmlSkipped += 1
            return .succeeded
        case .notFound:
            return .notFound
        case .failed(let error):
            return .failed(error)
        }
    }

    private func refreshMarkdownIfNeeded(repo: Repo, htmlStatus: ReadmePrefetchContentStatus, now: Date) async -> Bool {
        switch await readmeAPI.refreshMarkdownIfNeeded(for: repo) {
        case .updated:
            markdownUpdated += 1
            await persist(repoId: repo.id, htmlStatus: htmlStatus, markdownStatus: .succeeded, now: now)
            return true
        case .notModified:
            await persist(repoId: repo.id, htmlStatus: htmlStatus, markdownStatus: .skipped, now: now)
            return true
        case .notFound:
            notFound += 1
            await persist(
                repoId: repo.id,
                htmlStatus: htmlStatus,
                markdownStatus: .notFound,
                now: now,
                nextRetryAt: now.addingTimeInterval(Self.notFoundRetryDelay),
                failureCount: 0,
                errorKind: "notFound"
            )
            return true
        case .failed(let error):
            return await persistFailure(repoId: repo.id, htmlStatus: htmlStatus, markdownStatus: .failed, error: error, now: now)
        }
    }

    @discardableResult
    private func persistFailure(
        repoId: Int64,
        htmlStatus: ReadmePrefetchContentStatus,
        markdownStatus: ReadmePrefetchContentStatus,
        error: Error,
        now: Date
    ) async -> Bool {
        failures += 1
        lastFailureKind = Self.errorKind(error)

        if case .rateLimited(let retryAfter) = error as? NetworkError {
            let retryAt = now.addingTimeInterval(max(60, retryAfter))
            status = .coolingDown(until: retryAt)
            await persist(
                repoId: repoId,
                htmlStatus: htmlStatus,
                markdownStatus: markdownStatus,
                now: now,
                nextRetryAt: retryAt,
                failureCount: 1,
                errorKind: "rateLimited"
            )
            return false
        }

        if case .unauthorized = error as? NetworkError {
            await persist(
                repoId: repoId,
                htmlStatus: htmlStatus,
                markdownStatus: markdownStatus,
                now: now,
                nextRetryAt: now.addingTimeInterval(60 * 60),
                failureCount: 1,
                errorKind: "unauthorized"
            )
            return false
        }

        let previous = (try? await repository.state(repoId: repoId)) ?? nil
        let failureCount = min((previous?.failureCount ?? 0) + 1, 4)
        await persist(
            repoId: repoId,
            htmlStatus: htmlStatus,
            markdownStatus: markdownStatus,
            now: now,
            nextRetryAt: now.addingTimeInterval(Self.retryDelay(failureCount: failureCount)),
            failureCount: failureCount,
            errorKind: Self.errorKind(error)
        )
        AppLog.network.warning("README prefetch failed repoId=\(repoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return true
    }

    private func persist(
        repoId: Int64,
        htmlStatus: ReadmePrefetchContentStatus,
        markdownStatus: ReadmePrefetchContentStatus,
        now: Date,
        nextRetryAt: Date? = nil,
        failureCount: Int = 0,
        errorKind: String? = nil
    ) async {
        let record = ReadmePrefetchStateRecord(
            repoId: repoId,
            htmlStatus: htmlStatus,
            markdownStatus: markdownStatus,
            lastAttemptAt: ISO8601DateFormatter.shared.string(from: now),
            nextRetryAt: nextRetryAt.map { ISO8601DateFormatter.shared.string(from: $0) },
            failureCount: failureCount,
            lastErrorKind: errorKind
        )
        do {
            try await repository.upsert(record)
        } catch {
            failures += 1
            lastFailureKind = Self.errorKind(error)
            AppLog.network.warning("README prefetch state persist failed repoId=\(repoId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func retryDelay(failureCount: Int) -> TimeInterval {
        switch failureCount {
        case 0, 1: return 15 * 60
        case 2: return 60 * 60
        case 3: return 6 * 60 * 60
        default: return 24 * 60 * 60
        }
    }

    private static func errorKind(_ error: Error) -> String {
        guard let network = error as? NetworkError else {
            return String(describing: type(of: error))
        }
        switch network {
        case .transport: return "transport"
        case .serverError: return "server"
        case .clientError: return "client"
        case .cancelled: return "cancelled"
        case .rateLimited: return "rateLimited"
        case .unauthorized: return "unauthorized"
        case .notFound: return "notFound"
        case .decodingError: return "decoding"
        case .invalidURL: return "invalidURL"
        case .invalidResponse: return "invalidResponse"
        case .notModified: return "notModified"
        }
    }

    private enum StepResult {
        case succeeded
        case skipped
        case notFound
        case failed(Error)

        var persistedStatus: ReadmePrefetchContentStatus {
            switch self {
            case .succeeded: return .succeeded
            case .skipped: return .skipped
            case .notFound: return .notFound
            case .failed: return .failed
            }
        }
    }
}
