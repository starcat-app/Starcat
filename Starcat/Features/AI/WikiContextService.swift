//
//  WikiContextService.swift
//  Starcat
//
//  Wiki 探测结果的 SWR 中间层（2026-06-15 dong4j 拍板）。
//
//  模块职责：
//  - 封装 "查 `DiskWikiCache` → 命中 fresh 直接返回 / stale 返回旧值且后台刷新 / miss
//    可选阻塞拉取" 的 SWR 编排逻辑；
//  - 把 `WikiAPI.fetchStatus` 与 `DiskWikiCache.save` 串到一起，调用方只关心
//    "我要这个 repo 的 [WikiLink]"。
//  - 保持 `DiskWikiCache` 纯 CRUD：本层是唯一会发起网络请求并写盘的组合层。
//
//  关键约束：
//    1. **同步路径 `cachedLinks(owner:repo:)` 永远秒返回**：仅读盘。bootstrap / 设置页
//       渲染 / 第一次发消息走这个，避免任何网络 IO 拖慢 UI 关键路径。
//    2. **后台刷新 fire-and-forget**：`refreshInBackground` 不返回 Task，调用方不
//       等待。完成后通过 `DiskWikiCache.save` 写盘 + reload，让 @Observable 派生量
//       更新；同一 repo 下次进入聊天即可命中新结果。
//    3. **去重并发**：同一 `(owner, repo)` 同时多次触发 refresh 时只跑一次，避免
//       AI 窗口被快速开关或 bootstrap 与 popover 同时打开造成重复请求。用
//       `inFlightRefreshes: [WikiRepoKey: Task<...>]` 去重，**与 `RepoAIChatViewModel.bootstrapTask`
//       同款模式**。
//    4. **错误吞掉**：网络失败不抛给 UI，只 warn 日志 —— wiki 是辅助上下文，挂了不
//       应阻塞对话；下次重试自然有机会成功。**唯一例外**是显式调用
//       `refresh(owner:repo:) async throws` 的同步阻塞版本，那是给"详情页强制刷新"
//       这种需要用户感知失败的场景准备的（首版不必接入，留接口）。
//

import Foundation

/// `(owner, repo)` 唯一标识，并发去重 key 用。
struct WikiRepoKey: Hashable, Sendable {
    let owner: String
    let repo: String
}

/// 抽象网络层 —— 让 `WikiContextService` 在测试时可注入 stub，不必启 URLProtocol。
///
/// **不嵌套在 `WikiContextService` 内**：嵌进 `@MainActor final class` 会让 protocol
/// 继承 main actor isolation，而生产实现 `WikiAPI` 是独立 actor，无法 conform。
/// 顶层 protocol 不带 actor isolation，actor 自身的 async method 直接满足要求。
protocol WikiStatusFetching: Sendable {
    func fetchStatus(owner: String, repo: String) async throws -> [WikiStatusItem]
}

extension WikiAPI: WikiStatusFetching {}

/// Wiki SWR 编排层（所有公开方法 `@MainActor`）。
///
/// 单例由 `AppDependencies.wikiContextService` 注入；测试通过 init 注入 stub
/// `WikiStatusFetching` + 独立 `DiskWikiCache`(rootOverride) 隔离。
@MainActor
final class WikiContextService {

    private struct RefreshRequest: Sendable {
        let key: WikiRepoKey
        let generation: UInt64
    }

    // MARK: - 依赖

    private let cache: DiskWikiCache
    private let fetcher: WikiStatusFetching

    /// 同一 `(owner, repo)` 的并发去重：排队和执行阶段都只能存在一份请求。
    private var inFlightRefreshes: [WikiRepoKey: Task<Void, Never>] = [:]
    private var pendingRefreshes: [RefreshRequest] = []
    private var pendingKeys: Set<WikiRepoKey> = []
    private var refreshGeneration: UInt64 = 0
    private let maximumConcurrentRefreshes: Int

    init(
        cache: DiskWikiCache,
        fetcher: WikiStatusFetching,
        maximumConcurrentRefreshes: Int = 2
    ) {
        self.cache = cache
        self.fetcher = fetcher
        self.maximumConcurrentRefreshes = max(1, maximumConcurrentRefreshes)
    }

    // MARK: - 同步只读：bootstrap / 设置页 / chat 第一条用

    /// 读 cache 拿当前已知 `[WikiLink]`，不发起网络。
    /// - cache miss → 返回空数组（调用方应通过 `refreshInBackground` 顺手触发拉取）；
    /// - cache hit（fresh 或 stale 都算）→ 返回当时探测到的 indexed 链接。
    func cachedLinks(owner: String, repo: String) -> [WikiLink] {
        cache.load(owner: owner, repo: repo)?.indexedLinks ?? []
    }

    /// 读 cache 拿当前快照（含 fresh / stale 信息）。
    /// 主要给 SWR 决策路径用（"返回旧值 + 是否需要后台刷新"）。
    func cachedSnapshot(owner: String, repo: String) -> WikiCacheSnapshot? {
        cache.load(owner: owner, repo: repo)
    }

    /// 所有前台消费方共用的 cache-first 入口。fresh 只读缓存，stale / miss 只排队，
    /// 因此详情渲染、Companion 和 AI bootstrap 都不会等待外部 Wiki 网络。
    func cacheFirstLinks(
        owner: String,
        repo: String,
        isPrivate: Bool
    ) -> [WikiLink] {
        // 私有仓库名称本身也属于用户数据，不能发送给第三方 Wiki 服务。
        guard !isPrivate else { return [] }
        let snapshot = cache.load(owner: owner, repo: repo)
        if snapshot?.freshness() != .fresh {
            enqueueRefresh(owner: owner, repo: repo, isPrivate: false)
        }
        return snapshot?.indexedLinks ?? []
    }

    // MARK: - 异步刷新

    /// fire-and-forget 后台刷新：如果该 repo 没在刷，启一个 Task 跑 `WikiAPI.fetchStatus`
    /// + 写盘。**不返回 Task**——调用方意图就是"我不关心结果什么时候到"。
    ///
    /// 典型触发路径：
    /// - `RepoAIChatViewModel.bootstrap`：cache miss 或 stale 时调一下；
    /// - 详情页打开 wiki popover 时（未来接入）。
    func refreshInBackground(owner: String, repo: String, isPrivate: Bool = false) {
        enqueueRefresh(owner: owner, repo: repo, isPrivate: isPrivate)
    }

    /// 后台批量补齐与前台 miss 共用同一有界队列。这里不直接为每个仓库创建网络 Task，
    /// 避免大知识库启动时瞬间产生数千个连接和 Task。
    func enqueueRefresh(owner: String, repo: String, isPrivate: Bool) {
        guard !isPrivate else { return }
        let key = WikiRepoKey(owner: owner, repo: repo)
        guard inFlightRefreshes[key] == nil, !pendingKeys.contains(key) else { return }

        pendingKeys.insert(key)
        pendingRefreshes.append(RefreshRequest(key: key, generation: refreshGeneration))
        drainRefreshQueue()
    }

    /// 同步阻塞版本：拉一次最新结果并返回 `[WikiLink]`，抛错暴露给调用方。
    /// 首版没有 UI 入口调用此方法，留作"详情页强制刷新"未来接入。
    func refresh(owner: String, repo: String, isPrivate: Bool = false) async throws -> [WikiLink] {
        guard !isPrivate else { return [] }
        let items = try await fetcher.fetchStatus(owner: owner, repo: repo)
        let snapshot = WikiCacheSnapshot(
            owner: owner,
            repo: repo,
            probedAt: Date(),
            nextProbeAt: WikiCacheSnapshot.computeNextProbeAt(items: items),
            items: items
        )
        try cache.save(snapshot: snapshot)
        return snapshot.indexedLinks
    }

    /// 账号 / 数据库切换前取消旧队列并推进 generation。旧网络请求即使不响应取消，
    /// 返回后也会因 generation 不匹配而跳过写盘与后续 Metadata 事件。
    func cancelPendingRefreshes() async {
        refreshGeneration &+= 1
        pendingRefreshes.removeAll()
        pendingKeys.removeAll()
        let tasks = Array(inFlightRefreshes.values)
        inFlightRefreshes.removeAll()
        tasks.forEach { $0.cancel() }
        for task in tasks {
            await task.value
        }
    }

    // MARK: - 私有

    private func performRefresh(_ request: RefreshRequest) async {
        do {
            let items = try await fetcher.fetchStatus(owner: request.key.owner, repo: request.key.repo)
            try Task.checkCancellation()
            guard request.generation == refreshGeneration else { return }
            let snapshot = WikiCacheSnapshot(
                owner: request.key.owner,
                repo: request.key.repo,
                probedAt: Date(),
                nextProbeAt: WikiCacheSnapshot.computeNextProbeAt(items: items),
                items: items
            )
            do {
                try cache.save(snapshot: snapshot)
            } catch {
                AppLog.ai.warning("Wiki context: cache save failed owner=\(request.key.owner, privacy: .public) repo=\(request.key.repo, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        } catch is CancellationError {
            // 切库和 App 生命周期取消属于正常路径，不记录为网络故障。
        } catch {
            // 网络失败静默：wiki 是辅助上下文，挂了不影响对话主流程。
            AppLog.ai.info("Wiki context: refresh failed owner=\(request.key.owner, privacy: .public) repo=\(request.key.repo, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func drainRefreshQueue() {
        while inFlightRefreshes.count < maximumConcurrentRefreshes,
              !pendingRefreshes.isEmpty {
            let request = pendingRefreshes.removeFirst()
            pendingKeys.remove(request.key)
            guard request.generation == refreshGeneration else { continue }
            let task = Task { [weak self] in
                guard let self else { return }
                await self.performRefresh(request)
                self.finishRefresh(request)
            }
            inFlightRefreshes[request.key] = task
        }
    }

    private func finishRefresh(_ request: RefreshRequest) {
        guard request.generation == refreshGeneration else { return }
        inFlightRefreshes[request.key] = nil
        drainRefreshQueue()
    }
}
