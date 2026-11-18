//
//  AIBackgroundBillingAlerts.swift
//  Starcat
//
//  工具栏与状态面板共用的后台 AI 余额提醒。
//

import Foundation
import Observation

/// 每个账号的进程内提醒。只接收业务终态，不能用底层请求次数代替受影响任务数。
@MainActor
@Observable
final class AIBackgroundBillingAlerts {
    enum Kind: CaseIterable {
        case summary
        case tags
        case grouping
        case sharing

        var titleKey: String {
            switch self {
            case .summary: "ai.usage.feature.repo_summary"
            case .tags: "ai.usage.feature.repo_tags"
            case .grouping: "ai.usage.feature.repo_grouping"
            case .sharing: "repo.share.button.label"
            }
        }
    }

    struct Alert: Identifiable, Equatable {
        var provider: AIBillingProvider
        fileprivate(set) var reposByKind: [Kind: [Int64: String]] = [:]

        var id: String { provider.id }
        var taskCount: Int { reposByKind.values.reduce(0) { $0 + $1.count } }
        func count(for kind: Kind) -> Int { reposByKind[kind]?.count ?? 0 }
    }

    private(set) var alerts: [Alert] = []

    /// 同配置下按任务类型和仓库去重，重试同一工作不会抬高受影响数量。
    func record(_ error: any Error, kind: Kind, repo: Repo) {
        guard !Task.isCancelled, let provider = (error as? AIClientError)?.billingProvider else { return }
        if let index = alerts.firstIndex(where: { $0.id == provider.id }) {
            alerts[index].provider = provider
            alerts[index].reposByKind[kind, default: [:]][repo.id] = repo.fullName
        } else {
            alerts.append(Alert(provider: provider, reposByKind: [kind: [repo.id: repo.fullName]]))
        }
    }

    /// 同一任务完成后扣除该任务，即使用户改用了另一个服务商。
    func resolve(kind: Kind, repoID: Int64) {
        for index in alerts.indices where alerts[index].reposByKind[kind]?[repoID] != nil {
            alerts[index].reposByKind[kind]?.removeValue(forKey: repoID)
        }
        alerts.removeAll { $0.taskCount == 0 }
    }

    func dismiss(providerID: String) {
        alerts.removeAll { $0.id == providerID }
    }

    func reset() {
        alerts.removeAll()
    }
}
