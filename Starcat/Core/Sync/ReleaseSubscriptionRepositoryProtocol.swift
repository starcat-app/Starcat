//
//  ReleaseSubscriptionRepositoryProtocol.swift
//  Starcat
//
//  Release 订阅 Repository 协议（HOM-47）。
//
//  设计约束：
//  - 一个 repo 至多一条订阅记录（repo_id 主键）
//  - subscribe / unsubscribe 是显式操作；取消订阅时**不删行**只置 isSubscribed=false，
//    便于二次订阅恢复 lastKnownReleaseId 游标，不会重新推送一遍历史 Release
//  - 后台轮询通过 fetchActive() 一次拉所有"激活订阅"，避免 N+1
//

import Foundation

protocol ReleaseSubscriptionRepositoryProtocol: Sendable {

    // MARK: - 查询

    /// 找该 repo 的订阅记录；从未订阅返回 nil。
    func find(repoId: Int64) async throws -> ReleaseSubscription?

    /// 拉取所有当前激活（is_subscribed=1）的订阅记录。
    /// 后台轮询用：一次拉全 → 逐个查 GitHub Release → 更新游标。
    func fetchActive() async throws -> [ReleaseSubscription]

    /// 拉取所有订阅记录（含已取消订阅），用于时间线视图聚合 repo 信息。
    func fetchAll() async throws -> [ReleaseSubscription]

    // MARK: - 写入

    /// 订阅。如已存在记录（isSubscribed=false），将其翻为 true 并更新 modifiedAt。
    /// - Parameter primingReleaseId: 首次订阅时立即把 lastKnownReleaseId 写成"当前最新"，
    ///   避免触发"补发历史 Release 通知"。
    func subscribe(repoId: Int64, primingReleaseId: Int64?, primingTagName: String?) async throws

    /// 取消订阅（is_subscribed=0），保留行 + 游标。
    func unsubscribe(repoId: Int64) async throws

    /// 仅切换 notify_enabled。订阅记录不存在时为 no-op（防御性）。
    func setNotifyEnabled(repoId: Int64, enabled: Bool) async throws

    /// 更新轮询游标（lastKnownReleaseId / lastKnownTagName / lastPolledAt）。
    func updatePollCursor(repoId: Int64, latestReleaseId: Int64?, latestTagName: String?, polledAt: Date) async throws
}
