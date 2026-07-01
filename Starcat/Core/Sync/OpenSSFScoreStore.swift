//
//  OpenSSFScoreStore.swift
//  Starcat
//
//  OpenSSF Scorecard UI 状态缓存。
//
//  设计约束：
//  - View 同步读取 `badge(for:)`，永远不在 body 中 await。
//  - 无记录时 `prefetchIfNeeded` 只启动后台 Task，立刻返回，不阻塞主线程和列表滚动。
//  - 具体网络与落库由 OpenSSFScoreService actor 承担；Store 只把结果投影成 UI 可观察字典。
//

import Foundation
import Observation

@MainActor
@Observable
final class OpenSSFScoreStore {
    private let service: OpenSSFScoreService
    private(set) var records: [Int64: OpenSSFScoreRecord] = [:]
    private var loadingRepoIDs: Set<Int64> = []

    init(service: OpenSSFScoreService) {
        self.service = service
    }

    func badge(for repoId: Int64) -> OpenSSFScoreBadgeData? {
        records[repoId]?.badgeData
    }

    func record(for repoId: Int64) -> OpenSSFScoreRecord? {
        records[repoId]
    }

    func isLoading(repoId: Int64) -> Bool {
        loadingRepoIDs.contains(repoId)
    }

    func loadCachedScores(for repoIds: [Int64], forceReload: Bool = false) async {
        let targetIDs = forceReload ? repoIds : repoIds.filter { records[$0] == nil }
        guard !targetIDs.isEmpty else { return }
        do {
            let fetched = try await service.cachedRecords(for: targetIDs)
            guard !fetched.isEmpty else { return }
            // 列表行都会同步读取 badge；逐条写 records 会让很多 row 连续重算。
            // 这里先合并再一次性赋值，把缓存加载压成一次可观察状态变更。
            var merged = records
            for (id, record) in fetched {
                merged[id] = record
            }
            records = merged
        } catch {
            AppLog.database.warning("OpenSSF cached score load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 非阻塞预拉：调用方只负责 fire-and-forget，UI 不等待网络。
    func prefetchIfNeeded(repo: Repo, force: Bool = false) {
        guard !loadingRepoIDs.contains(repo.id) else { return }
        if let record = records[repo.id],
           !OpenSSFScoreRefreshPolicy.shouldRefresh(record, force: force) {
            return
        }

        loadingRepoIDs.insert(repo.id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.loadingRepoIDs.remove(repo.id) }
            do {
                let record = try await self.service.refreshIfNeeded(repo: repo, force: force)
                self.records[repo.id] = record
            } catch {
                AppLog.network.warning("OpenSSF prefetch failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func refresh(repo: Repo, force: Bool = true) async -> OpenSSFScoreRecord? {
        guard !loadingRepoIDs.contains(repo.id) else { return records[repo.id] }
        loadingRepoIDs.insert(repo.id)
        defer { loadingRepoIDs.remove(repo.id) }

        do {
            let record = try await service.refreshIfNeeded(repo: repo, force: force)
            records[repo.id] = record
            return record
        } catch {
            AppLog.network.warning("OpenSSF manual refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return records[repo.id]
        }
    }
}
