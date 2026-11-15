//
//  RepoListNoteAvailability.swift
//  Starcat
//
//  管理列表的已保存笔记状态。批量查询一次，单行只观察集合，
//  不因每张卡片出现而访问数据库，也不把编辑器未保存草稿当成笔记。
//

import Foundation
import Observation

/// 查询期间保留增删通知；整批结果回来后不能让刚清空的笔记重新出现。
@MainActor
@Observable
final class RepoListNoteAvailability {
    private(set) var repoIDs: Set<Int64> = []
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var changesDuringReload: [Int64: Bool] = [:]

    func contains(_ repoID: Int64) -> Bool { repoIDs.contains(repoID) }

    /// 与笔记编辑器一致，换行、制表符和 Unicode 空白均不构成正文。
    static func hasContent(_ content: String?) -> Bool {
        !(content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func apply(repoID: Int64, content: String?) {
        let available = Self.hasContent(content)
        changesDuringReload[repoID] = available
        if available { repoIDs.insert(repoID) } else { repoIDs.remove(repoID) }
    }

    /// 只以当前数据库完成 reopen 后的 revision 为边界，拒绝旧账号的晚到结果。
    func resetForDatabaseChange() {
        revision &+= 1
        repoIDs = []
        changesDuringReload = [:]
    }

    func reload(from repository: any RepoNoteRepositoryProtocol) async {
        await reload { try await repository.fetchRepoIdsWithNonEmptyContent() }
    }

    /// 将异步读取与状态合并分开，以便精确验证查询和实时通知的交错顺序。
    func reload(using fetch: () async throws -> Set<Int64>) async {
        revision &+= 1
        let requestedRevision = revision
        changesDuringReload = [:]
        do {
            var fetched = try await fetch()
            guard requestedRevision == revision, !Task.isCancelled else { return }
            for (repoID, available) in changesDuringReload {
                if available { fetched.insert(repoID) } else { fetched.remove(repoID) }
            }
            repoIDs = fetched
            changesDuringReload = [:]
        } catch {
            AppLog.database.warning("Repo note availability load failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
