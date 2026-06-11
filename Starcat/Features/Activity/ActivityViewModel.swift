//
//  ActivityViewModel.swift
//  Starcat
//
//  Activity 页本地聚合 ViewModel。
//
//  第一版只组合 Starcat 已有缓存：
//  - Release：复用 HOM-47 `ReleaseRepository.fetchTimeline`
//  - Star / Repository / Suggestion：复用 `RepoRepository.fetchAllStarred`
//  - Announcement：App 内置公告
//
//  不在这里直接接 GitHub Events API，原因是 Events 有延迟且 payload 差异很大；
//  后续应作为独立 source 写入 activity 缓存，而不是塞进首版本地聚合逻辑。
//

import Foundation
import Observation

@MainActor
@Observable
final class ActivityViewModel {

    private(set) var items: [ActivityItem] = []
    private(set) var isLoading: Bool = false
    private(set) var isRefreshing: Bool = false
    private(set) var loadError: String?
    private(set) var lastRefreshedAt: Date?
    private(set) var itemsRevision: Int = 0

    private let repoRepository: any RepoRepositoryProtocol
    private let releaseRepository: any ReleaseRepositoryProtocol
    private let releasePoller: ReleasePoller

    init(
        repoRepository: any RepoRepositoryProtocol,
        releaseRepository: any ReleaseRepositoryProtocol,
        releasePoller: ReleasePoller
    ) {
        self.repoRepository = repoRepository
        self.releaseRepository = releaseRepository
        self.releasePoller = releasePoller
    }

    /// 加载当前分类。默认只读本地缓存，保持进入页面快速稳定。
    func load(category: ActivityCategory) async {
        await reload(category: category, shouldPollReleases: false)
    }

    /// 用户主动刷新：先跑一次 Release 订阅巡检，再重新聚合本地缓存。
    func refresh(category: ActivityCategory) async {
        await reload(category: category, shouldPollReleases: true)
    }

    private func reload(category: ActivityCategory, shouldPollReleases: Bool) async {
        if items.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            if shouldPollReleases {
                _ = await releasePoller.runNow()
            }

            async let reposTask = repoRepository.fetchAllStarred()
            async let releasesTask = releaseRepository.fetchTimeline(limit: 120)
            let (repos, releases) = try await (reposTask, releasesTask)

            let all = makeItems(repos: repos, releases: releases)
            items = filter(all, by: category)
            itemsRevision += 1
            lastRefreshedAt = Date()
            loadError = nil
        } catch {
            loadError = String(localized: "activity.error.loadFailed")
        }
    }

    private func filter(_ source: [ActivityItem], by category: ActivityCategory) -> [ActivityItem] {
        let filtered: [ActivityItem]
        if category == .all {
            // `.all` 视图专属去重：makeStarItems / makeRepositoryItems / makeSuggestionItems
            // 三个 builder 都派生自同一份 starred repos，同一个 repo 在 .all 视图会同时
            // 出现 .star / .repository / .suggestion 三条卡片（id 前缀不同，Identifiable
            // 不会去重）。dong4j 2026-06-11 反馈视觉冗余 → 这里做一次「按 repo.id」去重。
            //
            // 单独的具体分类（.star / .repository / .suggestion）不在这里走，因为：
            //  - 它们各自就是单一 kind 视角（按 starredAt / pushedAt / stars 数排序），
            //    用户主动选择「看 push 活动」或「看推荐」时不应被去重剥夺信号；
            //  - 单一 kind 内同 repo 本就不会重复（每个 repo 在每个 builder 里最多 1 条）。
            filtered = deduplicateForAllView(source)
        } else {
            filtered = source.filter { $0.category == category }
        }
        return filtered.sorted { lhs, rhs in
            (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
        }
    }

    /// `.all` 视图按 `repo.id` 在 `.star` / `.repository` / `.suggestion` 三类间去重。
    ///
    /// **去重范围**：仅这三类参与（都派生自 starred repos）。
    ///  - `.announcement`：无 repo，独立事件源；
    ///  - `.release`：独立事件源（用户订阅过的版本发布），与同 repo 的 star 语义并存；
    ///  - `.following`：当前未生产，预留同 announcement 处理。
    ///
    /// **保留规则**：同 repo 的多条候选里选「createdAt 最近」的那条；时间相同时
    /// 按 kind 优先级取最高（star > repository > suggestion）—— suggestion 与
    /// repository 的 createdAt 都来自 `pushedAt`，永远相同，需要 tiebreaker。
    /// 选择 star 优先是因为它代表「用户行为」，比 push 活动 / 启发式推荐更强信号。
    private func deduplicateForAllView(_ source: [ActivityItem]) -> [ActivityItem] {
        var bestByRepoId: [Int64: ActivityItem] = [:]
        var nonDedupItems: [ActivityItem] = []

        for item in source {
            guard Self.isDedupableKind(item.kind), let repoId = item.repo?.id else {
                nonDedupItems.append(item)
                continue
            }
            if Self.shouldReplace(existing: bestByRepoId[repoId], with: item) {
                bestByRepoId[repoId] = item
            }
        }

        return nonDedupItems + Array(bestByRepoId.values)
    }

    private static func isDedupableKind(_ kind: ActivityKind) -> Bool {
        switch kind {
        case .star, .repository, .suggestion:
            return true
        case .announcement, .release, .following:
            return false
        }
    }

    private static func shouldReplace(existing: ActivityItem?, with candidate: ActivityItem) -> Bool {
        guard let existing else { return true }
        let lhs = existing.createdAt ?? .distantPast
        let rhs = candidate.createdAt ?? .distantPast
        if rhs > lhs { return true }
        if rhs < lhs { return false }
        return kindPriority(candidate.kind) > kindPriority(existing.kind)
    }

    /// kind 优先级（仅 tiebreaker 用，越高越优先保留）。
    /// star 是用户行为信号最强；repository 是 push 活动；suggestion 是启发式推荐。
    private static func kindPriority(_ kind: ActivityKind) -> Int {
        switch kind {
        case .star:         return 3
        case .repository:   return 2
        case .suggestion:   return 1
        case .announcement, .release, .following:
            return 0
        }
    }

    private func makeItems(repos: [Repo], releases: [ReleaseTimelineEntry]) -> [ActivityItem] {
        var result: [ActivityItem] = []
        result.append(makeAnnouncement())
        result.append(contentsOf: releases.prefix(40).map(makeReleaseItem))
        result.append(contentsOf: makeStarItems(repos))
        result.append(contentsOf: makeRepositoryItems(repos))
        result.append(contentsOf: makeSuggestionItems(repos))
        return result
    }

    private func makeAnnouncement() -> ActivityItem {
        ActivityItem(
            id: "announcement:activity-v1",
            kind: .announcement,
            category: .announcement,
            title: String(localized: "activity.announcement.activityV1.title"),
            subtitle: String(localized: "activity.announcement.activityV1.subtitle"),
            body: String(localized: "activity.announcement.activityV1.body"),
            createdAt: Date(),
            htmlURL: nil,
            repo: nil,
            release: nil,
            isRead: true
        )
    }

    private func makeReleaseItem(_ entry: ReleaseTimelineEntry) -> ActivityItem {
        let release = entry.release
        let title = release.name?.isEmpty == false ? release.name! : release.tagName
        return ActivityItem(
            id: "release:\(release.id)",
            kind: .release,
            category: .release,
            title: title,
            subtitle: entry.repo.fullName,
            body: release.bodyTruncated,
            createdAt: Self.parseDate(release.publishedAt) ?? Self.parseDate(release.createdAtRemote),
            htmlURL: URL(string: release.htmlUrl),
            repo: entry.repo,
            release: release,
            isRead: release.isRead
        )
    }

    private func makeStarItems(_ repos: [Repo]) -> [ActivityItem] {
        repos
            .filter { $0.isStarred }
            .sorted { ($0.starredAt ?? "") > ($1.starredAt ?? "") }
            .prefix(30)
            .map { repo in
                ActivityItem(
                    id: "star:\(repo.id):\(repo.starredAt ?? "")",
                    kind: .star,
                    category: .star,
                    title: repo.fullName,
                    subtitle: String(localized: "activity.star.subtitle"),
                    body: repo.description,
                    createdAt: Self.parseDate(repo.starredAt),
                    htmlURL: URL(string: repo.htmlUrl),
                    repo: repo,
                    release: nil,
                    isRead: true
                )
            }
    }

    private func makeRepositoryItems(_ repos: [Repo]) -> [ActivityItem] {
        repos
            .filter { $0.isStarred }
            .sorted { ($0.pushedAt ?? $0.updatedAt ?? "") > ($1.pushedAt ?? $1.updatedAt ?? "") }
            .prefix(30)
            .map { repo in
                ActivityItem(
                    id: "repository:\(repo.id):\(repo.pushedAt ?? repo.updatedAt ?? "")",
                    kind: .repository,
                    category: .repository,
                    title: repo.fullName,
                    subtitle: String(localized: "activity.repository.subtitle"),
                    body: repo.description,
                    createdAt: Self.parseDate(repo.pushedAt) ?? Self.parseDate(repo.updatedAt),
                    htmlURL: URL(string: repo.htmlUrl),
                    repo: repo,
                    release: nil,
                    isRead: true
                )
            }
    }

    private func makeSuggestionItems(_ repos: [Repo]) -> [ActivityItem] {
        repos
            .filter { $0.isStarred && !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.starsCount == rhs.starsCount {
                    return (lhs.pushedAt ?? "") > (rhs.pushedAt ?? "")
                }
                return lhs.starsCount > rhs.starsCount
            }
            .prefix(20)
            .map { repo in
                ActivityItem(
                    id: "suggestion:\(repo.id)",
                    kind: .suggestion,
                    category: .suggestion,
                    title: repo.fullName,
                    subtitle: String(localized: "activity.suggestion.subtitle"),
                    body: repo.description,
                    createdAt: Self.parseDate(repo.pushedAt) ?? Self.parseDate(repo.updatedAt),
                    htmlURL: URL(string: repo.htmlUrl),
                    repo: repo,
                    release: nil,
                    isRead: true
                )
            }
    }

    /// GitHub API 大多返回带 fractional seconds 的 ISO8601；少数旧缓存可能没有。
    /// 这里保留 fallback，避免一条坏时间导致排序全部掉到底。
    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = ISO8601DateFormatter.shared.date(from: value) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }
}
