//
//  WikiKnowledgeBackfillCoordinator.swift
//  Starcat
//
//  知识库 Wiki cache-first 后台补齐入口。
//
//  本类型只负责决定“哪些当前用户知识库仓库需要排队”，网络并发、repo 去重和缓存写入
//  统一由 WikiContextService 负责。账号切换时必须先 suspend，等待旧扫描与网络任务退出，
//  再切 SQLite；否则旧账号通知可能用新数据库查到同 id 的另一仓库。
//

import Foundation

@MainActor
final class WikiKnowledgeBackfillCoordinator {
    private let wikiContextService: WikiContextService
    private let fetchKnowledgeRepos: @Sendable () async throws -> [Repo]
    private let findRepo: @Sendable (Int64) async throws -> Repo?

    private var libraryObservationTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        repoRepository: any RepoRepositoryProtocol,
        wikiContextService: WikiContextService
    ) {
        self.wikiContextService = wikiContextService
        self.fetchKnowledgeRepos = { try await repoRepository.fetchKnowledgeRepos() }
        self.findRepo = { try await repoRepository.findById($0) }
    }

    /// 测试专用闭包注入，避免为调度测试实现完整 Repository protocol。
    init(
        wikiContextService: WikiContextService,
        fetchKnowledgeRepos: @escaping @Sendable () async throws -> [Repo],
        findRepo: @escaping @Sendable (Int64) async throws -> Repo?
    ) {
        self.wikiContextService = wikiContextService
        self.fetchKnowledgeRepos = fetchKnowledgeRepos
        self.findRepo = findRepo
    }

    /// 当前数据库就绪后启动监听，并以低优先级扫描一次已有知识库。
    func start() {
        guard libraryObservationTask == nil else { return }
        let activeGeneration = generation
        libraryObservationTask = Task { [weak self] in
            let stream = NotificationCenter.default.notifications(named: .repoLibraryStateDidChange)
            for await notification in stream {
                guard let self, activeGeneration == self.generation else { return }
                guard let repoID = notification.userInfo?["repoId"] as? Int64,
                      let rawState = notification.userInfo?["libraryState"] as? String,
                      rawState == LibraryState.inLibrary.rawValue,
                      let repo = try? await self.findRepo(repoID) else { continue }
                self.enqueueIfNeeded(repo)
            }
        }
        scanTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let repos = try await self.fetchKnowledgeRepos()
                guard activeGeneration == self.generation else { return }
                let publicRepos = repos.filter { !$0.isPrivate }
                let requests = publicRepos.map {
                    WikiAvailabilityRequest(id: $0.id, owner: $0.owner, repo: $0.name)
                }
                let freshRepositoryIDs = await self.wikiContextService.freshRepositoryIDs(for: requests)
                guard activeGeneration == self.generation, !Task.isCancelled else { return }
                for repo in publicRepos where !freshRepositoryIDs.contains(repo.id) {
                    try Task.checkCancellation()
                    self.wikiContextService.enqueueRefresh(
                        owner: repo.owner,
                        repo: repo.name,
                        isPrivate: false
                    )
                }
            } catch is CancellationError {
                // 切库取消是正常路径。
            } catch {
                AppLog.ai.info("Wiki backfill scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 切库屏障：先停止通知和扫描，再取消 Wiki 服务内排队/执行任务。
    func suspendForUserDatabaseChange() async {
        generation &+= 1
        let tasks = [libraryObservationTask, scanTask].compactMap { $0 }
        libraryObservationTask = nil
        scanTask = nil
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
        await wikiContextService.cancelPendingRefreshes()
    }

    func resumeAfterUserDatabaseChange() {
        start()
    }

    private func enqueueIfNeeded(_ repo: Repo) {
        // service 还会再次检查 private；这里提前过滤，避免无意义排队和日志噪音。
        guard !repo.isPrivate else { return }
        let snapshot = wikiContextService.cachedSnapshot(owner: repo.owner, repo: repo.name)
        guard snapshot?.freshness() != .fresh else { return }
        wikiContextService.enqueueRefresh(owner: repo.owner, repo: repo.name, isPrivate: false)
    }
}
