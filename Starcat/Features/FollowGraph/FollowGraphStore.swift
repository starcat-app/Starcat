//
//  FollowGraphStore.swift
//  Starcat
//
//  请求与图合并的串行所有者。网络 await 期间 actor 可以重入，因此每次返回都必须
//  校验 session；仅取消 Task 不足以阻止旧账户的迟到响应写入新会话。
//

import Foundation

enum FollowGraphStoreError: Error {
    case staleSession
    case quota(String)
    case authentication
}

/// ViewModel 负责公平排队，Store 负责最后一道账户会话与配额保护。
/// 产品已明确不设人为节点/边/请求数上限，最终规模由 GitHub API 配额与本机性能决定。
actor FollowGraphStore {
    private let provider: any FollowGraphProviding
    private let cache: FollowGraphDiskCache
    private var snapshot: FollowGraphSnapshot?
    private var session = UUID()
    private var requests = 0
    private var blockedUntil: Date?
    /// 仅覆盖写操作之前已开始的分页；之后发起的刷新仍以 GitHub 新响应为准。
    private var followRevision = 0
    private var followChanges: [String: (node: FollowGraphNode, following: Bool, revision: Int)] = [:]

    init(provider: any FollowGraphProviding, cache: FollowGraphDiskCache = .shared) {
        self.provider = provider
        self.cache = cache
    }

    /// 重开窗口的缓存读取可能早于刚完成的关注确认，不允许用旧快照覆盖同账户的新状态。
    @discardableResult
    func begin(_ snapshot: FollowGraphSnapshot, session: UUID) -> FollowGraphSnapshot {
        if (self.snapshot?.accountID != snapshot.accountID || self.snapshot?.relation != snapshot.relation) {
            followRevision = 0
            followChanges = [:]
        }
        if (self.snapshot?.accountID != snapshot.accountID || self.snapshot?.relation != snapshot.relation) ||
            snapshot.savedAt >= (self.snapshot?.savedAt ?? .distantPast) {
            self.snapshot = snapshot
        }
        self.session = session
        requests = 0
        return self.snapshot!
    }

    /// 手动加载逐页追加；完整刷新先收集新目标，只有末页成功才做删除。
    /// requests 只做诊断计数，不再作为请求数闸门；真实限流由 GitHub 429 触发。
    func load(userID: String, session: UUID, count: Int = 50, refresh: Bool = false,
              refreshLimit: Int? = nil) async throws -> FollowGraphSnapshot {
        guard self.session == session, let current = snapshot, let user = current.nodes[userID] else {
            throw FollowGraphStoreError.staleSession
        }
        // cursor 在末页可能为 nil；不能把“已完成”误解为“尚未开始”而重复读取第一页。
        // 显式刷新仍从头请求，已完成缓存的普通读取也不应受网络冷却时间影响。
        if !refresh, current.progress[userID]?.complete == true { return current }
        if let blockedUntil, blockedUntil > Date() {
            throw FollowGraphStoreError.quota(blockedUntil.ISO8601Format())
        }
        var cursor = refresh ? nil : current.progress[userID]?.cursor
        let revisionAtStart = followRevision
        var refreshedTargets = Set<String>()
        var refreshedCount = 0
        repeat {
            try Task.checkCancellation()
            guard snapshot != nil else { throw FollowGraphStoreError.staleSession }
            requests += 1
            let page: FollowGraphPage
            do {
                let pageCount = refresh ? min(count, max(1, (refreshLimit ?? Int.max) - refreshedCount)) : count
                page = try await provider.page(login: user.login, cursor: cursor, count: pageCount)
            } catch NetworkError.rateLimited(let retryAfter) {
                blockedUntil = Date().addingTimeInterval(max(1, retryAfter))
                throw FollowGraphStoreError.quota(blockedUntil!.ISO8601Format())
            } catch NetworkError.unauthorized {
                throw FollowGraphStoreError.authentication
            }
            try Task.checkCancellation()
            guard self.session == session, var value = snapshot else { throw FollowGraphStoreError.staleSession }
            guard page.source.id == userID, !page.hasNextPage || page.cursor != cursor else {
                throw NetworkError.clientError(statusCode: 502, message: String.l10n("followGraph.status.unavailable"))
            }
            refreshedTargets.formUnion(page.nodes.map(\.id))
            refreshedCount += page.nodes.count
            value.merge(page, replacing: refresh && !page.hasNextPage ? refreshedTargets : nil)
            DiagnosticLogStore.shared.enqueue(DiagnosticEvent(
                level: .info, category: "followGraph", operation: "pageMerge",
                message: "Relation page merged", context: ["user": userID], phase: "merged",
                fields: ["totalCount": .integer(page.totalCount),
                         "fetchedCount": .integer(page.nodes.count),
                         "uniquePageCount": .integer(Set(page.nodes.map(\.id)).count),
                         "cachedCount": .integer(value.relationCount(for: userID)),
                         "hasNextPage": .boolean(page.hasNextPage),
                         "hasCursor": .boolean(page.cursor != nil),
                         "refresh": .boolean(refresh),
                         "requestCount": .integer(requests),
                         "rateRemaining": .integer(page.remaining),
                         "rateResetAt": .string(page.resetAt)]
            ))
            // 刷新可能跨多页。整轮开始后确认的关注写入不能被末页的旧目标集合恢复。
            for change in followChanges.values.sorted(by: { $0.revision < $1.revision })
                where change.revision > revisionAtStart {
                value.setFollowing(change.following, node: change.node)
            }
            // 刷新前若已保存旧 cursor，中断时不能拿新的中间 cursor 当成完整刷新续点。
            // 下次刷新仍从头读取；普通分页则可以从当前 cursor 继续。
            if refresh && page.hasNextPage {
                value.progress[userID]?.complete = false
                value.progress[userID]?.cursor = current.progress[userID]?.cursor
            }
            snapshot = value
            // 每页保存：即使遮盖层被关闭或后续分页失败，已经取得的关系仍可离线恢复。
            try await cache.save(value)
            guard self.session == session else { throw FollowGraphStoreError.staleSession }
            cursor = page.cursor
            if !refresh || !page.hasNextPage || refreshedCount >= (refreshLimit ?? Int.max) { break }
        } while true
        return snapshot!
    }

    /// 真实 429 之后暴露恢复时间，供 UI 展示本地时间；没有限流时为 nil。
    var quotaResetAt: Date? { blockedUntil }

    func read(session: UUID) -> FollowGraphSnapshot? {
        self.session == session ? snapshot : nil
    }

    /// 关闭画布会改变加载 session，但已成功的写操作仍需要读取同账户确认结果。
    func read(accountID: String) -> FollowGraphSnapshot? {
        snapshot?.accountID == accountID ? snapshot : nil
    }

    /// 远端成功后的本地确认；账户校验、图合并与缓存共用 Store，避免 UI 私自双写快照。
    func setFollowing(_ following: Bool, node: FollowGraphNode, accountID: String) async throws -> FollowGraphSnapshot {
        guard var value = snapshot, value.accountID == accountID, node.id != value.rootID else {
            throw FollowGraphStoreError.staleSession
        }
        followRevision += 1
        followChanges[node.id] = (node, following, followRevision)
        value.setFollowing(following, node: node)
        snapshot = value
        try await cache.save(value)
        guard let current = snapshot, current.accountID == accountID else {
            throw FollowGraphStoreError.staleSession
        }
        return current
    }

    func finishRefresh(session: UUID) async throws -> FollowGraphSnapshot? {
        guard self.session == session, var value = snapshot else { return nil }
        value.pruneUnreachable()
        snapshot = value
        try await cache.save(value)
        // 保存期间 actor 可重入；返回最新快照，避免随后确认的关注操作被旧值覆盖。
        return snapshot
    }
}
