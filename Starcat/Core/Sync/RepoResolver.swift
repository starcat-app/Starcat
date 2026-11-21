//
//  RepoResolver.swift
//  Starcat
//
//  R-01 详情页 Repo 解析链（Chain of Responsibility 协调器）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  职责
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 持有 `[any RepoSource]`，按顺序询问每一个源
//  - 命中：返回 `Resolution`（含 sourceName / repo / 元信息），停止询问
//  - 未命中（nil）：继续询问下一个
//  - throws：捕获 + 打 warning 日志 + 跳过此源继续询问下一个
//  - 链全部失败的兜底由 `MinimalRepoSource`（永远命中）保证；不应该走到这里之外
//
//  ────────────────────────────────────────────────────────────────────────────
//  Resolution.isLocalHit
//  ────────────────────────────────────────────────────────────────────────────
//
//  各场景 ContentView 的关键决策点：
//  - `isLocalHit == true` → 已 star，渲染 tags / notes / release 三段
//  - `isLocalHit == false` → 未 star，三段不渲染（设计 §3.2.6）
//
//  约定：只有 `LocalRepoSource` 命中才算 isLocalHit = true。其他源虽然返回的
//  Repo 也可能恰好 isStarred = true（如 GitHub `/repos` 响应里 `viewer_starred`，
//  R-01 暂未消费此字段），但都视为「非本地真值」，让三段判断更稳定。
//

import Foundation

/// 一次 resolve 的结果。
struct RepoResolution: Sendable {
    /// 命中源的 name（用于日志 / debug）。
    let sourceName: String

    /// 解析出来的 Repo（永远非 nil，因 chain 末尾 MinimalRepoSource 兜底）。
    let repo: Repo

    /// 是否来自 LocalRepoSource（本地 SQLite 真值）。
    /// 各场景 ContentView 用此决定是否渲染 tags / notes / release 三段。
    let isLocalHit: Bool

    /// 是否最终走到了 MinimalRepoSource（chain 全部前面的源失败）。
    /// UI 层可以选择性显示 warning（如顶部 banner「无法获取最新数据」）。
    let isMinimal: Bool
}

/// 详情页 Repo 解析链。
///
/// 用法：
/// ```swift
/// let resolution = await resolver.resolve(owner: "alice", name: "foo", hint: nil)
/// // resolution.repo 永远非 nil
/// if resolution.isLocalHit { /* 渲染 tags / notes / release */ }
/// ```
@MainActor
final class RepoResolver {

    let chain: [any RepoSource]

    init(chain: [any RepoSource]) {
        self.chain = chain
    }

    /// 按顺序询问 chain，返回首个命中。
    ///
    /// **不抛错**：链中任一 source throws，本方法 catch + 打 warning + 跳过。
    /// 如果调用方需要拿到「具体哪一步失败」的详细信息（如 trending 详情显示
    /// 「⚠️ 无法获取最新数据」），通过 `resolution.isMinimal` 判断即可。
    func resolve(owner: String, name: String, hint: StarcatRepoCardDTO? = nil) async -> RepoResolution {
        for source in chain {
            do {
                if let repo = try await source.tryResolve(owner: owner, name: name, hint: hint) {
                    let isLocalHit = (source is LocalRepoSource)
                    let isMinimal = (source is MinimalRepoSource)
                    AppLog.sync.info("RepoResolver hit: \(source.name, privacy: .public) (\(owner, privacy: .public)/\(name, privacy: .public), localHit=\(isLocalHit, privacy: .public), minimal=\(isMinimal, privacy: .public))")
                    return RepoResolution(
                        sourceName: source.name,
                        repo: repo,
                        isLocalHit: isLocalHit,
                        isMinimal: isMinimal
                    )
                }
            } catch {
                AppLog.sync.warning("RepoResolver source \(source.name, privacy: .public) threw: \(error.localizedDescription, privacy: .public) (\(owner, privacy: .public)/\(name, privacy: .public))")
                continue
            }
        }

        // 理论不可达：链末尾 MinimalRepoSource 永远命中。
        // 兜底：构造一个最小 Repo 直接返回，避免 force unwrap 崩溃。
        AppLog.sync.error("RepoResolver: all sources failed unexpectedly (chain misconfigured?). Falling back to MinimalRepoSource directly.")
        // 最小仓库回退仍能完成本次解析，异常链路仅保留系统日志。
        return RepoResolution(
            sourceName: "MinimalRepoSource (forced)",
            repo: Repo.makeMinimal(owner: owner, name: name, hint: hint),
            isLocalHit: false,
            isMinimal: true
        )
    }
}

/// 共用详情的关注者计数读取。普通读取复用已知值，主动刷新只更新已有仓库的计数列。
@MainActor
enum RepoSubscriberCountResolver {
    /// 列表和本地已知值（包括真实零）直接复用。`isCurrent` 隔离切号时仍在途的查询，
    /// SwiftUI task 的取消则隔离连点切仓；二者都必须在挂起后、落库前检查。
    static func resolve(
        for repo: Repo,
        repository: any RepoRepositoryProtocol,
        apiClient: any GitHubAPIClientProtocol,
        forceRefresh: Bool = false,
        isCurrent: () -> Bool
    ) async throws -> Int? {
        try checkCurrent(isCurrent)
        if !forceRefresh {
            if let count = repo.subscribersCount { return count }
            let cached = if repo.id > 0 {
                try? await repository.findById(repo.id)
            } else {
                try? await repository.findByOwnerName(owner: repo.owner, name: repo.name)
            }
            try checkCurrent(isCurrent)
            if let count = cached?.subscribersCount { return count }
        }

        guard !repo.owner.isEmpty, !repo.name.isEmpty else { return nil }
        let dto = try await apiClient.repo(owner: repo.owner, repo: repo.name, forceRefresh: forceRefresh)
        try checkCurrent(isCurrent)
        guard repo.id <= 0 || dto.id == repo.id, let count = dto.subscribersCount else { return nil }

        let saved = try? await repository.cacheSubscriberCount(
            repoID: dto.id, count: count, replacingExisting: forceRefresh
        )
        try checkCurrent(isCurrent)
        return saved ?? count
    }

    private static func checkCurrent(_ isCurrent: () -> Bool) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }
}

/// 精简推荐快照的公开资料补齐，复用 repos 缓存，不创建 Star 或知识库归属。
@MainActor
enum PublicRepoMetadataResolver {
    /// 完整缓存一天内直接复用；离线时允许完整旧缓存，缺字段时必须重试公开详情。
    /// isCurrent 在挂起后检查账号作用域，防止旧账号的请求落入新账号数据库。
    static func resolve(
        owner: String,
        name: String,
        repository: any RepoRepositoryProtocol,
        apiClient: any GitHubAPIClientProtocol,
        now: Date = Date(),
        isCurrent: () -> Bool = { true }
    ) async throws -> Repo {
        let cached = try await repository.findByOwnerName(owner: owner, name: name)
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let complete = cached.map {
            $0.subscribersCount != nil && $0.createdAt != nil && $0.updatedAt != nil
        } ?? false
        if complete, let cached,
           let date = ISO8601DateFormatter.githubDate(from: cached.cachedAt),
           now.timeIntervalSince(date) < 86_400 {
            return cached
        }
        do {
            let dto = try await apiClient.repo(owner: owner, repo: name)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let saved = try await repository.upsertExternalRepoForLibrary(repoDTO: dto, syncedAt: now)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return saved
        } catch {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if complete, let cached { return cached }
            throw error
        }
    }
}
