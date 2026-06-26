//
//  GitHubStarListSyncService.swift
//  Starcat
//
//  GitHub Stars List 同步与用户写入操作协调层。
//
//  设计约束：
//  - GitHub 是远端真源；所有用户写操作必须先 mutation 成功，再更新本地缓存。
//  - `updateUserListsForItem` 是替换式写入，所以 add/remove/move 都先读取本地完整
//    membership，计算目标集合后一次提交。
//  - 本服务只处理 GitHub List，不处理 Starcat Tags / Smart Collections。
//

import Foundation
import GRDB

/// 批量移动 GitHub Stars List 时的来源上下文。
///
/// UI 只知道用户当前处在哪个列表；真正的 add / move 差异放在 service 内统一判断。
enum GitHubStarListBatchSource: Equatable {
    /// 虚拟「未分组」：目标操作是直接添加到目标 list。
    case ungrouped
    /// 真实 GitHub list：目标操作是从当前 list 移除，再加入目标 list。
    case list(String)
}

/// 批量移动结束摘要。单条失败不会中断后续仓库，最终由 UI 展示一次汇总。
struct GitHubStarListBatchMoveSummary: Equatable {
    let total: Int
    let succeeded: Int
    let failed: Int
}

@MainActor
@Observable
final class GitHubStarListSyncService {

    private let apiClient: GitHubAPIClient
    private let repository: any GitHubStarListRepositoryProtocol

    private(set) var isSyncing = false
    private(set) var lastErrorMessage: String?

    init(
        apiClient: GitHubAPIClient,
        repository: any GitHubStarListRepositoryProtocol
    ) {
        self.apiClient = apiClient
        self.repository = repository
    }

    /// 从 GitHub 拉取完整 list 快照并覆盖本地缓存。
    func sync(login: String) async {
        guard !login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let snapshot = try await apiClient.starLists(login: login)
            try await repository.replaceRemoteSnapshot(
                lists: snapshot.lists,
                memberships: snapshot.memberships,
                syncedAt: Date()
            )
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            AppLog.network.error("GitHub star lists sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    func createList(
        name: String,
        description: String?,
        isPrivate: Bool,
        colorHex: String?
    ) async throws -> GitHubStarList {
        let remote = try await apiClient.createUserList(
            name: name,
            description: description,
            isPrivate: isPrivate
        )
        try await repository.upsertList(remote, colorHex: colorHex, syncedAt: Date())
        return try await requireList(id: remote.id)
    }

    @discardableResult
    func updateList(
        id: String,
        name: String,
        description: String?,
        isPrivate: Bool,
        colorHex: String?
    ) async throws -> GitHubStarList {
        let existing = try await repository.findList(id: id)
        var remote = try await apiClient.updateUserList(
            id: id,
            name: name,
            description: description,
            isPrivate: isPrivate
        )
        // GitHub mutation 返回 list 本身，但不表达它在 viewer.lists connection 里的位置；
        // 编辑本地缓存时沿用已有 position，避免某个 list 被编辑后跳到首位。
        remote.position = existing?.position ?? remote.position
        try await repository.upsertList(remote, colorHex: colorHex, syncedAt: Date())
        return try await requireList(id: id)
    }

    func deleteList(id: String) async throws {
        try await apiClient.deleteUserList(id: id)
        try await repository.deleteList(id: id)
    }

    func addRepo(_ repo: Repo, toList listID: String) async throws {
        var listIDs = Set(try await repository.listIds(forRepo: repo.id))
        listIDs.insert(listID)
        try await replaceRepoLists(repo, with: Array(listIDs))
    }

    func removeRepo(_ repo: Repo, fromList listID: String) async throws {
        var listIDs = Set(try await repository.listIds(forRepo: repo.id))
        listIDs.remove(listID)
        try await replaceRepoLists(repo, with: Array(listIDs))
    }

    func moveRepo(_ repo: Repo, from sourceListID: String, to targetListID: String) async throws {
        var listIDs = Set(try await repository.listIds(forRepo: repo.id))
        listIDs.remove(sourceListID)
        listIDs.insert(targetListID)
        try await replaceRepoLists(repo, with: Array(listIDs))
    }

    func moveRepos(
        _ targets: [BatchStarTarget],
        from source: GitHubStarListBatchSource,
        to targetListID: String
    ) async -> GitHubStarListBatchMoveSummary {
        var succeeded = 0
        var failed = 0

        for target in targets {
            do {
                var listIDs = Set(try await repository.listIds(forRepo: target.ghRepoId))
                switch source {
                case .ungrouped:
                    listIDs.insert(targetListID)
                case .list(let sourceListID):
                    listIDs.remove(sourceListID)
                    listIDs.insert(targetListID)
                }
                try await replaceRepoLists(target, with: Array(listIDs))
                succeeded += 1
            } catch {
                failed += 1
                AppLog.network.error("GitHub star list batch move failed for \(target.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return GitHubStarListBatchMoveSummary(
            total: targets.count,
            succeeded: succeeded,
            failed: failed
        )
    }

    private func replaceRepoLists(_ repo: Repo, with listIDs: [String]) async throws {
        let sortedIDs = Array(Set(listIDs)).sorted()
        _ = try await apiClient.updateUserListsForRepository(
            owner: repo.owner,
            name: repo.name,
            listIds: sortedIDs
        )
        try await repository.setListIds(forRepo: repo.id, listIds: sortedIDs)
    }

    private func replaceRepoLists(_ target: BatchStarTarget, with listIDs: [String]) async throws {
        let sortedIDs = Array(Set(listIDs)).sorted()
        _ = try await apiClient.updateUserListsForRepository(
            owner: target.owner,
            name: target.name,
            listIds: sortedIDs
        )
        try await repository.setListIds(forRepo: target.ghRepoId, listIds: sortedIDs)
    }

    private func requireList(id: String) async throws -> GitHubStarList {
        if let list = try await repository.findList(id: id) {
            return list
        }
        throw DatabaseError.openFailed(underlying: NSError(
            domain: "GitHubStarListSyncService",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "GitHub star list not found after local write: \(id)"]
        ))
    }
}
