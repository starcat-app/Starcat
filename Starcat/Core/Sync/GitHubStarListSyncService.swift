//
//  GitHubStarListSyncService.swift
//  Starcat
//
//  GitHub Stars List 同步与用户写入操作协调层。
//
//  设计约束：
//  - GitHub 是远端真源；所有用户写操作必须先 mutation 成功，再更新本地缓存。
//  - `updateUserListsForItem` 是替换式写入，所以 add/remove/批量新增都先读取本地完整
//    membership，计算目标集合后一次提交。
//  - 本服务只处理 GitHub List，不处理 Starcat Tags / Smart Collections。
//

import Foundation
import GRDB

/// 批量更新 GitHub Stars List membership 的结果摘要。
///
/// 单条失败不会中断后续仓库；已经处于目标状态的仓库计入 skipped，避免重复 mutation。
struct GitHubStarListBatchMembershipSummary: Equatable {
    let total: Int
    let succeeded: Int
    let skipped: Int
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
        colorHex: String?,
        aiInstruction: String = "",
        autoApplyEnabled: Bool = false
    ) async throws -> GitHubStarList {
        let remote = try await apiClient.createUserList(
            name: name,
            description: description,
            isPrivate: isPrivate
        )
        try await repository.upsertList(remote, colorHex: colorHex, syncedAt: Date())
        try await saveAIRule(
            listID: remote.id,
            instruction: aiInstruction,
            autoApplyEnabled: autoApplyEnabled
        )
        return try await requireList(id: remote.id)
    }

    @discardableResult
    func updateList(
        id: String,
        name: String,
        description: String?,
        isPrivate: Bool,
        colorHex: String?,
        aiInstruction: String = "",
        autoApplyEnabled: Bool = false
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
        try await saveAIRule(
            listID: id,
            instruction: aiInstruction,
            autoApplyEnabled: autoApplyEnabled
        )
        return try await requireList(id: id)
    }

    func deleteList(id: String) async throws {
        try await apiClient.deleteUserList(id: id)
        try await repository.deleteList(id: id)
    }

    func aiRule(forList listID: String) async throws -> GitHubStarListAIRule? {
        try await repository.findAIRule(listId: listID)
    }

    func allAIRules() async throws -> [GitHubStarListAIRule] {
        try await repository.fetchAllAIRules()
    }

    /// 开始页只用分组计数，避免为概览去解码全部 membership 行。
    func repoCountsByList() async throws -> [String: Int] {
        try await repository.repoCountsByList()
    }

    func ungroupedRepoCount() async throws -> Int {
        try await repository.ungroupedRepoCount()
    }

    /// 手动/自动 AI 整理在启动时读取完整快照，避免依赖当前 Sidebar 是否已经展开。
    func allLists() async throws -> [GitHubStarList] {
        try await repository.fetchAllLists()
    }

    func allListAssignments() async throws -> [Int64: [GitHubStarList]] {
        try await repository.fetchAllListAssignments()
    }

    func allAIAutoIgnoredRepos() async throws -> [GitHubStarListAIAutoIgnoredRepo] {
        try await repository.fetchAIAutoIgnoredRepos()
    }

    func markAIAutoIgnored(
        repoID: Int64,
        reason: GitHubStarListAIAutoIgnoreReason
    ) async throws {
        try await repository.upsertAIAutoIgnoredRepo(GitHubStarListAIAutoIgnoredRepo(
            repoId: repoID,
            reason: reason,
            updatedAt: ISO8601DateFormatter.shared.string(from: Date())
        ))
    }

    func clearAIAutoIgnored(repoID: Int64) async throws {
        try await repository.deleteAIAutoIgnoredRepo(repoId: repoID)
    }

    /// 保存本地 AI 规则。这里不经过 GitHub API，避免把 Starcat 私有上下文混进远端描述。
    func saveAIRule(
        listID: String,
        instruction: String,
        autoApplyEnabled: Bool
    ) async throws {
        let normalizedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        try await repository.upsertAIRule(GitHubStarListAIRule(
            listId: listID,
            instruction: normalizedInstruction,
            // 空规则不能参与自动整理，即使旧 UI 状态仍保留了开关值也必须收敛为 false。
            autoApplyEnabled: !normalizedInstruction.isEmpty && autoApplyEnabled,
            updatedAt: ISO8601DateFormatter.shared.string(from: Date())
        ))
    }

    func addRepo(_ repo: Repo, toList listID: String) async throws {
        _ = try await addRepo(repo, toLists: [listID])
    }

    /// 把同一仓库的多个批准建议合并成至多一次 GitHub mutation。
    ///
    /// 应用前重新读取最新 membership，保证用户在 AI 审核期间手动新增的其它 Lists 不会
    /// 被替换式 mutation 覆盖。目标已经全部存在时直接 no-op，实现安全重试幂等。
    @discardableResult
    func addRepo(_ repo: Repo, toLists requestedListIDs: Set<String>) async throws -> Set<String> {
        guard !requestedListIDs.isEmpty else { return [] }
        let existingListIDs = Set(try await repository.listIds(forRepo: repo.id))
        let addedListIDs = requestedListIDs.subtracting(existingListIDs)
        guard !addedListIDs.isEmpty else { return [] }
        try await replaceRepoLists(repo, with: Array(existingListIDs.union(addedListIDs)))
        return addedListIDs
    }

    func removeRepo(_ repo: Repo, fromList listID: String) async throws {
        var listIDs = Set(try await repository.listIds(forRepo: repo.id))
        listIDs.remove(listID)
        try await replaceRepoLists(repo, with: Array(listIDs))
    }

    /// 把一个仓库的 membership 精确替换成审核页当前勾选集合。
    /// 该入口用于编辑“已应用”结果，必须允许同时新增和移除分组。
    func setLists(for repo: Repo, listIDs: Set<String>) async throws {
        try await replaceRepoLists(repo, with: Array(listIDs))
    }

    /// 为一批仓库统一设置某个分组的 membership，同时保留它们已有的其它分组。
    ///
    /// GitHub 的 mutation 是替换式写入，因此每个仓库都必须先读取完整 membership，再只修改
    /// 当前目标分组。这样批量“勾选分组”不会退化成旧的单选移动语义。
    func updateRepos(
        _ targets: [BatchStarTarget],
        membershipIn listID: String,
        shouldBelong: Bool
    ) async -> GitHubStarListBatchMembershipSummary {
        var succeeded = 0
        var skipped = 0
        var failed = 0

        for target in targets {
            do {
                var listIDs = Set(try await repository.listIds(forRepo: target.ghRepoId))
                let didChange: Bool
                if shouldBelong {
                    didChange = listIDs.insert(listID).inserted
                } else {
                    didChange = listIDs.remove(listID) != nil
                }

                guard didChange else {
                    skipped += 1
                    continue
                }

                try await replaceRepoLists(target, with: Array(listIDs))
                succeeded += 1
            } catch {
                failed += 1
                AppLog.network.error("GitHub star list batch membership update failed for \(target.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        return GitHubStarListBatchMembershipSummary(
            total: targets.count,
            succeeded: succeeded,
            skipped: skipped,
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
        // 账号切换会取消批量队列。远端 mutation 若恰好已完成，仍必须在写当前数据库前
        // 再检查一次取消，避免旧账号结果落进刚切换的新账号作用域；旧账号下次同步会回读远端。
        try Task.checkCancellation()
        try await repository.setListIds(forRepo: repo.id, listIds: sortedIDs)
    }

    private func replaceRepoLists(_ target: BatchStarTarget, with listIDs: [String]) async throws {
        let sortedIDs = Array(Set(listIDs)).sorted()
        _ = try await apiClient.updateUserListsForRepository(
            owner: target.owner,
            name: target.name,
            listIds: sortedIDs
        )
        try Task.checkCancellation()
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
