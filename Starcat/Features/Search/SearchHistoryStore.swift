//
//  SearchHistoryStore.swift
//  Starcat
//
//  全局搜索中心的提交历史。
//
//  只保存用户明确提交过的 query，不记录逐字符草稿，也不记录 AI 自动生成的 query。
//  使用 UserDefaults 而不是数据库，是因为历史是轻量 UI 偏好，不参与知识库同步。
//

import Foundation
import Observation

@MainActor
@Observable
final class SearchHistoryStore {
    private(set) var items: [String]

    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    init(
        defaults: UserDefaults = .standard,
        key: String = "search.center.history",
        limit: Int = 50
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = max(1, limit)
        self.items = Array((defaults.stringArray(forKey: key) ?? []).prefix(max(1, limit)))
    }

    /// 记录一次用户提交。大小写不敏感去重，但保留最新一次输入的原始大小写。
    func record(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        items.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        items.insert(trimmed, at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        persist()
    }

    func remove(_ query: String) {
        items.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        persist()
    }

    func clear() {
        guard !items.isEmpty else { return }
        items = []
        persist()
    }

    private func persist() {
        defaults.set(items, forKey: key)
    }
}

