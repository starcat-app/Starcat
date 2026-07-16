//
//  RAGComposerMentionFilters.swift
//  Starcat
//
//  Composer 上下文选择面板专用的排序/筛选快照。
//  只作用于面板候选，不改主窗口 Stars 列表；随 RAGComposerDraftStore 按会话暂存。
//

import Foundation

/// 上下文面板筛选条件。不含「知识库」分组——面板本身只展示已入库仓库。
struct RAGComposerMentionFilters: Equatable, Codable, Sendable {
    var hideArchived = false
    var hideForks = false
    var status: RepoStatus?
    var star: RepoStarFilter = .all
    /// 勾选的语言；名单来源复用 `AppSettings.interestedLanguages`。
    var selectedLanguages: [String] = []
    var wikiAvailability: RepoSignalAvailabilityFilter = .unknown
    var healthAvailability: RepoSignalAvailabilityFilter = .unknown
    var openSSFAvailability: RepoSignalAvailabilityFilter = .unknown

    static let empty = RAGComposerMentionFilters()

    /// 是否相对默认态有任何收窄；用于漏斗激活态与重置按钮。
    var isActive: Bool {
        hideArchived
            || hideForks
            || status != nil
            || star != .all
            || !selectedLanguages.isEmpty
            || wikiAvailability != .unknown
            || healthAvailability != .unknown
            || openSSFAvailability != .unknown
    }

    mutating func reset() {
        self = .empty
    }
}

/// 面板默认排序：与 Manage「默认」一致（最近 star / sparkles）。
enum RAGComposerMentionSort {
    static let `default`: RepoSortOption = .starredAtDesc
}
