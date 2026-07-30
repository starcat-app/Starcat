//
//  RepoNoteAIGenerationSessionStore.swift
//  Starcat
//
//  保存详情页之间仍在运行的 AI 个人笔记会话，避免切换仓库时丢失流式生成状态。
//

import Foundation

/// 按仓库隔离 AI 笔记生成 ViewModel 的应用内会话仓库。
///
/// 这里故意只保存内存状态，不写数据库：草稿必须在用户确认后才能落入个人笔记；同时应用退出后
/// 不恢复未确认草稿，避免把临时 AI 内容误认为用户数据。共享实例的生命周期覆盖详情页切换，
/// 每个 repo 仍持有独立 ViewModel，因此多个生成任务不会互相覆盖。
@MainActor
final class RepoNoteAIGenerationSessionStore {
    static let shared = RepoNoteAIGenerationSessionStore()

    private var sessions: [Int64: RepoNoteAIGenerationViewModel] = [:]

    init() {}

    func session(for repoID: Int64) -> RepoNoteAIGenerationViewModel? {
        sessions[repoID]
    }

    func retain(_ session: RepoNoteAIGenerationViewModel, for repoID: Int64) {
        sessions[repoID] = session
    }

    func removeSession(for repoID: Int64) {
        sessions.removeValue(forKey: repoID)
    }
}
