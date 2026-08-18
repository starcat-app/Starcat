//
//  KnowledgeRAGIndexBuilder.swift
//  Starcat
//
//  知识库范围的 source 级增量索引器。
//
//  索引器只读取 `fetchKnowledgeRepos()` 或显式确认仍为 `.inLibrary` 的 repo。全量构建会先补齐
//  缺失的 README Markdown，再分别 replace README、notes、summary、metadata。Meilisearch 文本
//  索引在 embedding 开始前全量同步；向量后端仍等 batch ready 后增量写入。embedding 失败时只
//  标记当前 batch，不删除已经 ready 的其它 chunks。
//

import Foundation
import Observation

/// Wiki cache 通知到 Metadata 刷新 identity 的唯一解析入口。
///
/// DiskWikiCache、前台 UI 与索引器共享同一 payload 契约；把解析保持为纯函数，才能用
/// 单元测试防止字段名变化后索引器静默停止增量重建。
enum RAGWikiMetadataRefreshRoute {
    static func changedRepository(from notification: Notification) -> WikiRepoKey? {
        guard let owner = notification.userInfo?["owner"] as? String,
              let repo = notification.userInfo?["repo"] as? String else { return nil }
        return WikiRepoKey(owner: owner, repo: repo)
    }

    static func resetRepositories(from notification: Notification) -> [WikiRepoKey] {
        notification.userInfo?["repositoryKeys"] as? [WikiRepoKey] ?? []
    }
}

enum RAGIndexingStatus: Equatable, Sendable {
    case idle
    case fetchingReadmes(processedRepos: Int, totalRepos: Int)
    case building(processedRepos: Int, totalRepos: Int)
    /// `processedChunks / totalChunks` 是当前模型的向量覆盖（已就绪 / 应向量化），不是本轮队列游标。
    case embedding(processedChunks: Int, totalChunks: Int)
    case completed(RAGIndexStatusProjection)
    case failed(String)

    var isActivelyIndexing: Bool {
        switch self {
        case .fetchingReadmes, .building, .embedding: true
        case .idle, .completed, .failed: false
        }
    }

    /// 只有实际调用 embedding API 时才暴露向量覆盖；全库 FTS 覆盖率不能代替向量化进度。
    var embeddingProgress: (processedChunks: Int, totalChunks: Int)? {
        guard case let .embedding(processedChunks, totalChunks) = self,
              totalChunks > 0 else {
            return nil
        }
        return (min(max(processedChunks, 0), totalChunks), totalChunks)
    }
}

/// 用户手动刷新全库时展示的阶段汇总。阶段切换后仍保留已完成阶段的数据，避免快速刷新让用户错过过程。
struct RAGIndexRefreshSummary: Equatable, Sendable {
    let totalRepos: Int
    var readmesProcessed: Int
    /// source 构建以仓库为单位；不能与后续按 chunk 计数的 embedding 混用。
    var sourceReposProcessed: Int
    /// 当前这轮实际需要调用 embedding API 的分片进度。
    var embeddingProcessed: Int
    var embeddingTotal: Int
    /// 开始 embedding 时的索引覆盖快照，用于在数据库最终汇总前平滑推进工作台进度条。
    var readyChunksBeforeEmbedding: Int
    var totalChunksAtEmbedding: Int
    var completedAt: Date?

    /// 只在本轮 embedding 期间使用的已向量化分片数；上限钳制避免异常响应让进度条越界。
    var embeddingReadyChunks: Int {
        min(totalChunksAtEmbedding, readyChunksBeforeEmbedding + embeddingProcessed)
    }
}

/// RAG 批处理的有界并发执行器。只维持 `maxConcurrentTasks` 个在途任务，
/// 每完成一项再补一项，避免为大知识库一次创建数千个 Task。
enum RAGBoundedTaskExecutor {
    static func forEach<Element: Sendable>(
        _ elements: [Element],
        maxConcurrentTasks: Int,
        operation: @escaping @Sendable (Element) async throws -> Void,
        didComplete: @escaping @Sendable (Int) async -> Void
    ) async throws {
        guard !elements.isEmpty else { return }
        let concurrencyLimit = max(1, maxConcurrentTasks)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var nextIndex = 0

            func scheduleNext() {
                guard nextIndex < elements.count else { return }
                let element = elements[nextIndex]
                nextIndex += 1
                group.addTask {
                    try Task.checkCancellation()
                    try await operation(element)
                }
            }

            for _ in 0..<min(concurrencyLimit, elements.count) {
                scheduleNext()
            }

            var completed = 0
            while try await group.next() != nil {
                completed += 1
                await didComplete(completed)
                try Task.checkCancellation()
                scheduleNext()
            }
        }
    }
}

private struct RAGExternalIndexSyncFingerprint: Equatable {
    var keywordBackend: RAGKeywordBackend
    var vectorBackend: RAGVectorBackend
    var meilisearch: RAGMeilisearchConfiguration?
    var qdrant: RAGQdrantConfiguration?
    var embeddingModel: String

    init(configuration: RAGBackendConfiguration, embeddingModel: String) {
        self.keywordBackend = configuration.keywordBackend
        self.vectorBackend = configuration.vectorBackend
        self.meilisearch = configuration.keywordBackend == .meilisearch ? configuration.meilisearch : nil
        self.qdrant = configuration.vectorBackend == .qdrant ? configuration.qdrant : nil
        self.embeddingModel = embeddingModel
    }
}

/// 用户手动重建会取消当前工作；自动增量在忙时只合并，不能把正在跑的 embedding 掐掉重来。
private enum RAGExclusiveWorkPolicy {
    case replaceRunning
    case waitInQueue
}

/// 自动 README / notes / 入库在互斥通道忙碌时合并到这里，当前一轮结束后再 drain。
private struct RAGPendingAutoIndexWork {
    var fullRebuild = false
    var repoSources: [Int64: Set<RAGChunkSource>] = [:]
    var libraryAddIDs: [Int64] = []

    var isEmpty: Bool {
        !fullRebuild && repoSources.isEmpty && libraryAddIDs.isEmpty
    }

    mutating func reset() {
        self = RAGPendingAutoIndexWork()
    }
}

/// 单 source 刷新的最小读取集合。Metadata 需要 Note 中的状态/入库时间和用户标签，
/// 其它 source 之间没有隐式依赖，不能因为共用 Builder 就读取无关表或大正文。
struct RAGSourceReadPlan: Equatable, Sendable {
    var readsReadme: Bool
    var readsNote: Bool
    var readsSummary: Bool
    var readsTags: Bool
    var readsMetadataSnapshot: Bool

    init(sources: Set<RAGChunkSource>) {
        readsReadme = sources.contains(.readme)
        readsNote = sources.contains(.notes) || sources.contains(.metadata)
        readsSummary = sources.contains(.summary)
        readsTags = sources.contains(.metadata)
        readsMetadataSnapshot = sources.contains(.metadata)
    }
}

@MainActor
@Observable
final class KnowledgeRAGIndexBuilder {
    private let chunkRepository: any RAGChunkRepositoryProtocol
    private let repoRepository: any RepoRepositoryProtocol
    private let readmeRepository: ReadmeRepository
    private let readmeAPI: ReadmeAPI
    private let noteRepository: any RepoNoteRepositoryProtocol
    private let summaryRepository: any AISummaryRepositoryProtocol
    private let repoTagRepository: any RepoTagRepositoryProtocol
    /// 都是本地缓存读取接口；Metadata 重建禁止触发 GitHub / OpenSSF 网络请求。
    private let releaseRepository: (any ReleaseRepositoryProtocol)?
    private let healthRepository: (any RepoHealthRepositoryProtocol)?
    private let openSSFRepository: (any OpenSSFScoreRepositoryProtocol)?
    /// Wiki 只读磁盘缓存；索引器不得持有 Wiki API 或等待外部网络。
    private let wikiCache: DiskWikiCache?
    private let settings: AppSettings
    private let entitlementGate: EntitlementGate
    private let keychain: any KeychainManaging
    private let builder: RAGChunkBuilder
    private let embeddingBatchSize: Int

    /// README HTML 与 Markdown 各自独立请求；限制单次请求，避免离线网络阻塞整轮索引。
    private static let readmeRequestTimeout: TimeInterval = 15
    /// GitHub 请求保持小幅并发：相比串行减少大库等待，又不会突发占满限额与连接。
    private static let readmeFetchConcurrency = 3

    private(set) var status: RAGIndexingStatus = .idle
    /// 仅由显式的全库刷新创建；自动 source 更新与单仓库刷新不能覆盖用户刚完成的全局结果。
    private(set) var refreshSummary: RAGIndexRefreshSummary?
    /// 单仓库刷新只影响知识库浏览器自己的时间戳，不能覆盖工作台的全局构建汇总。
    private(set) var repositoryRefreshDates: [Int64: Date] = [:]
    /// 所有写索引的工作走这一条 Task：暂停取消它，而不是只取消旧的 `startRebuild` 包装。
    private var exclusiveLock: Task<Void, Error>?
    private var workGeneration: UInt64 = 0
    /// 当前正在执行的那一轮 generation；`cancel()` 先加 generation，后到的 HTTP 就不能再改 status。
    private var activeWorkGeneration: UInt64 = 0
    private var exclusiveRunning = false
    private var pendingAuto = RAGPendingAutoIndexWork()
    private var refreshSummaryRestoreTask: Task<Void, Never>?
    private var observationTasks: [Task<Void, Never>] = []
    private var debouncedSourceTasks: [Int64: Task<Void, Never>] = [:]
    /// 同一 repo 在 debounce 窗口内的多个事实变更要合并，不能让 notes 事件覆盖 metadata 事件。
    private var debouncedSources: [Int64: Set<RAGChunkSource>] = [:]
    /// source debounce 和全库循环产生的多次 diff 先合并。关键词可在 embedding 前全量同步；
    /// 向量变更仍在 embedding 结束后提交，避免把未 ready 的空向量写入 Qdrant。
    private var externalIndexChanges = RAGExternalIndexChangeSet()
    /// 关键词 / 向量指纹分开：Meilisearch 先同步不能把 Qdrant 也标成已初始化。
    private var lastKeywordSyncFingerprint: RAGExternalIndexSyncFingerprint?
    private var lastVectorSyncFingerprint: RAGExternalIndexSyncFingerprint?
    private var isSuspendedForDatabaseChange = false
    private var activeOperationCount = 0
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        chunkRepository: any RAGChunkRepositoryProtocol,
        repoRepository: any RepoRepositoryProtocol,
        readmeRepository: ReadmeRepository,
        readmeAPI: ReadmeAPI,
        noteRepository: any RepoNoteRepositoryProtocol,
        summaryRepository: any AISummaryRepositoryProtocol,
        repoTagRepository: any RepoTagRepositoryProtocol,
        releaseRepository: (any ReleaseRepositoryProtocol)? = nil,
        healthRepository: (any RepoHealthRepositoryProtocol)? = nil,
        openSSFRepository: (any OpenSSFScoreRepositoryProtocol)? = nil,
        wikiCache: DiskWikiCache? = nil,
        settings: AppSettings,
        entitlementGate: EntitlementGate,
        keychain: any KeychainManaging = KeychainManager.shared,
        builder: RAGChunkBuilder = RAGChunkBuilder(),
        embeddingBatchSize: Int = 32
    ) {
        self.chunkRepository = chunkRepository
        self.repoRepository = repoRepository
        self.readmeRepository = readmeRepository
        self.readmeAPI = readmeAPI
        self.noteRepository = noteRepository
        self.summaryRepository = summaryRepository
        self.repoTagRepository = repoTagRepository
        self.releaseRepository = releaseRepository
        self.healthRepository = healthRepository
        self.openSSFRepository = openSSFRepository
        self.wikiCache = wikiCache
        self.settings = settings
        self.entitlementGate = entitlementGate
        self.keychain = keychain
        self.builder = builder
        // 配置异常时仍保证队列每轮能前进，避免 limit=0 导致空轮询。
        self.embeddingBatchSize = max(1, embeddingBatchSize)
        restorePersistedRefreshSummary()
    }

    func startRebuild(userInitiated: Bool = true) {
        guard !isSuspendedForDatabaseChange else { return }
        if !userInitiated, exclusiveRunning {
            pendingAuto.fullRebuild = true
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.rebuildKnowledgeBase(recordsRefreshSummary: false)
            } catch is CancellationError {
                // `cancel()` 已把状态打成 idle；被更新一轮替换时也不要覆盖新状态。
            } catch {
                self.assignStatus(.failed(error.localizedDescription))
                self.recordDeveloperDiagnosticIfNeeded(error, operation: "rag.rebuild")
                NotificationCenter.default.post(name: .knowledgeRAGIndexDidChange, object: nil)
            }
        }
    }

    func cancel() {
        workGeneration += 1
        pendingAuto.reset()
        exclusiveLock?.cancel()
        exclusiveRunning = false
        status = .idle
    }

    /// 多账号切库前建立写入屏障。仅取消已知 Task 不够：Stars 同步回调可能正在执行 metadata
    /// 刷新，因此还要等待所有已进入索引临界区的操作退出，避免旧账号任务在新 DB 上续写。
    func suspendForUserDatabaseChange() async {
        isSuspendedForDatabaseChange = true
        workGeneration += 1
        pendingAuto.reset()
        exclusiveRunning = false
        exclusiveLock?.cancel()
        let tasks = [refreshSummaryRestoreTask].compactMap { $0 }
            + observationTasks
            + Array(debouncedSourceTasks.values)
        tasks.forEach { $0.cancel() }
        _ = try? await exclusiveLock?.value
        for task in tasks {
            await task.value
        }
        exclusiveLock = nil
        refreshSummaryRestoreTask = nil
        observationTasks.removeAll()
        debouncedSourceTasks.removeAll()
        debouncedSources.removeAll()
        externalIndexChanges.reset()
        lastKeywordSyncFingerprint = nil
        lastVectorSyncFingerprint = nil
        await waitUntilIdle()
        status = .idle
        refreshSummary = nil
    }

    /// 数据库切换无论成功还是失败都恢复 source 监听；失败时仍然服务原数据库。
    func resumeAfterUserDatabaseChange() {
        isSuspendedForDatabaseChange = false
        startObservingSourceChanges()
        restorePersistedRefreshSummary()
    }

    /// 监听索引输入变化。AppDependencies 只调用一次；notes 使用 1.5 秒 debounce，避免
    /// 连续编辑时每次键入都触发 embedding。README / 摘要事件来自 Repository，保证页面、
    /// 后台预取和批量生成路径都不会漏掉；标签和入库状态是离散操作，可立即刷新。
    func startObservingSourceChanges() {
        guard observationTasks.isEmpty else { return }
        observationTasks.append(Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .readmeContentDidChange)
            for await notification in stream {
                if let repoID = notification.userInfo?["repoId"] as? Int64 {
                    await self?.refresh(repoID: repoID, sources: [.readme])
                } else {
                    self?.startRebuild(userInitiated: false)
                }
            }
        })
        observationTasks.append(Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .repoNoteContentDidChange)
            for await notification in stream {
                guard let repoID = notification.userInfo?["repoId"] as? Int64 else { continue }
                self?.scheduleDebouncedRefresh(repoID: repoID, sources: [.notes])
            }
        })
        observationTasks.append(Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .aiSummaryDidChange)
            for await notification in stream {
                guard let repoID = notification.userInfo?["repoId"] as? Int64 else { continue }
                await self?.refresh(repoID: repoID, sources: [.summary])
            }
        })
        observationTasks.append(Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .repoTagsDidChange)
            for await notification in stream {
                guard let repoID = notification.userInfo?["repoId"] as? Int64 else { continue }
                self?.scheduleDebouncedRefresh(repoID: repoID, sources: [.metadata])
            }
        })
        observationTasks.append(Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .repoLibraryStateDidChange)
            for await notification in stream {
                guard let repoID = notification.userInfo?["repoId"] as? Int64,
                      let raw = notification.userInfo?["libraryState"] as? String,
                      let state = LibraryState(rawValue: raw) else { continue }
                if state == .inLibrary {
                    await self?.indexNewlyAddedKnowledgeRepository(repoID: repoID)
                } else {
                    await self?.removeRepositoryFromExternalIndexes(repoID: repoID)
                }
            }
        })
        for notificationName in [
            Notification.Name.repoStatusDidChange,
            .releaseRecordsDidChange,
            .repoHealthSnapshotDidChange,
            .openSSFScoreDidChange
        ] {
            observationTasks.append(Task { [weak self] in
                let stream = NotificationCenter.default.notifications(named: notificationName)
                for await notification in stream {
                    guard let repoID = notification.userInfo?["repoId"] as? Int64 else { continue }
                    self?.scheduleDebouncedRefresh(repoID: repoID, sources: [.metadata])
                }
            })
        }
        observationTasks.append(Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .wikiCacheDidChange)
            for await notification in stream {
                guard let key = RAGWikiMetadataRefreshRoute.changedRepository(from: notification),
                      let repo = try? await self?.repoRepository.findByOwnerName(owner: key.owner, name: key.repo)
                else { continue }
                await self?.refresh(repo: repo, sources: [.metadata])
            }
        })
        observationTasks.append(Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .wikiCacheDidReset)
            for await notification in stream {
                guard let self else { continue }
                let keys = RAGWikiMetadataRefreshRoute.resetRepositories(from: notification)
                for key in keys {
                    // 清空缓存可能涉及大量仓库；builder 停止或切库后必须立刻退出，
                    // 不能吞掉 CancellationError 后继续访问已经切换的 repository。
                    guard !Task.isCancelled else { return }
                    guard let repo = try? await self.repoRepository.findByOwnerName(owner: key.owner, name: key.repo)
                    else { continue }
                    await self.refresh(repo: repo, sources: [.metadata])
                }
            }
        })
    }

    /// 全量重建只表示“重新计算 source diff + 补齐待处理 embedding”，内容未变的 ready chunk
    /// 仍复用原向量。真正强制换向量由 embedding model 变化触发 stale。
    func rebuildKnowledgeBase(recordsRefreshSummary: Bool = true) async throws {
        try await withExclusiveWork(policy: .replaceRunning) {
            try await self.performRebuildKnowledgeBase(recordsRefreshSummary: recordsRefreshSummary)
        }
    }

    /// 知识库浏览器手动刷新与“加入知识库”自动补全共用单仓库重建。
    ///
    /// `fetchMissingReadmes` 最终经过 `ReadmeInflightTracker`：如果 README 后台预拉已在处理
    /// 同一个 repo，两个入口会等待同一份 HTML / Markdown 请求结果，不会重复消耗 GitHub 配额。
    func rebuildRepository(_ repo: Repo) async throws {
        try await withExclusiveWork(policy: .waitInQueue) {
            try await self.performRebuildRepository(repo)
        }
    }

    /// 单 source 更新入口。调用方在 README / notes / summary / metadata 变化后使用；移出知识库
    /// 时直接跳过并保留缓存，由 Retriever 的 SQL join 保证不再召回。
    func refresh(repo: Repo, sources: Set<RAGChunkSource>) async {
        guard !isSuspendedForDatabaseChange else { return }
        if exclusiveRunning {
            pendingAuto.repoSources[repo.id, default: []].formUnion(sources)
            return
        }
        do {
            try await withExclusiveWork(policy: .waitInQueue) {
                await self.performRefresh(repo: repo, sources: sources)
            }
        } catch is CancellationError {
            return
        } catch {
            AppLog.ai.error("RAG source refresh scheduling failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func coverage() async throws -> RAGIndexStatusProjection {
        try await chunkRepository.coverage(model: resolvedEmbeddingModel())
    }

    /// 人工编辑会把分片置为 pending；仅补向量，不重拉 README 或重建其它 source，避免编辑后
    /// 还要用户手动点击刷新才能重新参与召回。
    func embedEditedChunks(_ chunks: [RAGDeletedChunkIdentity] = []) async throws {
        try await withExclusiveWork(policy: .waitInQueue) {
            try await self.performEmbedEditedChunks(chunks)
        }
    }

    /// 下架和永久删除也不经过 source diff。这里保留 source，确保 Metadata 只删除
    /// Meilisearch 文档，不向 Qdrant 发送无意义的点删除请求。
    func removeManagedChunksFromExternalIndexes(_ chunks: [RAGDeletedChunkIdentity]) async throws {
        try await withExclusiveWork(policy: .waitInQueue) {
            try await self.performRemoveManagedChunksFromExternalIndexes(chunks)
        }
    }

    /// GitHub stars 同步完成后批量刷新 metadata source。Metadata 是 FTS-only，不会产生 embedding。
    func refreshMetadataForKnowledgeRepos() async {
        do {
            try await withExclusiveWork(policy: .waitInQueue) {
                await self.performRefreshMetadataForKnowledgeRepos()
            }
        } catch is CancellationError {
            return
        } catch {
            AppLog.ai.error("RAG metadata refresh scheduling failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleDebouncedRefresh(repoID: Int64, sources: Set<RAGChunkSource>) {
        guard !isSuspendedForDatabaseChange else { return }
        debouncedSources[repoID, default: []].formUnion(sources)
        debouncedSourceTasks[repoID]?.cancel()
        debouncedSourceTasks[repoID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                let mergedSources = self.debouncedSources.removeValue(forKey: repoID) ?? sources
                self.debouncedSourceTasks[repoID] = nil
                await self.refresh(repoID: repoID, sources: mergedSources)
            } catch {
                // 新编辑会取消旧 debounce；取消不是索引错误。
            }
        }
    }

    private func refresh(repoID: Int64, sources: Set<RAGChunkSource>) async {
        guard let repo = try? await repoRepository.findById(repoID) else { return }
        await refresh(repo: repo, sources: sources)
    }

    /// 新入库的 repo 属于用户明确要求沉淀的内容，因此主动补齐 README 后再建立完整索引。
    /// 此路径不能复用普通 source refresh：后者只读取本地 Markdown，会留下仅 metadata 的半成品索引。
    private func indexNewlyAddedKnowledgeRepository(repoID: Int64) async {
        if exclusiveRunning {
            if !pendingAuto.libraryAddIDs.contains(repoID) {
                pendingAuto.libraryAddIDs.append(repoID)
            }
            return
        }
        guard let repo = try? await repoRepository.findById(repoID) else { return }
        do {
            try await rebuildRepository(repo)
        } catch EntitlementGateError.requiresPro {
            // 非 Pro 用户不建立 RAG 索引，保持既有静默门禁语义。
        } catch is CancellationError {
            // 切换账号或停止索引属于正常生命周期，不进入开发者诊断。
        } catch {
            AppLog.ai.error("RAG library-add indexing failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            recordDeveloperDiagnosticIfNeeded(error, operation: "rag.indexLibraryAddition", repo: repo.fullName)
            NotificationCenter.default.post(name: .knowledgeRAGIndexDidChange, object: nil)
        }
    }

    /// RAG 同时跨网络、Provider 与本地数据库；只有统一错误分类明确判定为本地数据、
    /// 安全存储或响应契约损坏时才进入 issue，避免缺 Key、断网和 Provider 失败误报。
    private func recordDeveloperDiagnosticIfNeeded(
        _ error: Error,
        operation: String,
        repo: String? = nil
    ) {
        let friendly = UserFacingError.map(error, operation: operation, service: "Starcat")
        guard friendly.shouldRecordDiagnostic else { return }
        DiagnosticLogStore.record(
            level: .error,
            visibility: .issue,
            category: "rag-index",
            operation: operation,
            message: "Knowledge RAG indexing failed because of a local or contract error",
            underlying: friendly.diagnosticSummary,
            context: repo.map { ["repo": $0] } ?? [:]
        )
    }

    /// 本地 chunk 作为可重建缓存继续保留，但移出知识库后要立即删除自托管后端副本。
    private func removeRepositoryFromExternalIndexes(repoID: Int64) async {
        do {
            try await withExclusiveWork(policy: .waitInQueue) {
                try await self.performRemoveRepositoryFromExternalIndexes(repoID: repoID)
            }
        } catch is CancellationError {
            return
        } catch {
            AppLog.ai.error("RAG external removal sync failed for repo \(repoID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performRebuildKnowledgeBase(recordsRefreshSummary: Bool) async throws {
        guard beginOperation() else { throw CancellationError() }
        defer { endOperation() }
        try entitlementGate.requirePro(.knowledgeRAG)
        let repos = try await repoRepository.fetchKnowledgeRepos()
        if recordsRefreshSummary {
            refreshSummary = RAGIndexRefreshSummary(
                totalRepos: repos.count,
                readmesProcessed: 0,
                sourceReposProcessed: 0,
                embeddingProcessed: 0,
                embeddingTotal: 0,
                readyChunksBeforeEmbedding: 0,
                totalChunksAtEmbedding: 0,
                // 刷新中继续显示上一轮完成时间；新时间只在本轮真正完成时替换，避免布局跳动。
                completedAt: refreshSummary?.completedAt
            )
        }
        let summaries = try await summaryRepository.fetchLatestPerRepo()
        try await fetchMissingReadmes(for: repos, recordsRefreshSummary: recordsRefreshSummary)
        for (index, repo) in repos.enumerated() {
            try Task.checkCancellation()
            assignStatus(.building(processedRepos: index, totalRepos: repos.count))
            try await rebuildSources(for: repo, summary: summaries[repo.id], sources: Set(RAGChunkSource.allCases))
            if recordsRefreshSummary {
                updateRefreshSummary(sourceReposProcessed: index + 1)
            }
        }
        assignStatus(.building(processedRepos: repos.count, totalRepos: repos.count))
        if recordsRefreshSummary {
            updateRefreshSummary(sourceReposProcessed: repos.count)
        }
        try await embedPendingChunks(recordsRefreshSummary: recordsRefreshSummary)
    }

    private func performRebuildRepository(_ repo: Repo) async throws {
        guard beginOperation() else { throw CancellationError() }
        defer { endOperation() }
        try entitlementGate.requirePro(.knowledgeRAG)
        guard try await noteRepository.fetchLibraryState(repoId: repo.id) == .inLibrary else { return }

        let summary = try await summaryRepository.fetchLatest(repoId: repo.id)
        try await fetchMissingReadmes(for: [repo], recordsRefreshSummary: false)
        assignStatus(.building(processedRepos: 0, totalRepos: 1))
        try await rebuildSources(for: repo, summary: summary, sources: Set(RAGChunkSource.allCases))
        assignStatus(.building(processedRepos: 1, totalRepos: 1))
        try await embedPendingChunks()
        repositoryRefreshDates[repo.id] = Date()
    }

    private func performRefresh(repo: Repo, sources: Set<RAGChunkSource>) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        do {
            try entitlementGate.requirePro(.knowledgeRAG)
            guard try await noteRepository.fetchLibraryState(repoId: repo.id) == .inLibrary else { return }
            let summary = sources.contains(.summary)
                ? try await summaryRepository.fetchLatest(repoId: repo.id)
                : nil
            try await rebuildSources(for: repo, summary: summary, sources: sources)
            try await embedPendingChunks()
        } catch EntitlementGateError.requiresPro {
            return
        } catch is CancellationError {
            return
        } catch {
            AppLog.ai.error("RAG source refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            recordDeveloperDiagnosticIfNeeded(error, operation: "rag.refreshSources", repo: repo.fullName)
            NotificationCenter.default.post(name: .knowledgeRAGIndexDidChange, object: nil)
        }
    }

    private func performEmbedEditedChunks(_ chunks: [RAGDeletedChunkIdentity]) async throws {
        guard beginOperation() else { throw CancellationError() }
        defer { endOperation() }
        try entitlementGate.requirePro(.knowledgeRAG)
        // 人工编辑与恢复不经过 source diff；先登记 ID，Metadata 才能直接 upsert，
        // 普通正文则会在本轮 embedding ready 后用同一 ID 覆盖 pending 变更。
        externalIndexChanges.recordUpserts(chunks.map(\.id))
        try await embedPendingChunks()
    }

    private func performRemoveManagedChunksFromExternalIndexes(_ chunks: [RAGDeletedChunkIdentity]) async throws {
        guard beginOperation() else { throw CancellationError() }
        defer { endOperation() }
        externalIndexChanges.recordDeletes(chunks)
        try await syncExternalBackends(model: resolvedEmbeddingModel())
    }

    private func performRefreshMetadataForKnowledgeRepos() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        do {
            try entitlementGate.requirePro(.knowledgeRAG)
            let repos = try await repoRepository.fetchKnowledgeRepos()
            for repo in repos {
                try Task.checkCancellation()
                try await rebuildSources(for: repo, summary: nil, sources: [.metadata])
            }
            // 其它 source 的 pending chunk 仍可能来自此前编辑；这里补齐不会包含 Metadata。
            try await embedPendingChunks()
        } catch EntitlementGateError.requiresPro {
            return
        } catch is CancellationError {
            return
        } catch {
            AppLog.ai.error("RAG metadata refresh failed: \(error.localizedDescription, privacy: .public)")
            recordDeveloperDiagnosticIfNeeded(error, operation: "rag.refreshMetadata")
        }
    }

    private func performRemoveRepositoryFromExternalIndexes(repoID: Int64) async throws {
        guard beginOperation() else { return }
        defer { endOperation() }
        let identities = try await chunkRepository.fetchChunkIdentities(repoId: repoID)
        externalIndexChanges.recordDeletes(identities)
        try await syncExternalBackends(model: resolvedEmbeddingModel())
    }

    private func rebuildSources(
        for repo: Repo,
        summary: AISummaryRecord?,
        sources: Set<RAGChunkSource>
    ) async throws {
        let readPlan = RAGSourceReadPlan(sources: sources)
        let note = readPlan.readsNote ? try await noteRepository.find(repoId: repo.id) : nil
        let tags = readPlan.readsTags
            ? try await repoTagRepository.fetchTags(forRepo: repo.id).map(\.name)
            : []
        let readme = readPlan.readsReadme ? try await readmeRepository.findContent(repoId: repo.id) : nil
        let summaryText = readPlan.readsSummary ? summary.flatMap(Self.summaryText) : nil
        let metadataSnapshot = readPlan.readsMetadataSnapshot ? await loadMetadataSnapshot(repo: repo) : nil
        let output = try await RAGChunkBuildExecutor.build(RAGChunkBuildInput(
            repo: repo,
            readme: readme,
            note: note,
            summaryText: summaryText,
            summarySourceID: summary?.model ?? "",
            tags: tags,
            metadataSnapshot: metadataSnapshot
        ), using: builder)

        if sources.contains(.readme) {
            let result = try await chunkRepository.replaceSource(repoId: repo.id, source: .readme, drafts: output.readme)
            externalIndexChanges.merge(result)
        }
        if sources.contains(.notes) {
            let result = try await chunkRepository.replaceSource(repoId: repo.id, source: .notes, drafts: output.notes)
            externalIndexChanges.merge(result)
        }
        if sources.contains(.summary) {
            let result = try await chunkRepository.replaceSource(repoId: repo.id, source: .summary, drafts: output.summary)
            externalIndexChanges.merge(result)
        }
        if sources.contains(.metadata) {
            let result = try await chunkRepository.replaceSource(repoId: repo.id, source: .metadata, drafts: output.metadata)
            externalIndexChanges.merge(result)
        }
    }

    /// 从本地缓存聚合 Metadata；单项读取失败时省略该项，不让辅助缓存阻断主索引。
    private func loadMetadataSnapshot(repo: Repo) async -> RAGMetadataSnapshot {
        let latestRelease: ReleaseRecord?
        if let releaseRepository {
            latestRelease = try? await releaseRepository.latest(forRepo: repo.id)
        } else {
            latestRelease = nil
        }
        let health: RepoHealthSnapshot?
        if let healthRepository {
            health = try? await healthRepository.snapshot(for: repo.id)
        } else {
            health = nil
        }
        let openSSF: OpenSSFScoreRecord?
        if let openSSFRepository {
            openSSF = try? await openSSFRepository.record(for: repo.id)
        } else {
            openSSF = nil
        }
        let wikiLinks = repo.isPrivate
            ? []
            : wikiCache?.load(owner: repo.owner, repo: repo.name)?.indexedLinks ?? []
        return RAGMetadataSnapshot(
            latestRelease: latestRelease,
            health: health,
            openSSF: openSSF,
            wikiLinks: wikiLinks
        )
    }

    /// 仅补齐本地没有 Markdown 的 README。索引器不能假设详情页或后台预拉已经访问过仓库，
    /// 否则知识库会退化成只有 metadata 的分片；单仓库失败则保留 metadata 并继续下一项。
    private func fetchMissingReadmes(for repos: [Repo], recordsRefreshSummary: Bool) async throws {
        assignStatus(.fetchingReadmes(processedRepos: 0, totalRepos: repos.count))
        let readmeRepository = self.readmeRepository
        let readmeAPI = self.readmeAPI
        let totalRepos = repos.count

        try await RAGBoundedTaskExecutor.forEach(
            repos,
            maxConcurrentTasks: Self.readmeFetchConcurrency,
            operation: { repo in
                try await Self.fetchMissingReadme(
                    for: repo,
                    readmeRepository: readmeRepository,
                    readmeAPI: readmeAPI
                )
            },
            didComplete: { [weak self] completed in
                await MainActor.run {
                    guard let self else { return }
                    self.assignStatus(.fetchingReadmes(processedRepos: completed, totalRepos: totalRepos))
                    if recordsRefreshSummary {
                        self.updateRefreshSummary(readmesProcessed: completed)
                    }
                }
            }
        )
        assignStatus(.fetchingReadmes(processedRepos: repos.count, totalRepos: repos.count))
        if recordsRefreshSummary {
            updateRefreshSummary(readmesProcessed: repos.count)
        }
    }

    /// 子任务只处理单仓 README，不发布 UI 状态。请求层的 15 秒超时、GitHub 限流和
    /// in-flight 去重均由原 `ReadmeAPI` 路径保留；每次网络 await 后重新检查取消，
    /// 防止 API 将 transport 取消包装成 `.failed` 后继续补发下一个请求。
    private nonisolated static func fetchMissingReadme(
        for repo: Repo,
        readmeRepository: ReadmeRepository,
        readmeAPI: ReadmeAPI
    ) async throws {
        try Task.checkCancellation()
        if let cachedMarkdown = try await readmeRepository.findContent(repoId: repo.id),
           !cachedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        let htmlResult = await readmeAPI.refreshReadme(
            for: repo,
            requestTimeout: Self.readmeRequestTimeout
        )
        try Task.checkCancellation()
        switch htmlResult {
        case .updated, .notModified:
            let markdownResult = await readmeAPI.refreshMarkdownIfNeeded(
                for: repo,
                requestTimeout: Self.readmeRequestTimeout
            )
            try Task.checkCancellation()
            if case .failed(let error) = markdownResult {
                AppLog.network.warning("RAG README Markdown fetch failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        case .notFound:
            break
        case .failed(let error):
            AppLog.network.warning("RAG README HTML fetch failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func embedPendingChunks(recordsRefreshSummary: Bool = false) async throws {
        try await chunkRepository.clearOrphanEmbeddingClaims()
        let embeddingRuntime = try? makeEmbeddingClient()
        // 文本分片一旦写入 rag_chunks 就已可被 FTS 检索。Embedding 配置缺失或失效时，
        // 将本轮作为关键词索引成功收口，不能把已经可用的本地知识误报成构建失败。
        guard let (client, model) = embeddingRuntime else {
            let total = try await chunkRepository.countChunksNeedingEmbedding()
            let coverage = try await chunkRepository.coverage(model: "")
            if recordsRefreshSummary {
                updateRefreshSummary(
                    embeddingProcessed: 0,
                    embeddingTotal: total,
                    readyChunksBeforeEmbedding: coverage.readyChunks,
                    totalChunksAtEmbedding: coverage.totalChunks
                )
            }
            try await syncKeywordBackendWithoutEmbedding()
            assignStatus(.completed(coverage))
            if recordsRefreshSummary {
                await markRefreshSummaryCompleted(at: Date())
            }
            NotificationCenter.default.post(name: .knowledgeRAGIndexDidChange, object: nil)
            return
        }

        // 确认当前 Embedding 客户端可用后，再把旧模型向量标 stale。关键词模式必须保留
        // 旧向量状态，便于用户补齐配置后继续增量处理，不能先把可恢复缓存整体标脏。
        try await chunkRepository.markStaleForOtherModels(currentModel: model)
        // 文本索引不依赖向量是否 ready。先灌 Meilisearch，向量化可以继续慢慢跑。
        try await syncKeywordBackendAheadOfEmbedding(model: model)
        var progress = try await chunkRepository.fetchVectorizationProgress(model: model)
        // Metadata-only 更新不能要求用户配置 embedding API；它只需刷新本地 FTS / 可选关键词后端。
        guard progress.readyChunks < progress.totalChunks else {
            try await syncExternalBackends(model: model)
            let coverage = try await chunkRepository.coverage(model: model)
            assignStatus(.completed(coverage))
            if recordsRefreshSummary {
                await markRefreshSummaryCompleted(at: Date())
            }
            NotificationCenter.default.post(name: .knowledgeRAGIndexDidChange, object: nil)
            return
        }

        if recordsRefreshSummary {
            // 第三行展示向量覆盖，不把 keyword_only 和本轮队列游标混进「已就绪」。
            updateRefreshSummary(
                embeddingProcessed: progress.readyChunks,
                embeddingTotal: progress.totalChunks,
                readyChunksBeforeEmbedding: 0,
                totalChunksAtEmbedding: progress.totalChunks
            )
        }
        assignStatus(.embedding(processedChunks: progress.readyChunks, totalChunks: progress.totalChunks))
        while true {
            try Task.checkCancellation()
            guard isCurrentWorkGeneration else { throw CancellationError() }
            let batch = try await chunkRepository.fetchChunksNeedingEmbedding(limit: embeddingBatchSize)
            guard !batch.isEmpty else { break }
            let claimID = UUID().uuidString
            let claimed = try await chunkRepository.claimChunksForEmbedding(
                batch.compactMap { chunk in
                    guard let id = chunk.id else { return nil }
                    return RAGEmbeddingIdentity(chunkID: id, contentHash: chunk.contentHash)
                },
                claimID: claimID
            )
            guard !claimed.isEmpty else { continue }
            do {
                let vectors = try await client.embeddings(inputs: claimed.map(\.content), model: model)
                // HTTP 返回后必须先认 generation：暂停已经把 UI 打成 idle，不能再 markReady 把进度弹回去。
                if Task.isCancelled || !isCurrentWorkGeneration {
                    try await chunkRepository.releaseEmbeddingClaim(claimID: claimID)
                    throw CancellationError()
                }
                // Provider 若少返回一条或给出空向量，不能让部分 chunk 永久停留在带 claim 的 pending。
                // 整批按失败处理，下一轮可重新领取；同时避免把错位向量写到错误正文。
                guard vectors.count == claimed.count, vectors.allSatisfy({ !$0.isEmpty }) else {
                    throw AIEmbeddingError.emptyResponse
                }
                let updates = zip(claimed, vectors).compactMap { chunk, vector -> RAGEmbeddingWrite? in
                    guard let id = chunk.id else { return nil }
                    return RAGEmbeddingWrite(
                        identity: .init(chunkID: id, contentHash: chunk.contentHash),
                        vector: vector
                    )
                }
                let readyCount = try await chunkRepository.markReady(updates, model: model, claimID: claimID)
                if readyCount == 0 {
                    // 内容已变或 claim 丢失：释放残留，本批不算成功，避免把过期向量写进外部索引。
                    try await chunkRepository.releaseEmbeddingClaim(claimID: claimID)
                    continue
                }
                if readyCount < updates.count {
                    try await chunkRepository.releaseEmbeddingClaim(claimID: claimID)
                }
                externalIndexChanges.recordUpserts(updates.map(\.identity.chunkID))
            } catch is CancellationError {
                try await chunkRepository.releaseEmbeddingClaim(claimID: claimID)
                throw CancellationError()
            } catch {
                try await chunkRepository.markFailed(
                    claimed.compactMap { chunk in
                        guard let id = chunk.id else { return nil }
                        return RAGEmbeddingIdentity(chunkID: id, contentHash: chunk.contentHash)
                    },
                    claimID: claimID,
                    error: error.localizedDescription
                )
                do {
                    try await syncExternalBackends(model: model)
                } catch {
                    AppLog.ai.error("RAG failed-batch external cleanup failed: \(error.localizedDescription, privacy: .public)")
                }
                throw error
            }
            progress = try await chunkRepository.fetchVectorizationProgress(model: model)
            assignStatus(.embedding(processedChunks: progress.readyChunks, totalChunks: progress.totalChunks))
            if recordsRefreshSummary {
                updateRefreshSummary(
                    embeddingProcessed: progress.readyChunks,
                    embeddingTotal: progress.totalChunks,
                    totalChunksAtEmbedding: progress.totalChunks
                )
            }
        }
        try await syncExternalBackends(model: model)
        let coverage = try await chunkRepository.coverage(model: model)
        assignStatus(.completed(coverage))
        if recordsRefreshSummary {
            await markRefreshSummaryCompleted(at: Date())
        }
        NotificationCenter.default.post(name: .knowledgeRAGIndexDidChange, object: nil)
    }

    /// Summary 是值类型；每次赋回属性以确保 Observation 能让两个窗口同步刷新。
    private func updateRefreshSummary(
        readmesProcessed: Int? = nil,
        sourceReposProcessed: Int? = nil,
        embeddingProcessed: Int? = nil,
        embeddingTotal: Int? = nil,
        readyChunksBeforeEmbedding: Int? = nil,
        totalChunksAtEmbedding: Int? = nil
    ) {
        guard isCurrentWorkGeneration, var summary = refreshSummary else { return }
        if let readmesProcessed { summary.readmesProcessed = readmesProcessed }
        if let sourceReposProcessed { summary.sourceReposProcessed = sourceReposProcessed }
        if let embeddingProcessed { summary.embeddingProcessed = embeddingProcessed }
        if let embeddingTotal { summary.embeddingTotal = embeddingTotal }
        if let readyChunksBeforeEmbedding { summary.readyChunksBeforeEmbedding = readyChunksBeforeEmbedding }
        if let totalChunksAtEmbedding { summary.totalChunksAtEmbedding = totalChunksAtEmbedding }
        refreshSummary = summary
    }

    private func markRefreshSummaryCompleted(at date: Date) async {
        guard isCurrentWorkGeneration, var summary = refreshSummary else { return }
        summary.completedAt = date
        refreshSummary = summary
        do {
            try await chunkRepository.saveLastIndexRefreshSummary(summary)
        } catch {
            // 索引本身已经成功；摘要写入失败只影响下次展示，不能反过来把一次成功刷新报成失败。
            AppLog.ai.warning("RAG index refresh summary persistence failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Builder 生命周期跨用户数据库切换；恢复前必须先取消旧读任务，避免旧库结果回填到新账号。
    private func restorePersistedRefreshSummary() {
        refreshSummaryRestoreTask?.cancel()
        refreshSummaryRestoreTask = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.chunkRepository.fetchLastIndexRefreshSummary()
                guard !Task.isCancelled else { return }
                self.refreshSummary = summary
            } catch {
                AppLog.ai.warning("RAG index refresh summary restore failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 自托管后端是本地 chunk 的派生副本。关键词与向量指纹分开：Meilisearch 可在
    /// embedding 前全量初始化，Qdrant 仍等当前模型 ready 向量。
    private func syncExternalBackends(model: String) async throws {
        let configuration = settings.ragBackendConfiguration
        guard configuration.keywordBackend == .meilisearch || configuration.vectorBackend == .qdrant else {
            externalIndexChanges.reset()
            lastKeywordSyncFingerprint = nil
            lastVectorSyncFingerprint = nil
            return
        }
        let fingerprint = RAGExternalIndexSyncFingerprint(
            configuration: configuration,
            embeddingModel: model
        )
        let changes = externalIndexChanges
        // 外部后端虽由用户自托管，但仍属于离开 Starcat 本地数据库的数据边界。
        // 默认只同步公开仓库；私有仓库继续使用 SQLite FTS5 + 本地向量检索。
        let repos = try await repoRepository.fetchKnowledgeRepos()
        let repoIDs = Set(repos.filter { !$0.isPrivate }.map(\.id))
        let publicRepoIDs = Array(repoIDs)
        let needKeywordFull = configuration.keywordBackend == .meilisearch
            && lastKeywordSyncFingerprint != fingerprint
        let needVectorFull = configuration.vectorBackend == .qdrant
            && lastVectorSyncFingerprint != fingerprint
        do {
            if needKeywordFull {
                try await replaceKeywordIndex(configuration: configuration, publicRepoIDs: publicRepoIDs)
                lastKeywordSyncFingerprint = fingerprint
            }
            if needVectorFull {
                try await replaceVectorIndex(
                    configuration: configuration,
                    model: model,
                    publicRepoIDs: publicRepoIDs
                )
                lastVectorSyncFingerprint = fingerprint
            }
            if !changes.isEmpty && (!needKeywordFull || !needVectorFull) {
                let currentChunks = try await chunkRepository.fetchChunks(ids: Array(changes.upsertIDs))
                let plan = RAGExternalIndexSyncPlan(
                    changes: changes,
                    currentChunks: currentChunks,
                    publicKnowledgeRepoIDs: repoIDs,
                    model: model
                )
                try await applyExternalIndexPlan(
                    plan,
                    configuration: configuration,
                    applyKeyword: !needKeywordFull,
                    applyVector: !needVectorFull
                )
            }
            externalIndexChanges.markSynced(revision: changes.revision)
        } catch {
            AppLog.ai.error("RAG external backend sync failed: \(error.localizedDescription, privacy: .public)")
            try RAGExternalBackendFallbackPolicy.handle(
                error,
                fallbackToSQLite: configuration.fallbackToSQLite
            )
        }
    }

    /// Embedding 可能要跑数万条；Meilisearch 只存文本，必须在向量化循环前完成全量关键词同步。
    private func syncKeywordBackendAheadOfEmbedding(model: String) async throws {
        let configuration = settings.ragBackendConfiguration
        guard configuration.keywordBackend == .meilisearch else { return }
        let fingerprint = RAGExternalIndexSyncFingerprint(
            configuration: configuration,
            embeddingModel: model
        )
        guard lastKeywordSyncFingerprint != fingerprint else { return }
        try await syncKeywordBackendWithoutEmbedding()
    }

    /// 没有 Embedding 时只同步外部关键词索引，绝不以空模型清空 Qdrant。
    ///
    /// 关键词分片不依赖向量状态；这里使用全量替换保证 Meilisearch 与 SQLite FTS 口径一致。
    /// 变更追踪仍保留，用户之后配置 Embedding 时可继续完成向量后端同步。
    private func syncKeywordBackendWithoutEmbedding() async throws {
        let configuration = settings.ragBackendConfiguration
        guard configuration.keywordBackend == .meilisearch else { return }

        do {
            let repos = try await repoRepository.fetchKnowledgeRepos()
            let publicRepoIDs = repos.filter { !$0.isPrivate }.map(\.id)
            try await replaceKeywordIndex(configuration: configuration, publicRepoIDs: publicRepoIDs)
            lastKeywordSyncFingerprint = RAGExternalIndexSyncFingerprint(
                configuration: configuration,
                embeddingModel: resolvedEmbeddingModel()
            )
        } catch {
            AppLog.ai.error(
                "RAG keyword-only external sync failed: \(error.localizedDescription, privacy: .public)"
            )
            try RAGExternalBackendFallbackPolicy.handle(
                error,
                fallbackToSQLite: configuration.fallbackToSQLite
            )
        }
    }

    private func replaceKeywordIndex(
        configuration: RAGBackendConfiguration,
        publicRepoIDs: [Int64]
    ) async throws {
        let chunks = try await chunkRepository.fetchKeywordSearchableChunks(repoIDs: publicRepoIDs)
        let provider = MeilisearchRAGProvider(
            configuration: configuration.meilisearch,
            apiKey: try keychain.loadAIKey(forProvider: RAGBackendConfiguration.meilisearchKeychainID),
            repository: chunkRepository
        )
        try await provider.replaceAll(chunks: chunks)
    }

    private func replaceVectorIndex(
        configuration: RAGBackendConfiguration,
        model: String,
        publicRepoIDs: [Int64]
    ) async throws {
        let chunks = try await chunkRepository.fetchReadyChunks(model: model, repoIDs: publicRepoIDs)
        let provider = QdrantRAGProvider(
            configuration: configuration.qdrant,
            apiKey: try keychain.loadAIKey(forProvider: RAGBackendConfiguration.qdrantKeychainID),
            repository: chunkRepository
        )
        try await provider.replaceAll(chunks: chunks)
    }

    private func applyExternalIndexPlan(
        _ plan: RAGExternalIndexSyncPlan,
        configuration: RAGBackendConfiguration,
        applyKeyword: Bool = true,
        applyVector: Bool = true
    ) async throws {
        if applyKeyword,
           configuration.keywordBackend == .meilisearch,
           !plan.keywordUpserts.isEmpty || !plan.keywordDeleteIDs.isEmpty {
            let provider = MeilisearchRAGProvider(
                configuration: configuration.meilisearch,
                apiKey: try keychain.loadAIKey(forProvider: RAGBackendConfiguration.meilisearchKeychainID),
                repository: chunkRepository
            )
            try await provider.applyChanges(
                upserts: plan.keywordUpserts,
                deleteIDs: plan.keywordDeleteIDs
            )
        }
        if applyVector,
           configuration.vectorBackend == .qdrant,
           !plan.vectorUpserts.isEmpty || !plan.vectorDeleteIDs.isEmpty {
            let provider = QdrantRAGProvider(
                configuration: configuration.qdrant,
                apiKey: try keychain.loadAIKey(forProvider: RAGBackendConfiguration.qdrantKeychainID),
                repository: chunkRepository
            )
            try await provider.applyChanges(
                upserts: plan.vectorUpserts,
                deleteIDs: plan.vectorDeleteIDs
            )
        }
    }

    private func makeEmbeddingClient() throws -> (any AIClientProtocol, String) {
        let selection = try settings.resolveEmbeddingSelection()
        let apiKey = try keychain.loadAIKey(forProvider: selection.profile.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || selection.profile.provider.allowsEmptyAPIKey else {
            throw AIEmbeddingError.missingAPIKey
        }
        let client = try OpenAIClient(configuration: AIClientConfiguration(
            providerID: selection.profile.id,
            provider: selection.profile.provider,
            apiKey: apiKey,
            baseURL: selection.profile.baseURL,
            chatModel: settings.aiChatTask.resolvedModelName,
            embeddingModel: selection.modelName,
            timeoutInterval: selection.parameters.timeoutSeconds,
            usageContext: AIUsageContext(feature: .knowledgeIndexing, phase: "chunk_embedding")
        ))
        return (client, selection.modelName)
    }

    private func resolvedEmbeddingModel() -> String {
        settings.aiEmbeddingTask.resolvedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isCurrentWorkGeneration: Bool {
        workGeneration == activeWorkGeneration && !Task.isCancelled
    }

    private func assignStatus(_ newStatus: RAGIndexingStatus) {
        guard isCurrentWorkGeneration else { return }
        status = newStatus
    }

    /// 所有写索引入口共用一条 Task 链。用户全量重建取消当前轮；自动增量走排队或 coalesce。
    private func withExclusiveWork(
        policy: RAGExclusiveWorkPolicy,
        operation: @escaping () async throws -> Void
    ) async throws {
        guard !isSuspendedForDatabaseChange else { throw CancellationError() }
        if policy == .replaceRunning {
            workGeneration += 1
            pendingAuto.reset()
            exclusiveLock?.cancel()
        }
        let generation = workGeneration
        let previous = exclusiveLock
        let task = Task<Void, Error> { @MainActor [weak self] in
            _ = try? await previous?.value
            guard let self else { throw CancellationError() }
            try Task.checkCancellation()
            guard self.workGeneration == generation else { throw CancellationError() }
            guard !self.isSuspendedForDatabaseChange else { throw CancellationError() }
            self.activeWorkGeneration = generation
            self.exclusiveRunning = true
            defer {
                if self.workGeneration == generation {
                    self.exclusiveRunning = false
                }
            }
            do {
                try await operation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.assignStatus(.failed(error.localizedDescription))
                throw error
            }
            guard self.workGeneration == generation, !Task.isCancelled else { throw CancellationError() }
            do {
                try await self.drainPendingAutoIfNeeded()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // 收尾增量失败不能把已经成功的用户重建改写成失败。
                AppLog.ai.error("RAG coalesced follow-up indexing failed: \(error.localizedDescription, privacy: .public)")
                self.recordDeveloperDiagnosticIfNeeded(error, operation: "rag.drainPending")
            }
        }
        exclusiveLock = task
        try await task.value
    }

    /// drain 必须走 perform*，不能再进 `withExclusiveWork`，否则会等自己结束而卡死。
    private func drainPendingAutoIfNeeded() async throws {
        while !pendingAuto.isEmpty {
            try Task.checkCancellation()
            guard isCurrentWorkGeneration else { throw CancellationError() }
            let pending = pendingAuto
            pendingAuto.reset()
            if pending.fullRebuild {
                try await performRebuildKnowledgeBase(recordsRefreshSummary: false)
                continue
            }
            for repoID in pending.libraryAddIDs {
                try Task.checkCancellation()
                guard let repo = try? await repoRepository.findById(repoID) else { continue }
                do {
                    try await performRebuildRepository(repo)
                } catch EntitlementGateError.requiresPro {
                    continue
                }
            }
            for (repoID, sources) in pending.repoSources {
                try Task.checkCancellation()
                guard let repo = try? await repoRepository.findById(repoID) else { continue }
                await performRefresh(repo: repo, sources: sources)
            }
        }
    }

    /// 所有会写 RAG 索引的公开异步入口都必须经过这里，切库屏障才能覆盖未被本类持有的调用方 Task。
    private func beginOperation() -> Bool {
        guard !isSuspendedForDatabaseChange else { return false }
        activeOperationCount += 1
        return true
    }

    private func endOperation() {
        activeOperationCount -= 1
        guard activeOperationCount == 0 else { return }
        let continuations = idleContinuations
        idleContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func waitUntilIdle() async {
        guard activeOperationCount > 0 else { return }
        await withCheckedContinuation { continuation in
            idleContinuations.append(continuation)
        }
    }

    private nonisolated static func summaryText(_ record: AISummaryRecord) -> String? {
        let insight = try? RepoAIInsightService.decodeInsight(json: record.summaryJson)
        return Self.nonBlank(insight?.summaryMarkdown) ?? Self.nonBlank(insight?.summary)
    }

    /// 索引构建层只接受有实际内容的模型名与摘要，避免把空白字符串写入索引元数据。
    private nonisolated static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Notification.Name {
    /// RAG source diff / embedding 批次结束后通知工作台刷新覆盖率。
    static let knowledgeRAGIndexDidChange = Notification.Name("StarcatKnowledgeRAGIndexDidChange")
}
