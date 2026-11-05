//
//  FollowGraphStore.swift
//  Starcat
//
//  请求与图合并的串行所有者。网络 await 期间 actor 可以重入，因此每次返回都必须
//  校验 session；仅取消 Task 不足以阻止旧账户的迟到响应写入新会话。
//

import Foundation

enum FollowGraphStoreError: Error {
    case budget
    case staleSession
    case quota(String)
    case authentication
}

/// ViewModel 负责公平排队，Store 负责最后一道容量、配额与账户写入保护。
actor FollowGraphStore {
    private let provider: any FollowGraphProviding
    private let cache: FollowGraphDiskCache
    private var snapshot: FollowGraphSnapshot?
    private var session = UUID()
    private var requests = 0
    private var blockedUntil: Date?

    init(provider: any FollowGraphProviding, cache: FollowGraphDiskCache = .shared) {
        self.provider = provider
        self.cache = cache
    }

    func begin(_ snapshot: FollowGraphSnapshot, session: UUID) {
        self.snapshot = snapshot
        self.session = session
        requests = 0
    }

    /// 手动加载逐页追加；完整刷新先收集新目标，只有末页成功才做删除。
    func load(userID: String, session: UUID, count: Int = 50, refresh: Bool = false,
              refreshLimit: Int? = nil) async throws -> FollowGraphSnapshot {
        guard self.session == session, let current = snapshot, let user = current.nodes[userID] else {
            throw FollowGraphStoreError.staleSession
        }
        if let blockedUntil, blockedUntil > Date() {
            throw FollowGraphStoreError.quota(blockedUntil.ISO8601Format())
        }
        var cursor = refresh ? nil : current.progress[userID]?.cursor
        var refreshedTargets = Set<String>()
        var refreshedCount = 0
        repeat {
            try Task.checkCancellation()
            guard requests < 300, let value = snapshot,
                  value.nodes.count < 10_000, value.edges.count < 30_000 else {
                throw FollowGraphStoreError.budget
            }
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
            let nodeIDs = Set(page.nodes.map(\.id)).union(value.nodes.keys)
            let newEdges = Set(page.nodes.filter { $0.id != userID }.map {
                FollowGraphEdge(source: userID, target: $0.id)
            })
            guard nodeIDs.count <= 10_000, value.edges.union(newEdges).count <= 30_000 else {
                throw FollowGraphStoreError.budget
            }
            guard page.source.id == userID, !page.hasNextPage || page.cursor != cursor else {
                throw NetworkError.clientError(statusCode: 502, message: String.l10n("followGraph.status.unavailable"))
            }
            refreshedTargets.formUnion(page.nodes.map(\.id))
            refreshedCount += page.nodes.count
            value.merge(page, replacing: refresh && !page.hasNextPage ? refreshedTargets : nil)
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
            if page.remaining < 200 {
                blockedUntil = ISO8601DateFormatter().date(from: page.resetAt) ?? Date().addingTimeInterval(60)
                throw FollowGraphStoreError.quota(page.resetAt)
            }
            cursor = page.cursor
            if !refresh || !page.hasNextPage || refreshedCount >= (refreshLimit ?? Int.max) { break }
        } while true
        return snapshot!
    }

    func read(session: UUID) -> FollowGraphSnapshot? {
        self.session == session ? snapshot : nil
    }

    func finishRefresh(session: UUID) async throws -> FollowGraphSnapshot? {
        guard self.session == session, var value = snapshot else { return nil }
        value.pruneUnreachable()
        snapshot = value
        try await cache.save(value)
        return value
    }
}
