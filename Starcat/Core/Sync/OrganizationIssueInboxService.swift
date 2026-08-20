//
//  OrganizationIssueInboxService.swift
//  Starcat
//
//  组织 Issue 的本地增量同步器。名字保留旧文件路径，职责已从会话级独立 Inbox
//  收口为通知时间线的数据源，不持有 UI 状态。
//

import Foundation

/// 把当前用户已授权组织的 Issue 分页写入统一时间线缓存。
///
/// 关键约束：
/// - 每个组织、每份凭据分别保存分页游标，单路失败不能清空另一份成功缓存。
/// - 回填期间先刷新第一页，再继续持久化的历史页，避免长回填漏掉新 Issue。
/// - 每轮最多消费有限页数；UI 永远读 SQLite，本地分页不等待 GitHub 远端分页。
@MainActor
final class OrganizationIssueTimelineSyncService {

    private let primaryClient: any GitHubAPIClientProtocol
    private let projectClient: (any GitHubAPIClientProtocol)?
    private let repoRepository: any RepoRepositoryProtocol
    private let timelineRepository: any GitHubNotificationThreadRepositoryProtocol
    private let isProjectAccessAvailable: () -> Bool
    private let clock: () -> Date
    private let perPage: Int
    private let maxHistoryPagesPerRun: Int
    private let minimumRefreshInterval: TimeInterval

    init(
        primaryClient: any GitHubAPIClientProtocol,
        projectClient: (any GitHubAPIClientProtocol)? = nil,
        repoRepository: any RepoRepositoryProtocol,
        timelineRepository: any GitHubNotificationThreadRepositoryProtocol,
        isProjectAccessAvailable: @escaping () -> Bool = { false },
        clock: @escaping () -> Date = Date.init,
        perPage: Int = 100,
        maxHistoryPagesPerRun: Int = 3,
        minimumRefreshInterval: TimeInterval = 15 * 60
    ) {
        self.primaryClient = primaryClient
        self.projectClient = projectClient
        self.repoRepository = repoRepository
        self.timelineRepository = timelineRepository
        self.isProjectAccessAvailable = isProjectAccessAvailable
        self.clock = clock
        self.perPage = min(max(perPage, 1), 100)
        self.maxHistoryPagesPerRun = max(1, maxHistoryPagesPerRun)
        self.minimumRefreshInterval = max(0, minimumRefreshInterval)
    }

    /// 同步当前账号的全部组织。失败只记录到对应 scope，不删除已有时间线。
    func sync(userID: Int64, force: Bool = false) async {
        let organizations: [String]
        do {
            organizations = try await repoRepository
                .fetchProjectFilterOptions(userID: userID)
                .organizationLogins
        } catch {
            AppLog.network.warning(
                "Organization timeline scopes unavailable: \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        for organization in organizations {
            for (source, client) in activeClients() {
                do {
                    try await syncScope(
                        organization: organization,
                        source: source,
                        client: client,
                        force: force
                    )
                } catch is CancellationError {
                    return
                } catch {
                    await persistFailure(
                        organization: organization,
                        source: source,
                        error: error
                    )
                }
            }
        }
    }

    private func syncScope(
        organization: String,
        source: GitHubTimelineCredentialSource,
        client: any GitHubAPIClientProtocol,
        force: Bool
    ) async throws {
        let state = try await timelineRepository.organizationIssueSyncState(
            organization: organization,
            credentialSource: source
        )
        if !force,
           let raw = state?.lastFetchedAt,
           let lastFetched = ISO8601DateFormatter.githubDate(from: raw),
           clock().timeIntervalSince(lastFetched) < minimumRefreshInterval {
            return
        }

        let fetchedAt = ISO8601DateFormatter.shared.string(from: clock())
        var watermark = state?.watermarkUpdatedAt
        var nextHistoryPage = state?.nextPage
        var completedAt = state?.backfillCompletedAt

        // 历史回填跨多轮时仍先刷第一页，保证用户刚关联的新 Issue 立即可见。
        if let savedPage = nextHistoryPage, savedPage > 1 {
            let first = try await fetchAndPersist(
                organization: organization,
                source: source,
                client: client,
                page: 1,
                fetchedAt: fetchedAt
            )
            watermark = Self.newerWatermark(current: watermark, issues: first.value)
        }

        var page = nextHistoryPage ?? 1
        var pagesFetched = 0
        while pagesFetched < maxHistoryPagesPerRun {
            try Task.checkCancellation()
            let response = try await fetchAndPersist(
                organization: organization,
                source: source,
                client: client,
                page: page,
                fetchedAt: fetchedAt
            )
            pagesFetched += 1
            watermark = Self.newerWatermark(current: watermark, issues: response.value)

            guard let next = response.linkHeader.nextPage else {
                nextHistoryPage = nil
                completedAt = completedAt ?? fetchedAt
                break
            }

            // 历史已完成后，增量轮遇到旧水位就停，不每 15 分钟重扫完整历史。
            if completedAt != nil,
               let oldWatermark = state?.watermarkUpdatedAt,
               response.value.contains(where: { Self.timestamp($0) <= oldWatermark }) {
                nextHistoryPage = nil
                break
            }
            nextHistoryPage = next
            page = next
        }

        try await timelineRepository.updateOrganizationIssueSyncState(
            organization: organization,
            credentialSource: source,
            nextPage: nextHistoryPage,
            watermarkUpdatedAt: watermark,
            backfillCompletedAt: completedAt,
            lastFetchedAt: fetchedAt,
            lastError: nil
        )
    }

    private func fetchAndPersist(
        organization: String,
        source: GitHubTimelineCredentialSource,
        client: any GitHubAPIClientProtocol,
        page: Int,
        fetchedAt: String
    ) async throws -> APIResponse<[GitHubOrganizationIssue]> {
        let response = try await client.organizationIssues(
            organization: organization,
            state: .all,
            page: page,
            perPage: perPage
        )
        try await timelineRepository.upsertOrganizationIssues(
            response.value,
            credentialSource: source,
            fetchedAt: fetchedAt
        )
        return response
    }

    private func activeClients() -> [(GitHubTimelineCredentialSource, any GitHubAPIClientProtocol)] {
        var result: [(GitHubTimelineCredentialSource, any GitHubAPIClientProtocol)] = [
            (.primaryOAuth, primaryClient)
        ]
        if isProjectAccessAvailable(), let projectClient {
            result.append((.projectAccess, projectClient))
        }
        return result
    }

    private func persistFailure(
        organization: String,
        source: GitHubTimelineCredentialSource,
        error: Error
    ) async {
        let previous = try? await timelineRepository.organizationIssueSyncState(
            organization: organization,
            credentialSource: source
        )
        try? await timelineRepository.updateOrganizationIssueSyncState(
            organization: organization,
            credentialSource: source,
            nextPage: previous?.nextPage,
            watermarkUpdatedAt: previous?.watermarkUpdatedAt,
            backfillCompletedAt: previous?.backfillCompletedAt,
            lastFetchedAt: previous?.lastFetchedAt,
            lastError: error.localizedDescription
        )
        AppLog.network.warning(
            "Organization timeline sync failed: org=\(organization, privacy: .public) source=\(source.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
    }

    nonisolated private static func newerWatermark(
        current: String?,
        issues: [GitHubOrganizationIssue]
    ) -> String? {
        issues.map(timestamp).reduce(current) { partial, candidate in
            guard let partial else { return candidate }
            return max(partial, candidate)
        }
    }

    nonisolated private static func timestamp(_ issue: GitHubOrganizationIssue) -> String {
        ISO8601DateFormatter.shared.string(from: issue.updatedAt ?? issue.createdAt ?? .distantPast)
    }
}
