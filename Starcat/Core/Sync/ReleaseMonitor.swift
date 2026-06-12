//
//  ReleaseMonitor.swift
//  Starcat
//
//  Release 订阅追踪 - 检测新 Release 协调器（HOM-47）。
//
//  职责：
//  - 一次"巡检"：拉取所有激活订阅 → 对每个 repo 调 GitHub Releases API → 写库 → 找出新 Release
//  - 不直接发通知（由 ReleaseNotificationService 在 ReleasePoller 中编排）
//  - 不持有调度器引用（被 ReleasePoller / RepoReleaseStatItem 调用; v2.0 前为 RepoReleaseSection）
//
//  设计取舍：
//  - 串行而非并发：避免短时内对 GitHub 5000/h 配额造成集中冲击；订阅数预计 < 100，串行总耗时可接受
//  - 单 repo 失败不打断整体巡检：catch 后 log 继续下一个，避免 1 个仓库 404 导致全部静默
//  - "新 Release"判定：游标 lastKnownReleaseId 之后（id > cursor）的 Release 即视为新
//      原因：① GitHub release id 单调递增（即使作者 backdate published_at）
//             ② 比时间戳更鲁棒，不会被时区 / 字符串排序误伤
//

import Foundation

/// 一次"巡检"返回的新 Release 项（按 repo 分组）。
///
/// 不实现 `Equatable`：`perRepoErrors` 持有 `Error`（协议）无法等值比较，
/// 调用方目前也只读不需要 diff，因此放弃 conformance。
/// 改为 `@unchecked Sendable`（同样因为 `Error` 非 Sendable）—— 唯一持有点是 actor
/// `ReleaseMonitor` 与 `ReleasePoller`，跨 actor 传递时是只读快照，安全。
struct ReleaseMonitorReport: @unchecked Sendable {

    /// 单条 "应推送通知" 项：repo + release，UI / 通知层根据 notifyEnabled 决定是否真的推。
    struct NewReleaseItem {
        let repo: Repo
        let release: ReleaseRecord
    }

    /// 本次巡检在每个 repo 上发现的"新 Release"数（含已被通知静默的）。
    var newReleasesByRepo: [Int64: Int]

    /// 需要推送通知的项（已过滤 notifyEnabled=true）。
    var notifications: [NewReleaseItem]

    /// 巡检过程中遇到的非致命错误（按 repoId 分组），用于日志 / debug。
    var perRepoErrors: [Int64: Error]

    /// 结果总结：是否有 repo 出现新 Release（不含静默）。
    var hasNewReleases: Bool {
        !newReleasesByRepo.isEmpty
    }
}

/// Release 巡检协调器。
///
/// 线程模型：actor 隔离，所有 GitHub API + DB 操作在 actor 内串行；
/// 调用方（poller / UI）`await` 即可。
actor ReleaseMonitor {

    private let apiClient: any GitHubAPIClientProtocol
    private let subscriptionRepo: any ReleaseSubscriptionRepositoryProtocol
    private let releaseRepo: any ReleaseRepositoryProtocol
    private let repoRepo: any RepoRepositoryProtocol

    /// 单 repo 默认每页拉取条数。GitHub 限制 max 100；这里取满第一页，保证发行版聚合
    /// 详情页能拿到尽可能完整的近期历史，同时仍避免无限翻页消耗 GitHub rate limit。
    private let perPage: Int

    init(
        apiClient: any GitHubAPIClientProtocol,
        subscriptionRepo: any ReleaseSubscriptionRepositoryProtocol,
        releaseRepo: any ReleaseRepositoryProtocol,
        repoRepo: any RepoRepositoryProtocol,
        perPage: Int = 100
    ) {
        self.apiClient = apiClient
        self.subscriptionRepo = subscriptionRepo
        self.releaseRepo = releaseRepo
        self.repoRepo = repoRepo
        self.perPage = perPage
    }

    /// 主入口：跑一次完整巡检。
    /// - Returns: 报告（含每 repo 新 Release 数 + 待通知项 + 单 repo 错误）
    @discardableResult
    func runOnce() async -> ReleaseMonitorReport {
        var newCounts: [Int64: Int] = [:]
        var notifications: [ReleaseMonitorReport.NewReleaseItem] = []
        var errors: [Int64: Error] = [:]

        let subscriptions: [ReleaseSubscription]
        do {
            subscriptions = try await subscriptionRepo.fetchActive()
        } catch {
            AppLog.network.error("ReleaseMonitor: fetchActive failed: \(error.localizedDescription, privacy: .public)")
            return ReleaseMonitorReport(
                newReleasesByRepo: [:],
                notifications: [],
                perRepoErrors: [-1: error]
            )
        }

        AppLog.network.info("ReleaseMonitor: scanning \(subscriptions.count) active subscriptions")

        for subscription in subscriptions {
            do {
                let result = try await scanRepo(subscription)
                if result.newCount > 0 {
                    newCounts[subscription.repoId] = result.newCount
                    if subscription.notifyEnabled {
                        notifications.append(contentsOf: result.notifications)
                    }
                }
            } catch {
                errors[subscription.repoId] = error
                AppLog.network.error("ReleaseMonitor: repo \(subscription.repoId, privacy: .public) scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        return ReleaseMonitorReport(
            newReleasesByRepo: newCounts,
            notifications: notifications,
            perRepoErrors: errors
        )
    }

    // MARK: - 私有：单 repo 扫描

    private struct RepoScanResult {
        let newCount: Int
        let notifications: [ReleaseMonitorReport.NewReleaseItem]
    }

    private func scanRepo(_ subscription: ReleaseSubscription) async throws -> RepoScanResult {
        guard let repo = try await repoRepo.findById(subscription.repoId) else {
            // 数据已不一致（订阅指向的 repo 行被删了）—— 跳过本次，不抛错避免打断整体巡检
            return RepoScanResult(newCount: 0, notifications: [])
        }

        // 拉一页 Releases。404 = 仓库无 Release（GitHub 行为），不抛错。
        let dtos: [GitHubReleaseDTO]
        do {
            let response = try await apiClient.releases(owner: repo.owner, repo: repo.name, perPage: perPage)
            dtos = response.value
        } catch NetworkError.notFound {
            // 仓库无 Release：把游标推进到"无"语义的话，未来作者发布时会被识别为新 Release（lastKnownId 仍为 nil → 全部 > nil 是 false → 不会通知）。
            // 只更新 lastPolledAt 表明"刚轮询过"。
            try await subscriptionRepo.updatePollCursor(
                repoId: repo.id,
                latestReleaseId: subscription.lastKnownReleaseId,
                latestTagName: subscription.lastKnownTagName,
                polledAt: Date()
            )
            return RepoScanResult(newCount: 0, notifications: [])
        }

        guard !dtos.isEmpty else {
            try await subscriptionRepo.updatePollCursor(
                repoId: repo.id,
                latestReleaseId: subscription.lastKnownReleaseId,
                latestTagName: subscription.lastKnownTagName,
                polledAt: Date()
            )
            return RepoScanResult(newCount: 0, notifications: [])
        }

        // 转换 DTO → DB 行；并按 release id 升序排，方便确定"新 Release"分界。
        let nowISO = ISO8601DateFormatter.shared.string(from: Date())
        let records: [ReleaseRecord] = dtos.map { dto in
            ReleaseRecord(
                id: dto.id,
                repoId: repo.id,
                tagName: dto.tagName,
                name: dto.name,
                bodyMarkdown: dto.body,
                htmlUrl: dto.htmlUrl,
                isPrerelease: dto.prerelease,
                isDraft: dto.draft,
                publishedAt: dto.publishedAt,
                createdAtRemote: dto.createdAt,
                assetsJson: ReleaseAssetCodec.encode(dto.assets?.map(Self.dtoToAsset)),
                isRead: false,
                fetchedAt: nowISO
            )
        }

        // 找出"新 Release"——id > lastKnownReleaseId 的部分。
        // 首次轮询（cursor == nil）按"无新 Release"处理：subscribe 时已 priming 过游标。
        let cursor = subscription.lastKnownReleaseId
        let newRecords: [ReleaseRecord]
        if let cursor {
            newRecords = records.filter { $0.id > cursor }
        } else {
            // priming-only：游标空说明 subscribe 没传 priming（罕见）；先全部入库但不判定为"新"
            newRecords = []
        }

        // 写库：所有 records 都 upsert（不论新旧，更新 body / assets）；
        // is_read 默认值：新 Release → false（未读，用户能看到 badge）；
        //                 既存 Release upsert → on conflict 不动 is_read（SQL 中 DO UPDATE 没列出 is_read）
        try await releaseRepo.upsertMany(records, isReadDefault: false)

        // 推进游标：取本次拿到的最大 release id（dtos 默认 desc 排，第一条即最大）
        let latest = dtos.first
        try await subscriptionRepo.updatePollCursor(
            repoId: repo.id,
            latestReleaseId: latest?.id ?? subscription.lastKnownReleaseId,
            latestTagName: latest?.tagName ?? subscription.lastKnownTagName,
            polledAt: Date()
        )

        let notifications = newRecords.map { ReleaseMonitorReport.NewReleaseItem(repo: repo, release: $0) }
        return RepoScanResult(newCount: newRecords.count, notifications: notifications)
    }

    // MARK: - 工具

    private static func dtoToAsset(_ dto: GitHubReleaseAssetDTO) -> ReleaseAsset {
        ReleaseAsset(
            id: dto.id,
            name: dto.name,
            contentType: dto.contentType,
            size: dto.size,
            browserDownloadUrl: dto.browserDownloadUrl,
            downloadCount: dto.downloadCount,
            createdAt: dto.createdAt
        )
    }
}
