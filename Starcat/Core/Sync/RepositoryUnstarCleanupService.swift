//
//  RepositoryUnstarCleanupService.swift
//  Starcat
//
//  GitHub 取消 Star 成功后的单仓库本地数据清理协调器。
//

import Foundation
import GRDB

/// 用户取消 Star 时选择的本地数据清理范围。
enum RepositoryUnstarCleanupScope: Equatable, Sendable {
    /// 删除 Star 私有整理与派生分析数据，但保留知识库成员关系和知识索引。
    case keepKnowledgeLibrary
    /// 在基础清理之外，同时移出知识库并删除可重建的知识来源与检索索引。
    case removeFromKnowledgeLibrary
}

/// 串联数据库、磁盘缓存与外部知识索引的清理失败。
///
/// GitHub 状态已经成功变更后才会进入本服务，因此失败信息必须明确表达“本地清理未完整完成”，
/// 不能伪装成远端取消 Star 失败。
struct RepositoryUnstarCleanupError: LocalizedError {
    let failedComponents: [String]

    var errorDescription: String? {
        String.l10n("repo.unstarData.cleanupFailed")
    }
}

/// 取消 Star 后的数据删除唯一入口。
///
/// 关键约束：
/// - 本服务不调用 GitHub；调用方必须先确认远端 `unstar` 成功。
/// - `repos` 元数据行保留为可复用缓存，重新 Star 时仍由现有 upsert 路径恢复关系。
/// - RAG 会话与回答历史不删除，只删除可重建分片；引用外键会自动置空。
/// - 整仓移出知识库时必须连 tombstone 一起清理，否则重新入库会被旧“永久删除”意图拦截。
@MainActor
final class RepositoryUnstarCleanupService {
    typealias RepoOperation = @MainActor (Repo) async throws -> Void
    typealias RepoIDOperation = @MainActor (Int64) async throws -> Void
    typealias RepoIDAsyncAction = @MainActor (Int64) async -> Void

    private let database: any DatabaseManaging
    private let cancelAISession: RepoIDAsyncAction
    private let prepareKnowledgeIndexRemoval: RepoIDOperation
    private let finishKnowledgeIndexRemoval: RepoIDAsyncAction
    private let deleteChatHistory: RepoOperation
    private let deleteRepoContext: RepoOperation
    private let deleteCodeFlow: RepoOperation
    private let deleteCodebaseMemory: RepoOperation
    private let deleteReadmeTranslations: RepoOperation
    private let deleteWikiCache: RepoOperation

    /// 洞察 Artifact 与进程内缓存的装配晚于 Star 服务；AppDependencies 完成对应依赖后补挂。
    private var deleteKnowledgeArtifacts: RepoOperation = { _ in }

    init(
        database: any DatabaseManaging,
        cancelAISession: @escaping RepoIDAsyncAction = { _ in },
        prepareKnowledgeIndexRemoval: @escaping RepoIDOperation = { _ in },
        finishKnowledgeIndexRemoval: @escaping RepoIDAsyncAction = { _ in },
        deleteChatHistory: @escaping RepoOperation = { repo in
            try DiskChatHistoryStore.shared.deleteAllForRepo(owner: repo.owner, repo: repo.name)
        },
        deleteRepoContext: @escaping RepoOperation = { repo in
            try RepoContextStorage.shared.deleteProject(owner: repo.owner, repo: repo.name)
        },
        deleteCodeFlow: @escaping RepoOperation = { repo in
            try CodeFlowStorage.shared.deleteProject(owner: repo.owner, name: repo.name)
        },
        deleteCodebaseMemory: @escaping RepoOperation = { repo in
            try CodebaseMemoryStorage.shared.deleteProject(owner: repo.owner, name: repo.name)
        },
        deleteReadmeTranslations: @escaping RepoOperation = { repo in
            try await DiskReadmeTranslationCache.shared.deleteAll(owner: repo.owner, repo: repo.name)
        },
        deleteWikiCache: @escaping RepoOperation = { repo in
            try DiskWikiCache.shared.delete(owner: repo.owner, repo: repo.name)
        }
    ) {
        self.database = database
        self.cancelAISession = cancelAISession
        self.prepareKnowledgeIndexRemoval = prepareKnowledgeIndexRemoval
        self.finishKnowledgeIndexRemoval = finishKnowledgeIndexRemoval
        self.deleteChatHistory = deleteChatHistory
        self.deleteRepoContext = deleteRepoContext
        self.deleteCodeFlow = deleteCodeFlow
        self.deleteCodebaseMemory = deleteCodebaseMemory
        self.deleteReadmeTranslations = deleteReadmeTranslations
        self.deleteWikiCache = deleteWikiCache
    }

    /// 补挂知识库专属 Artifact 清理。该闭包只在“同时从知识库移除”时执行。
    func attachKnowledgeArtifactCleanup(_ cleanup: @escaping RepoOperation) {
        deleteKnowledgeArtifacts = cleanup
    }

    /// 异步清理单仓库数据；所有可独立执行的组件都会尝试，最后统一报告失败项。
    func cleanup(repo: Repo, scope: RepositoryUnstarCleanupScope) async throws {
        await cancelAISession(repo.id)

        var failures: [String] = []

        if scope == .removeFromKnowledgeLibrary {
            if let failure = await captureFailure("知识库外部索引", operation: {
                try await prepareKnowledgeIndexRemoval(repo.id)
            }) {
                failures.append(failure)
            }
        }

        if let failure = await captureFailure("本地数据库", operation: {
            try await deleteDatabaseData(repoID: repo.id, scope: scope)
        }) {
            failures.append(failure)
        }
        if scope == .removeFromKnowledgeLibrary {
            // 外部索引删除与本地事务之间持续抑制旧事件回写；数据库已收口后再解除。
            await finishKnowledgeIndexRemoval(repo.id)
        }
        if let failure = await captureFailure("仓库问答记录", operation: {
            try await deleteChatHistory(repo)
        }) {
            failures.append(failure)
        }
        if let failure = await captureFailure("仓库分析报告", operation: {
            try await deleteRepoContext(repo)
            try await deleteCodeFlow(repo)
            try await deleteCodebaseMemory(repo)
        }) {
            failures.append(failure)
        }

        if scope == .removeFromKnowledgeLibrary {
            if let failure = await captureFailure("README 翻译缓存", operation: {
                try await deleteReadmeTranslations(repo)
            }) {
                failures.append(failure)
            }
            if let failure = await captureFailure("Wiki 缓存", operation: {
                try await deleteWikiCache(repo)
            }) {
                failures.append(failure)
            }
            if let failure = await captureFailure("仓库洞察资料", operation: {
                try await deleteKnowledgeArtifacts(repo)
            }) {
                failures.append(failure)
            }
        }

        postChangeNotifications(repoID: repo.id, scope: scope)

        guard failures.isEmpty else {
            throw RepositoryUnstarCleanupError(failedComponents: failures)
        }
    }

    /// 数据库删除集中在一个事务中，避免 UI 观察到“笔记已删但向量仍在”等中间态。
    private func deleteDatabaseData(
        repoID: Int64,
        scope: RepositoryUnstarCleanupScope
    ) async throws {
        try await database.writer.write { db in
            // Star 私有整理数据与可重建分析缓存：两种清理范围都删除。
            for table in [
                "repo_tags",
                "repo_pins",
                "repo_github_star_lists",
                "repo_github_star_list_overrides",
                "ai_organization_draft_items",
                "ai_summaries",
                "repo_embeddings",
                "repo_health_snapshots",
                "open_ssf_scores"
            ] {
                try db.execute(sql: "DELETE FROM \(table) WHERE repo_id = ?", arguments: [repoID])
            }

            let previous = try Row.fetchOne(db, sql: "SELECT status, library_state FROM repo_notes WHERE repo_id = ?",
                                            arguments: [repoID])
            let now = Date()
            if previous?["status"] as String? == RepoStatus.using.rawValue {
                try KnowledgeActivity.append(.stoppedUsing, repoID: repoID, at: now, source: .unstarCleanup, db: db)
            }
            if scope == .removeFromKnowledgeLibrary,
               previous?["library_state"] as String? == LibraryState.inLibrary.rawValue {
                try KnowledgeActivity.append(.leftLibrary, repoID: repoID, at: now, source: .unstarCleanup, db: db)
            }
            switch scope {
            case .keepKnowledgeLibrary:
                // 知识库归属独立于 Star；只保留承载归属所需的最小行。
                try db.execute(
                    sql: """
                    UPDATE repo_notes
                    SET content = NULL,
                        status = 'unread',
                        is_ai_generated = 0,
                        edited_at = NULL
                    WHERE repo_id = ? AND library_state = 'in_library'
                    """,
                    arguments: [repoID]
                )
                try db.execute(
                    sql: "DELETE FROM repo_notes WHERE repo_id = ? AND library_state != 'in_library'",
                    arguments: [repoID]
                )

            case .removeFromKnowledgeLibrary:
                try db.execute(sql: "DELETE FROM repo_notes WHERE repo_id = ?", arguments: [repoID])

                // 原始来源、派生分析和检索分片都可在重新入库时重新获取。
                for table in [
                    "readmes",
                    "readme_contents",
                    "readme_prefetch_states",
                    "releases",
                    "repo_insights_snapshots",
                    "repo_star_history_points",
                    "rag_chunks",
                    "rag_chunk_tombstones"
                ] {
                    try db.execute(sql: "DELETE FROM \(table) WHERE repo_id = ?", arguments: [repoID])
                }
                // 全库刷新摘要已经不再代表当前索引，下一次打开 Inspector 时应重新计算。
                try db.execute(sql: "DELETE FROM rag_index_refresh_summary")
            }
        }
    }

    private func captureFailure(
        _ component: String,
        operation: () async throws -> Void
    ) async -> String? {
        do {
            try await operation()
            return nil
        } catch {
            AppLog.sync.error(
                "Unstar local cleanup failed [\(component, privacy: .public)]: \(error.localizedDescription, privacy: .public)"
            )
            return component
        }
    }

    private func postChangeNotifications(repoID: Int64, scope: RepositoryUnstarCleanupScope) {
        let center = NotificationCenter.default
        let repoInfo: [String: Any] = ["repoId": repoID]
        center.post(name: .repoTagsDidChange, object: nil, userInfo: repoInfo)
        center.post(name: .repoNoteContentDidChange, object: nil, userInfo: repoInfo)
        center.post(
            name: .repoStatusDidChange,
            object: nil,
            userInfo: ["repoId": repoID, "status": RepoStatus.unread.rawValue]
        )
        center.post(name: .aiSummaryDidChange, object: nil, userInfo: repoInfo)
        center.post(name: .repoHealthSnapshotDidChange, object: nil, userInfo: repoInfo)
        center.post(name: .openSSFScoreDidChange, object: nil, userInfo: repoInfo)

        if scope == .removeFromKnowledgeLibrary {
            center.post(
                name: .repoLibraryStateDidChange,
                object: nil,
                userInfo: [
                    "repoId": repoID,
                    "libraryState": LibraryState.outsideLibrary.rawValue
                ]
            )
            center.post(name: .readmeContentDidChange, object: nil, userInfo: repoInfo)
            center.post(name: .releaseRecordsDidChange, object: nil, userInfo: repoInfo)
            center.post(name: .knowledgeRAGIndexDidChange, object: nil)
        }
    }
}
