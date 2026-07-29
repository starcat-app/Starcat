//
//  RepositoryInsightsContextCoordinator.swift
//  Starcat
//
//  页面、仓库 AI 与 RAG 共用的仓库洞察 XML 生命周期协调器。
//
//  关键约束：
//  - refreshIfNeeded 才允许走现有洞察 Provider 的 SWR 网络路径。
//  - cacheOnly 只读取 Artifact / SQLite 缓存，知识库查询不能额外扇出 GitHub 请求。
//  - 相同 repo + scope + mode 的并发任务合并；账号切换后的迟到结果禁止写盘。
//

import Foundation

/// AppDependencies 持有的轻量 scope 真相源。
///
/// Coordinator 的生成 Task 可能跨越账号切换；独立对象避免初始化期间捕获未完成的
/// AppDependencies，同时让切库完成点可以原子更新 userID + revision。
@MainActor
final class RepositoryInsightsContextScopeState {
    private(set) var scope: RepositoryInsightsContextScope

    init(scope: RepositoryInsightsContextScope) {
        self.scope = scope
    }

    func update(userID: Int64?, databaseRevision: UInt64) {
        scope = RepositoryInsightsContextScope(
            userID: userID,
            databaseRevision: databaseRevision
        )
    }
}

enum RepositoryInsightsContextPreparationMode: Hashable, Sendable {
    case refreshIfNeeded
    case cacheOnly
    case forceRegenerate
}

struct RepositoryInsightsContextPreparationResult: Sendable {
    let document: RepositoryInsightsDocument
    let artifact: RepositoryInsightsContextArtifact?
}

/// RAG 只依赖 cache-only Artifact 准备能力，避免为测试或其它消费者暴露页面 / AI 的完整协议。
protocol RepositoryInsightsRAGContextProviding: Sendable {
    func prepareArtifact(
        for repo: Repo,
        mode: RepositoryInsightsContextPreparationMode
    ) async -> RepositoryInsightsContextArtifact?
}

protocol RepositoryInsightsContextCoordinating:
    RepositoryInsightsAIContextProviding,
    RepositoryInsightsDocumentProviding,
    RepositoryInsightsRAGContextProviding,
    Sendable
{
    func prepareArtifact(
        for repo: Repo,
        mode: RepositoryInsightsContextPreparationMode
    ) async -> RepositoryInsightsContextArtifact?

    func loadArtifact(for repo: Repo) async -> RepositoryInsightsContextArtifact?
    func deleteArtifact(for repo: Repo) async throws
}

actor RepositoryInsightsContextCoordinator: RepositoryInsightsContextCoordinating {
    typealias ScopeProvider =
        @MainActor @Sendable () -> RepositoryInsightsContextScope

    private struct TaskKey: Hashable, Sendable {
        let repositoryID: Int64
        let scope: RepositoryInsightsContextScope
        let mode: RepositoryInsightsContextPreparationMode
    }

    private struct InFlight {
        let id: UUID
        let task: Task<RepositoryInsightsContextPreparationResult, Never>
    }

    private let documentProvider: any RepositoryInsightsDocumentProviding
    private let storage: any RepositoryInsightsContextStoring
    private let scopeProvider: ScopeProvider
    private var inFlight: [TaskKey: InFlight] = [:]

    init(
        documentProvider: any RepositoryInsightsDocumentProviding,
        storage: any RepositoryInsightsContextStoring,
        scopeProvider: @escaping ScopeProvider
    ) {
        self.documentProvider = documentProvider
        self.storage = storage
        self.scopeProvider = scopeProvider
    }

    func context(for repo: Repo) async -> RepositoryInsightsAIContext {
        let result = await prepare(for: repo, mode: .refreshIfNeeded)
        return RepositoryInsightsAIContext(content: result.document.xml)
    }

    func document(for repo: Repo) async -> RepositoryInsightsDocument {
        await prepare(for: repo, mode: .refreshIfNeeded).document
    }

    func cachedDocument(for repo: Repo) async -> RepositoryInsightsDocument {
        await prepare(for: repo, mode: .cacheOnly).document
    }

    func prepareArtifact(
        for repo: Repo,
        mode: RepositoryInsightsContextPreparationMode
    ) async -> RepositoryInsightsContextArtifact? {
        await prepare(for: repo, mode: mode).artifact
    }

    func loadArtifact(for repo: Repo) async -> RepositoryInsightsContextArtifact? {
        let scope = await scopeProvider()
        return try? await storage.load(
            repositoryID: repo.id,
            repositoryFullName: repo.fullName,
            scope: scope
        )
    }

    func deleteArtifact(for repo: Repo) async throws {
        let scope = await scopeProvider()
        // 删除是用户的数据控制操作，不能吞掉失败后让 UI 误以为 Artifact 已移除。
        try await storage.delete(
            repositoryID: repo.id,
            repositoryFullName: repo.fullName,
            scope: scope
        )
    }

    private func prepare(
        for repo: Repo,
        mode: RepositoryInsightsContextPreparationMode
    ) async -> RepositoryInsightsContextPreparationResult {
        let initialScope = await scopeProvider()
        let key = TaskKey(repositoryID: repo.id, scope: initialScope, mode: mode)
        if let existing = inFlight[key] {
            return await existing.task.value
        }

        let id = UUID()
        let documentProvider = self.documentProvider
        let storage = self.storage
        let scopeProvider = self.scopeProvider
        let task = Task {
            if mode == .cacheOnly,
               let existing = try? await storage.load(
                   repositoryID: repo.id,
                   repositoryFullName: repo.fullName,
                   scope: initialScope
               ) {
                return RepositoryInsightsContextPreparationResult(
                    document: existing.document,
                    artifact: existing
                )
            }

            let document: RepositoryInsightsDocument
            switch mode {
            case .cacheOnly:
                document = await documentProvider.cachedDocument(for: repo)
            case .refreshIfNeeded, .forceRegenerate:
                document = await documentProvider.document(for: repo)
            }

            // Provider 可能跨越多次网络请求；写盘前必须重新读取数据库 scope。
            guard await scopeProvider() == initialScope else {
                return RepositoryInsightsContextPreparationResult(
                    document: document,
                    artifact: nil
                )
            }
            let outcome = try? await storage.store(
                document,
                scope: initialScope,
                force: mode == .forceRegenerate
            )
            let artifact: RepositoryInsightsContextArtifact?
            switch outcome {
            case .written(let value), .unchanged(let value):
                artifact = value
            case .suppressed, .none:
                artifact = nil
            }
            return RepositoryInsightsContextPreparationResult(
                document: document,
                artifact: artifact
            )
        }
        inFlight[key] = InFlight(id: id, task: task)
        let result = await task.value
        if inFlight[key]?.id == id {
            inFlight[key] = nil
        }
        return result
    }
}
