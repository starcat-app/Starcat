//
//  RepoIssuesSharedStore.swift
//  Starcat
//
//  Issues 浮层的进程内共享缓存：per-repo 的「未解决 / 已关闭」首屏快照与精确计数。
//
//  为什么（2026-11-01 dong4j）：详情页 Issues 浮层与 hero「Issues」角标都消费 issues
//  数据，但浮层此前完全无缓存——每次打开浮层、来回切筛选、切仓库再切回都会重新打
//  GitHub 首屏与 Search 计数。这里提供 stale-while-revalidate 的内存数据源：
//  - 读：命中即返回（含已过期数据，调用方自行决定是否后台校准）；未命中返回 nil。
//  - 写：首屏 / 计数请求成功后回写；角标因此能在浮层首次打开后拿到精确未解决数。
//  - TTL 对齐仓库洞察 recentActivity 的 15 分钟（同为 issues 活动数据，口径一致）。
//  - 只做进程内存缓存，不落盘：issues 列表可随时从 GitHub 重建，不属于「用户数据不能丢」。
//  - 与「项目洞察-最近动态」不共享请求：那边是一次 GraphQL bundle（KPI + 最近 5 条
//    PR/Issue 事件，无 labels/作者/评论数字段），形状喂不了浮层列表，反向亦然；
//    能共享的只有本 store 承载的首屏与计数。
//
//  容量：按仓库 LRU（写入触碰时间），超过上限淘汰最久未用仓库的全部条目，
//  避免长会话浏览大量仓库时字典无界增长。
//

import Foundation

/// 单个状态（open / closed）首屏的缓存快照。
struct RepoIssuesPageSnapshot: Sendable, Equatable {
    let issues: [GitHubRepoIssue]
    /// Link 头解析出的下一页页码；nil = 没有更多（缓存恢复 `hasMore` 用）。
    let nextPage: Int?
    let fetchedAt: Date
}

/// 未解决 / 已关闭精确计数快照（`/search/issues` total_count，不含 PR）。
struct RepoIssuesCountSnapshot: Sendable, Equatable {
    let openCount: Int
    let closedCount: Int
    let fetchedAt: Date
}

actor RepoIssuesSharedStore {

    /// 进程级单例：详情窗口可开关、ViewModel 可重建，缓存要跨这些生命周期存活。
    /// 测试一律注入独立实例，禁止依赖单例状态。
    static let shared = RepoIssuesSharedStore()

    /// 命中结果：快照 + 是否已过 TTL。过期数据同样返回，由调用方决定后台校准。
    struct Hit<Value: Sendable> {
        let value: Value
        let isStale: Bool
    }

    private var pages: [String: RepoIssuesPageSnapshot] = [:]
    private var counts: [String: RepoIssuesCountSnapshot] = [:]
    private var lastTouchedAt: [String: Date] = [:]

    /// 与仓库洞察 recentActivity 的 TTL 口径一致（15 分钟）。
    private let timeToLive: TimeInterval
    /// 最多缓存仓库数；超限淘汰最久未触碰的仓库。
    private let maxRepos: Int

    init(timeToLive: TimeInterval = 15 * 60, maxRepos: Int = 12) {
        self.timeToLive = timeToLive
        self.maxRepos = maxRepos
    }

    // MARK: - 读

    func page(
        owner: String,
        repo: String,
        state: GitHubRepoIssueState
    ) -> Hit<RepoIssuesPageSnapshot>? {
        guard let snapshot = pages[cacheKey(owner: owner, repo: repo, state: state)] else { return nil }
        touch(repoKey(owner: owner, repo: repo))
        return Hit(value: snapshot, isStale: isStale(snapshot.fetchedAt))
    }

    func counts(owner: String, repo: String) -> Hit<RepoIssuesCountSnapshot>? {
        let key = repoKey(owner: owner, repo: repo)
        guard let snapshot = counts[key] else { return nil }
        touch(key)
        return Hit(value: snapshot, isStale: isStale(snapshot.fetchedAt))
    }

    // MARK: - 写

    func storePage(
        _ snapshot: RepoIssuesPageSnapshot,
        owner: String,
        repo: String,
        state: GitHubRepoIssueState
    ) {
        pages[cacheKey(owner: owner, repo: repo, state: state)] = snapshot
        touch(repoKey(owner: owner, repo: repo))
        evictIfNeeded()
    }

    func storeCounts(
        _ snapshot: RepoIssuesCountSnapshot,
        owner: String,
        repo: String
    ) {
        counts[repoKey(owner: owner, repo: repo)] = snapshot
        touch(repoKey(owner: owner, repo: repo))
        evictIfNeeded()
    }

    // MARK: - 私有

    private func isStale(_ fetchedAt: Date) -> Bool {
        Date().timeIntervalSince(fetchedAt) >= timeToLive
    }

    /// GitHub owner / repo 大小写不敏感，统一小写避免同仓库写出双份缓存。
    private func repoKey(owner: String, repo: String) -> String {
        "\(owner)/\(repo)".lowercased()
    }

    private func cacheKey(owner: String, repo: String, state: GitHubRepoIssueState) -> String {
        "\(repoKey(owner: owner, repo: repo))#\(state.rawValue)"
    }

    private func touch(_ key: String) {
        lastTouchedAt[key] = Date()
    }

    /// 淘汰最久未触碰仓库的 pages + counts + 触碰记录，保证字典有界。
    private func evictIfNeeded() {
        guard lastTouchedAt.count > maxRepos else { return }
        let overflow = lastTouchedAt.count - maxRepos
        let evictedKeys = lastTouchedAt
            .sorted { $0.value < $1.value }
            .prefix(overflow)
            .map(\.key)
        for key in evictedKeys {
            lastTouchedAt[key] = nil
            counts[key] = nil
            pages = pages.filter { !$0.key.hasPrefix("\(key)#") }
        }
    }
}
