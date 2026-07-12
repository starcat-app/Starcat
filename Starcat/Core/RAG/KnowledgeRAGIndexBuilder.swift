//
//  KnowledgeRAGIndexBuilder.swift
//  Starcat
//
//  知识库范围的 source 级增量索引器。
//
//  索引器只读取 `fetchKnowledgeRepos()` 或显式确认仍为 `.inLibrary` 的 repo。全量构建会先补齐
//  缺失的 README Markdown，再分别 replace README、notes、summary、metadata；embedding 统一批量
//  失败时只标记当前 batch，不删除已经 ready 的其它 chunks。
//

import Foundation
import Observation

enum RAGIndexingStatus: Equatable, Sendable {
    case idle
    case fetchingReadmes(processedRepos: Int, totalRepos: Int)
    case building(processedRepos: Int, totalRepos: Int)
    case embedding(processedChunks: Int, totalChunks: Int)
    case completed(RAGIndexCoverage)
    case failed(String)
}

/// 用户手动刷新时展示的阶段汇总。阶段切换后仍保留已完成阶段的数据，避免快速刷新让用户错过过程。
struct RAGIndexRefreshSummary: Equatable, Sendable {
    let totalRepos: Int
    var readmesProcessed: Int
    var chunksProcessed: Int
    var completedAt: Date?
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
    private let settings: AppSettings
    private let entitlementGate: EntitlementGate
    private let keychain: any KeychainManaging
    private let builder: RAGChunkBuilder
    private let embeddingBatchSize: Int

    /// README HTML 与 Markdown 各自独立请求；限制单次请求，避免离线网络阻塞整轮索引。
    private static let readmeRequestTimeout: TimeInterval = 15

    private(set) var status: RAGIndexingStatus = .idle
    /// 仅由显式的全量/仓库刷新创建；自动 source 更新不能覆盖用户刚完成的刷新结果。
    private(set) var refreshSummary: RAGIndexRefreshSummary?
    private var indexingTask: Task<Void, Never>?
    private var observationTasks: [Task<Void, Never>] = []
    private var debouncedSourceTasks: [Int64: Task<Void, Never>] = [:]
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
        self.settings = settings
        self.entitlementGate = entitlementGate
        self.keychain = keychain
        self.builder = builder
        self.embeddingBatchSize = embeddingBatchSize
    }

    func startRebuild() {
        guard !isSuspendedForDatabaseChange else { return }
        indexingTask?.cancel()
        indexingTask = Task { [weak self] in
            guard let self else { return }
            do {
                // source 监听触发的后台补建不能改写用户在工作台看到的最后一次手动刷新结果。
                try await self.rebuildKnowledgeBase(recordsRefreshSummary: false)
            } catch is CancellationError {
                self.status = .idle
            } catch {
                self.status = .failed(error.localizedDescription)
                NotificationCenter.default.post(name: .knowledgeRAGIndexDidChange, object: nil)
            }
        }
    }

    func cancel() {
        indexingTask?.cancel()
        indexingTask = nil
        status = .idle
    }

    /// 多账号切库前建立写入屏障。仅取消已知 Task 不够：Stars 同步回调可能正在执行 metadata
    /// 刷新，因此还要等待所有已进入索引临界区的操作退出，避免旧账号任务在新 DB 上续写。
    func suspendForUserDatabaseChange() async {
        isSuspendedForDatabaseChange = true
        let tasks = [indexingTask].compactMap { $0 }
            + observationTasks
            + Array(debouncedSourceTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        indexingTask = nil
        observationTasks.removeAll()
        debouncedSourceTasks.removeAll()
        await waitUntilIdle()
        status = .idle
    }

    /// 数据库切换无论成功还是失败都恢复 source 监听；失败时仍然服务原数据库。
    func resumeAfterUserDatabaseChange() {
        isSuspendedForDatabaseChange = false
        startObservingSourceChanges()
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
                    self?.startRebuild()
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
                await self?.refresh(repoID: repoID, sources: [.metadata])
            }
        })
        observationTasks.append(Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .repoLibraryStateDidChange)
            for await notification in stream {
                guard let repoID = notification.userInfo?["repoId"] as? Int64,
                      let raw = notification.userInfo?["libraryState"] as? String,
                      LibraryState.parse(raw) == .inLibrary else { continue }
                await self?.refresh(repoID: repoID, sources: Set(RAGChunkSource.allCases))
            }
        })
    }

    /// 全量重建只表示“重新计算 source diff + 补齐待处理 embedding”，内容未变的 ready chunk
    /// 仍复用原向量。真正强制换向量由 embedding model 变化触发 stale。
    func rebuildKnowledgeBase(recordsRefreshSummary: Bool = true) async throws {
        guard beginOperation() else { throw CancellationError() }
        defer { endOperation() }
        try entitlementGate.requirePro(.knowledgeRAG)
        let repos = try await repoRepository.fetchKnowledgeRepos()
        if recordsRefreshSummary {
            refreshSummary = RAGIndexRefreshSummary(
                totalRepos: repos.count,
                readmesProcessed: 0,
                chunksProcessed: 0,
                completedAt: nil
            )
        }
        let summaries = try await summaryRepository.fetchLatestPerRepo()
        try await fetchMissingReadmes(for: repos, recordsRefreshSummary: recordsRefreshSummary)
        for (index, repo) in repos.enumerated() {
            try Task.checkCancellation()
            status = .building(processedRepos: index, totalRepos: repos.count)
            try await rebuildSources(for: repo, summary: summaries[repo.id], sources: Set(RAGChunkSource.allCases))
            if recordsRefreshSummary {
                updateRefreshSummary(chunksProcessed: index + 1)
            }
        }
        status = .building(processedRepos: repos.count, totalRepos: repos.count)
        if recordsRefreshSummary {
            updateRefreshSummary(chunksProcessed: repos.count)
        }
        try await embedPendingChunks(recordsRefreshSummary: recordsRefreshSummary)
    }

    /// 知识库浏览器的刷新只重建当前选中的仓库，避免用户以为是局部操作却触发全库网络请求。
    func rebuildRepository(_ repo: Repo) async throws {
        guard beginOperation() else { throw CancellationError() }
        defer { endOperation() }
        try entitlementGate.requirePro(.knowledgeRAG)
        guard try await noteRepository.fetchLibraryState(repoId: repo.id) == .inLibrary else { return }

        refreshSummary = RAGIndexRefreshSummary(
            totalRepos: 1,
            readmesProcessed: 0,
            chunksProcessed: 0,
            completedAt: nil
        )
        let summaries = try await summaryRepository.fetchLatestPerRepo()
        try await fetchMissingReadmes(for: [repo], recordsRefreshSummary: true)
        status = .building(processedRepos: 0, totalRepos: 1)
        try await rebuildSources(for: repo, summary: summaries[repo.id], sources: Set(RAGChunkSource.allCases))
        status = .building(processedRepos: 1, totalRepos: 1)
        updateRefreshSummary(chunksProcessed: 1)
        try await embedPendingChunks(recordsRefreshSummary: true)
    }

    /// 单 source 更新入口。调用方在 README / notes / summary / metadata 变化后使用；移出知识库
    /// 时直接跳过并保留缓存，由 Retriever 的 SQL join 保证不再召回。
    func refresh(repo: Repo, sources: Set<RAGChunkSource>) async {
        guard beginOperation() else { return }
        defer { endOperation() }
        do {
            try entitlementGate.requirePro(.knowledgeRAG)
            guard try await noteRepository.fetchLibraryState(repoId: repo.id) == .inLibrary else { return }
            let summary = try await summaryRepository.fetchLatestPerRepo()[repo.id]
            try await rebuildSources(for: repo, summary: summary, sources: sources)
            try await embedPendingChunks()
        } catch EntitlementGateError.requiresPro {
            return
        } catch {
            AppLog.ai.error("RAG source refresh failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NotificationCenter.default.post(name: .knowledgeRAGIndexDidChange, object: nil)
        }
    }

    func coverage() async throws -> RAGIndexCoverage {
        try await chunkRepository.coverage(model: resolvedEmbeddingModel())
    }

    /// GitHub stars 同步完成后批量刷新 metadata source，再统一补 embedding。
    /// 数值字段已在 RAGChunkBuilder 中 bucket 化，未跨 bucket 的变化会复用原向量。
    func refreshMetadataForKnowledgeRepos() async {
        guard beginOperation() else { return }
        defer { endOperation() }
        do {
            try entitlementGate.requirePro(.knowledgeRAG)
            let repos = try await repoRepository.fetchKnowledgeRepos()
            for repo in repos {
                try Task.checkCancellation()
                try await rebuildSources(for: repo, summary: nil, sources: [.metadata])
            }
            try await embedPendingChunks()
        } catch EntitlementGateError.requiresPro {
            return
        } catch {
            AppLog.ai.error("RAG metadata refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleDebouncedRefresh(repoID: Int64, sources: Set<RAGChunkSource>) {
        guard !isSuspendedForDatabaseChange else { return }
        debouncedSourceTasks[repoID]?.cancel()
        debouncedSourceTasks[repoID] = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.5))
                await self?.refresh(repoID: repoID, sources: sources)
            } catch {
                // 新编辑会取消旧 debounce；取消不是索引错误。
            }
        }
    }

    private func refresh(repoID: Int64, sources: Set<RAGChunkSource>) async {
        guard let repo = try? await repoRepository.findById(repoID) else { return }
        await refresh(repo: repo, sources: sources)
    }

    private func rebuildSources(
        for repo: Repo,
        summary: AISummaryRecord?,
        sources: Set<RAGChunkSource>
    ) async throws {
        let note = try await noteRepository.find(repoId: repo.id)
        let tags = try await repoTagRepository.fetchTags(forRepo: repo.id).map(\.name)
        let readme = sources.contains(.readme) ? try await readmeRepository.findContent(repoId: repo.id) : nil
        let summaryText = summary.flatMap(Self.summaryText)
        let output = builder.build(RAGChunkBuildInput(
            repo: repo,
            readme: readme,
            note: note,
            summaryText: summaryText,
            summarySourceID: summary?.model ?? "",
            tags: tags
        ))

        if sources.contains(.readme) {
            _ = try await chunkRepository.replaceSource(repoId: repo.id, source: .readme, drafts: output.readme)
        }
        if sources.contains(.notes) {
            _ = try await chunkRepository.replaceSource(repoId: repo.id, source: .notes, drafts: output.notes)
        }
        if sources.contains(.summary) {
            _ = try await chunkRepository.replaceSource(repoId: repo.id, source: .summary, drafts: output.summary)
        }
        if sources.contains(.metadata) {
            _ = try await chunkRepository.replaceSource(repoId: repo.id, source: .metadata, drafts: output.metadata)
        }
    }

    /// 仅补齐本地没有 Markdown 的 README。索引器不能假设详情页或后台预拉已经访问过仓库，
    /// 否则知识库会退化成只有 metadata 的分片；单仓库失败则保留 metadata 并继续下一项。
    private func fetchMissingReadmes(for repos: [Repo], recordsRefreshSummary: Bool) async throws {
        for (index, repo) in repos.enumerated() {
            try Task.checkCancellation()
            status = .fetchingReadmes(processedRepos: index, totalRepos: repos.count)

            if let cachedMarkdown = try await readmeRepository.findContent(repoId: repo.id),
               !cachedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if recordsRefreshSummary {
                    updateRefreshSummary(readmesProcessed: index + 1)
                }
                continue
            }

            let htmlResult = await readmeAPI.refreshReadme(
                for: repo,
                requestTimeout: Self.readmeRequestTimeout
            )
            switch htmlResult {
            case .updated, .notModified:
                let markdownResult = await readmeAPI.refreshMarkdownIfNeeded(
                    for: repo,
                    requestTimeout: Self.readmeRequestTimeout
                )
                if case .failed(let error) = markdownResult {
                    AppLog.network.warning("RAG README Markdown fetch failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            case .notFound:
                break
            case .failed(let error):
                AppLog.network.warning("RAG README HTML fetch failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            if recordsRefreshSummary {
                updateRefreshSummary(readmesProcessed: index + 1)
            }
        }
        status = .fetchingReadmes(processedRepos: repos.count, totalRepos: repos.count)
        if recordsRefreshSummary {
            updateRefreshSummary(readmesProcessed: repos.count)
        }
    }

    private func embedPendingChunks(recordsRefreshSummary: Bool = false) async throws {
        let (client, model) = try makeEmbeddingClient()
        try await chunkRepository.markStaleForOtherModels(currentModel: model)

        var processed = 0
        var pending = try await chunkRepository.fetchChunksNeedingEmbedding(limit: Int.max)
        let total = pending.count
        while !pending.isEmpty {
            try Task.checkCancellation()
            let batch = Array(pending.prefix(embeddingBatchSize))
            status = .embedding(processedChunks: processed, totalChunks: total)
            do {
                let vectors = try await client.embeddings(inputs: batch.map(\.content), model: model)
                let pairs: [(Int64, [Float])] = zip(batch, vectors).compactMap { chunk, vector in
                    guard let id = chunk.id, !vector.isEmpty else { return nil }
                    return (id, vector)
                }
                let updates = Dictionary(uniqueKeysWithValues: pairs)
                try await chunkRepository.markReady(updates, model: model)
            } catch {
                try await chunkRepository.markFailed(
                    chunkIDs: batch.compactMap(\.id),
                    error: error.localizedDescription
                )
                throw error
            }
            processed += batch.count
            pending.removeFirst(batch.count)
        }
        try await syncExternalBackends(model: model)
        let coverage = try await chunkRepository.coverage(model: model)
        status = .completed(coverage)
        if recordsRefreshSummary {
            markRefreshSummaryCompleted(at: Date())
        }
        NotificationCenter.default.post(name: .knowledgeRAGIndexDidChange, object: nil)
    }

    /// Summary 是值类型；每次赋回属性以确保 Observation 能让两个窗口同步刷新。
    private func updateRefreshSummary(readmesProcessed: Int? = nil, chunksProcessed: Int? = nil) {
        guard var summary = refreshSummary else { return }
        if let readmesProcessed { summary.readmesProcessed = readmesProcessed }
        if let chunksProcessed { summary.chunksProcessed = chunksProcessed }
        refreshSummary = summary
    }

    private func markRefreshSummaryCompleted(at date: Date) {
        guard var summary = refreshSummary else { return }
        summary.completedAt = date
        refreshSummary = summary
    }

    /// 自托管后端是本地 chunk 的派生副本。每次本地 pending batch 完成后完整 replace，
    /// 优先保证删除和 source 变化的一致性；后续规模超过本地知识库量级再改增量 upsert。
    private func syncExternalBackends(model: String) async throws {
        let configuration = settings.ragBackendConfiguration
        guard configuration.keywordBackend == .meilisearch || configuration.vectorBackend == .qdrant else { return }
        // 外部后端虽由用户自托管，但仍属于离开 Starcat 本地数据库的数据边界。
        // 默认只同步公开仓库；私有仓库继续使用 SQLite FTS5 + 本地向量检索。
        let repos = try await repoRepository.fetchKnowledgeRepos()
        let repoIDs = repos.filter { !$0.isPrivate }.map(\.id)
        let chunks = try await chunkRepository.fetchReadyChunks(model: model, repoIDs: repoIDs)
        do {
            if configuration.keywordBackend == .meilisearch {
                let provider = MeilisearchRAGProvider(
                    configuration: configuration.meilisearch,
                    apiKey: try keychain.loadAIKey(forProvider: RAGBackendConfiguration.meilisearchKeychainID),
                    repository: chunkRepository
                )
                try await provider.replaceAll(chunks: chunks)
            }
            if configuration.vectorBackend == .qdrant {
                let provider = QdrantRAGProvider(
                    configuration: configuration.qdrant,
                    apiKey: try keychain.loadAIKey(forProvider: RAGBackendConfiguration.qdrantKeychainID),
                    repository: chunkRepository
                )
                try await provider.replaceAll(chunks: chunks)
            }
        } catch {
            AppLog.ai.error("RAG external backend sync failed: \(error.localizedDescription, privacy: .public)")
            if !configuration.fallbackToSQLite { throw error }
        }
    }

    private func makeEmbeddingClient() throws -> (any AIClientProtocol, String) {
        let task = settings.aiEmbeddingTask
        guard let profile = settings.aiProviderProfiles.first(where: { $0.id == task.providerID }) else {
            throw SemanticSearchError.missingAPIKey
        }
        let apiKey = try keychain.loadAIKey(forProvider: profile.id)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty || profile.provider.allowsEmptyAPIKey else {
            throw SemanticSearchError.missingAPIKey
        }
        let model = Self.nonBlank(task.resolvedModelName) ?? settings.aiEmbeddingModel
        let client = try OpenAIClient(configuration: AIClientConfiguration(
            providerID: profile.id,
            provider: profile.provider,
            apiKey: apiKey,
            baseURL: profile.baseURL,
            chatModel: settings.aiChatTask.resolvedModelName,
            embeddingModel: model,
            timeoutInterval: settings.effectiveParameters(for: task).timeoutSeconds
        ))
        return (client, model)
    }

    private func resolvedEmbeddingModel() -> String {
        Self.nonBlank(settings.aiEmbeddingTask.resolvedModelName) ?? settings.aiEmbeddingModel
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
