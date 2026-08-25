//
//  RepositorySpotlightService.swift
//  Starcat
//
//  当前用户仓库数据库与 Core Spotlight 之间的生命周期协调器。
//

import AppIntents
import Foundation
import GRDB

/// 根据用户授权维护全部 starred repositories（含 private 与笔记）的 Spotlight 索引。
///
/// 服务本身留在 MainActor：AppSettings、账号切换和通知入口都属于 App 生命周期状态；
/// 真正的系统索引写入由 `CoreSpotlightRepositoryIndex` actor 串行化。数据库读取始终从
/// `DatabaseManaging.writer` 现场取得，不能缓存 writer，否则多账号切库后会继续读取旧库。
@MainActor
final class RepositorySpotlightService {
    private let database: any DatabaseManaging
    private let settings: AppSettings
    private let index: any RepositorySpotlightIndexing
    private let notificationCenter: NotificationCenter

    private var observationTasks: [Task<Void, Never>] = []
    private var scheduledRebuildTask: Task<Void, Never>?

    init(
        database: any DatabaseManaging,
        settings: AppSettings,
        index: any RepositorySpotlightIndexing = CoreSpotlightRepositoryIndex(),
        notificationCenter: NotificationCenter = .default
    ) {
        self.database = database
        self.settings = settings
        self.index = index
        self.notificationCenter = notificationCenter
    }

    deinit {
        scheduledRebuildTask?.cancel()
        observationTasks.forEach { $0.cancel() }
    }

    /// App Intents 查询在独立系统入口恢复实体时，仍复用当前服务和账号数据库。
    func registerAppIntentDependency() {
        AppDependencyManager.shared.add(dependency: self)
    }

    /// 只在生产 App 生命周期启动一次；测试显式调用具体方法，避免触碰系统 Spotlight。
    func startObserving() {
        guard observationTasks.isEmpty else { return }

        observationTasks.append(observeRepositorySourceChanges())
        observationTasks.append(observeNoteChanges())
        observationTasks.append(observePreferenceChanges())

        if settings.spotlightSearchEnabled {
            scheduleRebuild()
        } else {
            scheduleRemoveAll()
        }
    }

    /// 同步完成或账号切换到已登录数据库后调用。重复请求会取消尚未开始写索引的旧重建。
    func scheduleRebuild() {
        scheduledRebuildTask?.cancel()
        scheduledRebuildTask = Task { [weak self] in
            // 合并同一 run loop 内的同步、账号切换和设置变更，避免连续全量读库。
            await Task.yield()
            guard !Task.isCancelled else { return }
            await self?.rebuild()
        }
    }

    /// 账号退出或切换前必须 await，保证旧账号条目先从系统索引删除。
    func removeAll() async {
        scheduledRebuildTask?.cancel()
        await performRemoveAll()
    }

    /// 与任务调度解耦的实际清理入口。
    ///
    /// 调度任务不能调用公开 `removeAll()`，否则会先取消自己；虽然当前系统索引桥接
    /// 使用独立串行任务链，仍不应依赖未结构化任务的取消继承细节来保证隐私清理。
    private func performRemoveAll() async {
        do {
            try await index.removeAll()
        } catch {
            recordFailure(operation: "spotlight.removeAll", error: error)
        }
    }

    /// EntityQuery 只恢复系统点名的 IDs，不无请求枚举私人内容。
    func entities(for identifiers: [RepositorySpotlightEntity.ID]) async -> [RepositorySpotlightEntity] {
        guard settings.spotlightSearchEnabled else { return [] }
        let repositoryIDs = identifiers.compactMap(Int64.init)
        guard !repositoryIDs.isEmpty else { return [] }

        do {
            let snapshots = try await fetchSnapshots(repositoryIDs: repositoryIDs)
            let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.repositoryID, $0.entity) })
            return repositoryIDs.compactMap { byID[$0] }
        } catch {
            recordFailure(operation: "spotlight.resolveEntities", error: error)
            return []
        }
    }

    /// 单仓库内容变化后的幂等刷新：仍符合索引条件则 upsert，否则删除旧条目。
    func refresh(repositoryID: Int64) async {
        guard settings.spotlightSearchEnabled else { return }
        do {
            if let snapshot = try await fetchSnapshot(repositoryID: repositoryID) {
                try await index.upsert(snapshot.entity)
            } else {
                try await index.remove(identifiers: [String(repositoryID)])
            }
        } catch {
            recordFailure(operation: "spotlight.refreshRepository", error: error, repositoryID: repositoryID)
        }
    }

    /// 立即把当前用户数据库与 Spotlight 对齐；同步钩子通常走 `scheduleRebuild()` 合并请求。
    ///
    /// 保留为 internal 便于单元测试注入内存索引并验证 private repo、笔记和删除边界，
    /// 测试不会因此写入真实系统 Spotlight。
    func rebuild() async {
        guard settings.spotlightSearchEnabled else {
            await performRemoveAll()
            return
        }

        do {
            let snapshots = try await fetchSnapshots()
            try Task.checkCancellation()
            try await index.replaceAll(with: snapshots.map(\.entity))
            AppLog.general.info(
                "Spotlight repository index rebuilt (count=\(snapshots.count, privacy: .public))"
            )
        } catch is CancellationError {
            return
        } catch {
            recordFailure(operation: "spotlight.rebuild", error: error)
        }
    }

    private func scheduleRemoveAll() {
        scheduledRebuildTask?.cancel()
        scheduledRebuildTask = Task { [weak self] in
            await self?.performRemoveAll()
        }
    }

    private func observeRepositorySourceChanges() -> Task<Void, Never> {
        Task { [weak self, notificationCenter] in
            let stream = notificationCenter.notifications(named: .repositorySpotlightSourceDidChange)
            for await notification in stream {
                guard !Task.isCancelled else { break }
                guard let repositoryID = notification.userInfo?["repoId"] as? Int64 else { continue }
                await self?.refresh(repositoryID: repositoryID)
            }
        }
    }

    private func observeNoteChanges() -> Task<Void, Never> {
        Task { [weak self, notificationCenter] in
            let stream = notificationCenter.notifications(named: .repoNoteContentDidChange)
            for await notification in stream {
                guard !Task.isCancelled else { break }
                guard let repositoryID = notification.userInfo?["repoId"] as? Int64 else { continue }
                await self?.refresh(repositoryID: repositoryID)
            }
        }
    }

    private func observePreferenceChanges() -> Task<Void, Never> {
        Task { [weak self, notificationCenter] in
            let stream = notificationCenter.notifications(named: .spotlightSearchPreferenceDidChange)
            for await _ in stream {
                guard !Task.isCancelled, let self else { break }
                if self.settings.spotlightSearchEnabled {
                    self.scheduleRebuild()
                } else {
                    await self.removeAll()
                }
            }
        }
    }

    private func fetchSnapshots() async throws -> [RepositorySpotlightSnapshot] {
        try await database.writer.read { db in
            try RepositorySpotlightSnapshot.fetchAll(
                db,
                sql: Self.eligibleRepositoriesSQL
            )
        }
    }

    private func fetchSnapshot(repositoryID: Int64) async throws -> RepositorySpotlightSnapshot? {
        try await database.writer.read { db in
            try RepositorySpotlightSnapshot.fetchOne(
                db,
                sql: "\(Self.eligibleRepositoriesSQL) AND r.id = ?",
                arguments: [repositoryID]
            )
        }
    }

    private func fetchSnapshots(repositoryIDs: [Int64]) async throws -> [RepositorySpotlightSnapshot] {
        try await database.writer.read { db in
            var snapshots: [RepositorySpotlightSnapshot] = []
            snapshots.reserveCapacity(repositoryIDs.count)
            for repositoryID in repositoryIDs {
                if let snapshot = try RepositorySpotlightSnapshot.fetchOne(
                    db,
                    sql: "\(Self.eligibleRepositoriesSQL) AND r.id = ?",
                    arguments: [repositoryID]
                ) {
                    snapshots.append(snapshot)
                }
            }
            return snapshots
        }
    }

    /// 只读取 starred 且仍可访问的仓库。private repository 不在过滤条件中，因为用户
    /// 已通过总开关明确授权；LEFT JOIN 让没有笔记的仓库也能正常进入 Spotlight。
    nonisolated private static let eligibleRepositoriesSQL = """
        SELECT r.id AS repository_id,
               r.owner,
               r.name,
               r.description AS repository_description,
               r.language,
               r.topics AS topics_json,
               NULLIF(TRIM(n.content), '') AS note
        FROM repos AS r
        LEFT JOIN repo_notes AS n ON n.repo_id = r.id
        WHERE r.is_starred = 1
          AND r.access_state = 'accessible'
        """

    private func recordFailure(operation: String, error: any Error, repositoryID: Int64? = nil) {
        AppLog.general.error(
            "Spotlight repository indexing failed (operation=\(operation, privacy: .public)): \(error.localizedDescription, privacy: .public)"
        )
        var context: [String: String] = [:]
        if let repositoryID {
            context["repoID"] = String(repositoryID)
        }
        DiagnosticLogStore.record(
            level: .error,
            visibility: .issue,
            category: "systemIntegration",
            operation: operation,
            message: "Spotlight repository index update failed",
            underlying: DiagnosticEvent.summarize(error),
            context: context
        )
    }
}

extension Notification.Name {
    /// repos 的 Star 或可访问状态已变化，Spotlight 应重新判断该仓库是否仍可索引。
    static let repositorySpotlightSourceDidChange = Notification.Name(
        "StarcatRepositorySpotlightSourceDidChange"
    )

    /// AppSettings 中的 Spotlight 明确授权发生变化。
    static let spotlightSearchPreferenceDidChange = Notification.Name(
        "StarcatSpotlightSearchPreferenceDidChange"
    )
}
