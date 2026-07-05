//
//  ActivityCategoryCountService.swift
//  Starcat
//
//  Activity 分类与 Sidebar 之间共享的轻量计数状态。
//

import Foundation
import Observation

@MainActor
@Observable
final class ActivityCategoryCountService {

    private(set) var localCounts: [ActivityCategory: Int]?
    /// Undo Star 计数独立存储（不依赖 ActivityViewModel 是否已加载）。
    private var undoStarCount: Int?

    private var undoStarRepository: (any UndoStarHistoryRepositoryProtocol)?
    private var countTask: Task<Void, Never>?

    func count(for category: ActivityCategory) -> Int? {
        if category == .undoStar { return undoStarCount }
        guard let localCounts else { return nil }
        return localCounts[category] ?? 0
    }

    func applyLocalCounts(_ counts: [ActivityCategory: Int]) {
        localCounts = counts
    }

    func applyUndoStarCount(_ count: Int) {
        undoStarCount = count
    }

    func configure(undoStarRepository: any UndoStarHistoryRepositoryProtocol) {
        self.undoStarRepository = undoStarRepository
        Task { await refreshUndoStarCount() }
        countTask = Task {
            for await _ in NotificationCenter.default.notifications(named: .undoStarHistoryDidChange) {
                guard !Task.isCancelled else { break }
                await refreshUndoStarCount()
            }
        }
    }

    private func refreshUndoStarCount() async {
        guard let repo = undoStarRepository else { return }
        do {
            let records = try await repo.fetchAll(sort: .unstarredAtDesc)
            undoStarCount = records.count
        } catch { }
    }
}
