//
//  AIUsageDashboardViewModel.swift
//  Starcat
//
//  AI 用量窗口的加载、筛选与错误状态。
//

import Foundation

@MainActor
@Observable
final class AIUsageDashboardViewModel {
    var filter = AIUsageFilter()
    private(set) var snapshot = AIUsageStatisticsSnapshot.empty
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let repository: any AIUsageRepositoryProtocol
    private var reloadGeneration = 0

    init(repository: any AIUsageRepositoryProtocol) {
        self.repository = repository
    }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await repository.statistics(
                filter: filter,
                now: Date(),
                calendar: .current,
                recentLimit: 80
            )
            guard generation == reloadGeneration else { return }
            snapshot = loaded
        } catch is CancellationError {
            return
        } catch {
            guard generation == reloadGeneration else { return }
            errorMessage = error.localizedDescription
        }
        if generation == reloadGeneration {
            isLoading = false
        }
    }

    func selectFeature(_ feature: AIUsageFeature?) async {
        filter.feature = feature
        await reload()
    }

    func selectModel(_ model: String?) async {
        filter.model = model
        await reload()
    }
}
