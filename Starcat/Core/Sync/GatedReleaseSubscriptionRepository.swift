//
//  GatedReleaseSubscriptionRepository.swift
//  Starcat
//
//  Pro Release 订阅数量门控包装器。
//

import Foundation

/// 给 Release 订阅仓储增加免费版数量上限。
///
/// 只在 `subscribe` 时校验：取消订阅、通知开关、轮询游标更新都不增加订阅数量，
/// 不应被 Pro 门控挡住。重新订阅已存在且仍 active 的 repo 视为 no-op，不消耗名额。
@MainActor
struct GatedReleaseSubscriptionRepository: ReleaseSubscriptionRepositoryProtocol {
    private let base: any ReleaseSubscriptionRepositoryProtocol
    private let entitlementGate: EntitlementGate

    init(base: any ReleaseSubscriptionRepositoryProtocol, entitlementGate: EntitlementGate) {
        self.base = base
        self.entitlementGate = entitlementGate
    }

    func find(repoId: Int64) async throws -> ReleaseSubscription? {
        try await base.find(repoId: repoId)
    }

    func fetchActive() async throws -> [ReleaseSubscription] {
        try await base.fetchActive()
    }

    func fetchAll() async throws -> [ReleaseSubscription] {
        try await base.fetchAll()
    }

    func subscribe(repoId: Int64, primingReleaseId: Int64?, primingTagName: String?) async throws {
        let existing = try await base.find(repoId: repoId)
        let activeCount = try await base.fetchActive().count
        try entitlementGate.validateReleaseSubscription(
            activeSubscriptionCount: activeCount,
            isAlreadySubscribed: existing?.isSubscribed == true
        )
        try await base.subscribe(
            repoId: repoId,
            primingReleaseId: primingReleaseId,
            primingTagName: primingTagName
        )
    }

    func unsubscribe(repoId: Int64) async throws {
        try await base.unsubscribe(repoId: repoId)
    }

    func setNotifyEnabled(repoId: Int64, enabled: Bool) async throws {
        try await base.setNotifyEnabled(repoId: repoId, enabled: enabled)
    }

    func updatePollCursor(repoId: Int64, latestReleaseId: Int64?, latestTagName: String?, polledAt: Date) async throws {
        try await base.updatePollCursor(
            repoId: repoId,
            latestReleaseId: latestReleaseId,
            latestTagName: latestTagName,
            polledAt: polledAt
        )
    }
}
