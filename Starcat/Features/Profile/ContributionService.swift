//
//  ContributionService.swift
//  Starcat
//
//  GitHub 贡献草坪数据加载 + 内存缓存 + 3 小时 TTL 协调器。
//  HOM-PROFILE 2026-06-05 引入。
//
//  设计动机：
//  - 贡献草坪渲染只需要拉一次 GraphQL，但用户切页 / 反复打开 sidebar 都不应重复请求。
//  - 同时 GitHub 的贡献统计有 3 小时左右的延迟更新，TTL 设 3h 是合理的"用户感知到刷新"
//    与"避免无意义请求"的平衡点。
//  - 与 `SyncManager` 解耦：贡献草坪是用户信息维度而非 stars 维度，不应捆在全量同步路径上。
//
//  数据流：
//  ┌──────────┐   load(force=false)
//  │ Sidebar  │ ──────────────────►┐
//  │  View    │                    │
//  └──────────┘                    ▼
//                         ┌────────────────┐
//                         │ ContributionSvc│
//                         │  (Observable)  │
//                         └────────────────┘
//                          │     ▲     │
//                          │     │     │ ttl 内命中
//                          │     │     ▼
//                          │  cache（内存 + 系统 Caches 目录）
//                          ▼
//                   GitHubAPIClient.graphql
//
//  缓存策略：
//  - **内存**：service 实例持有最新一份 `payload`；@Observable 让 SidebarView 自动重渲染。
//  - **磁盘**：每个账号一份紧凑的年度概览。启动先恢复草坪，再按 TTL 后台刷新。
//  - **每日明细**：按当前显示范围批量预拉；仅把 UTC 日期与五个计数存入系统 Caches。
//  - **TTL**：3 小时。`load(force: true)` 显式强刷（用户点刷新按钮等）。
//  - **错误处理**：拉取失败保留旧数据 + 设 `lastError`，UI 仍能显示历史草坪 + 一个可选错误标记。
//
//  关键约束：
//  - `@MainActor`：state 变更必须主线程（@Observable + SwiftUI 观察约束）。
//  - 同一 login 同时只允许一个进行中的请求，避免重复打 GraphQL（用 `inflightTask` 互斥）。
//

import Foundation
import Observation

/// 贡献草坪服务，单例语义（一个登录用户对应一个）。
@MainActor
@Observable
final class ContributionService {

    // MARK: - 状态（UI 观察）

    /// 当前已加载的贡献草坪数据。nil = 从未加载成功。
    /// 失败时不清空，保留旧数据避免 UI 抖动空白。
    private(set) var payload: ContributionCalendarPayload?

    /// 当前是否在拉取中（loading 仅在没有缓存且首次拉取时为 true，
    /// 后台刷新不进入 loading 态以避免 UI 闪烁）。
    private(set) var isLoading: Bool = false

    /// 最近一次错误；UI 可选展示（一般沉默处理即可）。
    private(set) var lastError: (any LocalizedError)?

    /// 上次成功加载时间戳，用于判 TTL 与显示 "X 分钟前"。
    private(set) var lastFetchedAt: Date?

    /// 草坪从磁盘恢复或网络更新后通知 Widget 快照重建。
    ///
    /// 这是装配层副作用，不属于 SwiftUI 可观察状态；调用方必须弱捕获，避免与
    /// `WidgetRefreshCoordinator` 形成生命周期环。
    @ObservationIgnored
    var onPayloadDidChange: (() -> Void)?

    // MARK: - 依赖

    /// GraphQL 调用入口；与 REST 同一个 client，复用 token 注入与集中式 401。
    /// 注意：协议 `GitHubAPIClientProtocol` 没暴露 `graphql<T>`（避免泛型 method 让 Mock 复杂化），
    /// 这里直接持有具体 `GitHubAPIClient` actor。Mock 注入由测试中通过 init 替换实现。
    private let apiClient: GitHubAPIClient

    /// 旧概览的 UserDefaults key 前缀。新文件成功写入后才删除。
    private let cacheKeyPrefix = "contribution.calendar."

    /// TTL：3 小时（与 GitHub 草坪刷新粒度同量级，避免无意义高频请求）。
    private let ttl: TimeInterval = 3 * 60 * 60

    /// 同一账号的重复加载共用进行中的请求。
    private var inflightTask: Task<Void, Never>?

    private var activeLogin: String?
    private var activityTask: Task<Void, Never>?
    private var activityCache = ContributionActivityCache()
    @ObservationIgnored private var activityRange: ContributionGraphRange = .recent90
    private let cacheDirectory: URL
    private let defaults: UserDefaults

    var isPrefetchingDayActivity: Bool { inflightTask != nil || activityTask != nil }

    // MARK: - 初始化

    init(
        apiClient: GitHubAPIClient,
        defaults: UserDefaults = .standard,
        cacheDirectory: URL = URL.cachesDirectory.appending(path: "com.starcat.app/contributions")
    ) {
        self.apiClient = apiClient
        self.defaults = defaults
        self.cacheDirectory = cacheDirectory
    }

    // MARK: - 公开 API

    /// 加载指定 login 的贡献草坪。
    ///
    /// - Parameters:
    ///   - login: GitHub 登录名（一般是当前登录用户）。
    ///   - force: 跳过概览的 TTL；明细保留仍匹配的历史数据。
    ///   - activityRange: 侧栏提供当前范围，登录或手动刷新时沿用服务内已有范围。
    ///
    /// 行为：
    /// 1. 若内存中无 payload，先尝试从磁盘 restore（秒显历史草坪）。
    /// 2. 若 !force && 缓存仍在 TTL 内 → 复用概览，仅补预拉明细。
    /// 3. 否则发 GraphQL 请求，成功后更新内存 + 磁盘。
    /// 4. 失败保留旧数据 + 设 `lastError`。
    func load(login: String, force: Bool = false, activityRange: ContributionGraphRange? = nil) {
        let login = login.lowercased()
        if activeLogin != login {
            reset(login: nil)
            activeLogin = login
            activityCache = .restore(from: activityFile(for: login))
            restoreFromDisk(login: login)
        }
        if let activityRange { self.activityRange = activityRange }
        guard inflightTask == nil else { return }

        if !force, let last = lastFetchedAt, Date().timeIntervalSince(last) < ttl {
            prefetchDayActivities()
            return
        }

        activityTask?.cancel()
        activityTask = nil
        isLoading = payload == nil

        inflightTask = Task { [weak self] in
            guard let self else { return }
            defer {
                // 账号已切换时，新任务接管状态；旧任务不得清掉其句柄或恢复预拉。
                if !Task.isCancelled {
                    self.isLoading = false
                    self.inflightTask = nil
                    self.prefetchDayActivities()
                }
            }
            do {
                let fetched = try await self.apiClient.contributionCalendar(login: login)
                try Task.checkCancellation()
                let fetchedAt = Date()
                self.payload = fetched
                self.lastFetchedAt = fetchedAt
                self.lastError = nil
                self.persistToDisk(DiskEnvelope(fetchedAt: fetchedAt.timeIntervalSince1970, payload: fetched), login: login)
                self.onPayloadDidChange?()
                AppLog.network.info("Contribution calendar fetched: login=\(login, privacy: .public), total=\(fetched.totalContributions, privacy: .public)")
            } catch is CancellationError {
                AppLog.network.info("Contribution fetch cancelled: login=\(login, privacy: .public)")
            } catch let err as LocalizedError {
                guard !Task.isCancelled else { return }
                self.lastError = err
                AppLog.network.error("Contribution fetch failed: \(err.localizedDescription, privacy: .public)")
            } catch {
                AppLog.network.error("Contribution fetch failed (unknown): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 悬停只读当前账号的内存计数，且必须与正在展示的草坪总数相符。
    func cachedDayActivity(login: String, day: ContributionDay) -> ContributionDayActivity? {
        guard activeLogin == login.lowercased(),
              let index = ContributionActivityCache.dayIndex(day.date) else { return nil }
        return activityCache.activity(on: index, matching: day.contributionCount)
    }

    /// 最近日期优先。后台任务每批读取最新显示范围，扩展范围时沿用已完成的数据。
    /// 明细与概览请求串行，刷新或切换账号会取消旧任务，避免旧快照的结果回写。
    private func prefetchDayActivities() {
        guard activityTask == nil, let login = activeLogin,
              let payload, let snapshotAt = lastFetchedAt?.timeIntervalSince1970 else { return }
        let datedDays = payload.days.sorted { $0.dayIndex > $1.dayIndex }
        guard let newest = datedDays.first, let oldest = datedDays.last else { return }
        let latestDay = Int(newest.dayIndex)
        let cacheStart = max(Int(oldest.dayIndex), firstDay(in: .year, endingAt: latestDay))
        let file = activityFile(for: login)
        var cache = activityCache
        cache.align(to: cacheStart...latestDay)

        let recentStart = latestDay - 2
        let refreshRecent = cache.recentSnapshotAt != snapshotAt
        let pending = datedDays.prefix { $0.dayIndex >= cacheStart }.filter { day in
            let index = Int(day.dayIndex)
            if day.contributionCount == 0 {
                cache[index] = .empty
                return false
            }
            if cache.activity(on: index, matching: day.contributionCount) == nil {
                cache[index] = nil
                return true
            }
            return refreshRecent && index >= recentStart
        }
        let recentPendingCount = pending.prefix { $0.dayIndex >= recentStart }.count
        if recentPendingCount == 0 { cache.recentSnapshotAt = snapshotAt }
        publishActivityCache(cache, to: file)
        guard let first = pending.first, first.dayIndex >= firstDay(in: activityRange, endingAt: latestDay) else { return }

        activityTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.activityTask = nil } }
            var remaining = pending[...]
            do {
                while !remaining.isEmpty {
                    let rangeStart = self.firstDay(in: self.activityRange, endingAt: latestDay)
                    let batch = remaining.prefix(GitHubAPIClient.contributionActivityBatchSize)
                        .prefix { $0.dayIndex >= rangeStart }
                    guard !batch.isEmpty else { break }
                    let dates = batch.map(\.date)
                    let activities = try await self.apiClient.contributionDayActivities(login: login, dates: dates)
                    try Task.checkCancellation()
                    var refreshedRecentCount = 0
                    for (day, date) in zip(batch, dates) {
                        guard let activity = activities[date],
                              activity.calendarCount == day.contributionCount else { continue }
                        cache[Int(day.dayIndex)] = activity
                        if day.dayIndex >= recentStart { refreshedRecentCount += 1 }
                    }
                    if remaining.startIndex == pending.startIndex, refreshedRecentCount == recentPendingCount {
                        cache.recentSnapshotAt = snapshotAt
                    }
                    self.publishActivityCache(cache, to: file)
                    remaining = remaining.dropFirst(batch.count)
                }
            } catch {
                // 失败停在当前批次，下次加载再补缺；保留已经写完的批次并避免限流时继续打请求。
                guard !Task.isCancelled else { return }
                AppLog.network.warning("Contribution activity prefetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func firstDay(in range: ContributionGraphRange, endingAt latestDay: Int) -> Int {
        latestDay - (range.dayCount ?? ContributionActivityCache.maximumDayCount) + 1
    }

    private func publishActivityCache(_ cache: ContributionActivityCache, to file: URL) {
        guard cache != activityCache else { return }
        activityCache = cache
        cache.save(to: file)
    }

    /// 清空内存数据（一般用于登出）。磁盘缓存按 login 分桶，登出时也清。
    func reset(login: String?) {
        inflightTask?.cancel()
        inflightTask = nil
        activityTask?.cancel()
        activityTask = nil
        activeLogin = nil
        payload = nil
        activityCache = ContributionActivityCache()
        activityRange = .recent90
        isLoading = false
        lastError = nil
        lastFetchedAt = nil
        if let login {
            defaults.removeObject(forKey: cacheKey(for: login))
            try? FileManager.default.removeItem(at: calendarFile(for: login))
            try? FileManager.default.removeItem(at: activityFile(for: login))
        }
    }

    // MARK: - 磁盘缓存

    private func cacheKey(for login: String) -> String {
        cacheKeyPrefix + login.lowercased()
    }

    private func activityFile(for login: String) -> URL {
        cacheDirectory.appending(component: "\(login.lowercased()).json.zlib")
    }

    private func calendarFile(for login: String) -> URL {
        cacheDirectory.appending(component: "\(login.lowercased()).calendar.cache")
    }

    /// 迁移沿用旧 envelope，原始拉取时间参与 TTL 和最近三天的明细匹配。
    private struct DiskEnvelope: Codable {
        let fetchedAt: TimeInterval
        let payload: ContributionCalendarPayload
    }

    private func persistToDisk(_ envelope: DiskEnvelope, login: String) {
        do {
            let data = try CacheJSONCodec.pack(JSONEncoder().encode(envelope))
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: calendarFile(for: login), options: .atomic)
            defaults.removeObject(forKey: cacheKey(for: login))
        } catch {
            AppLog.network.warning("Contribution persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restoreFromDisk(login: String) {
        let decoder = JSONDecoder()
        let key = cacheKey(for: login)
        let envelope: DiskEnvelope
        if let data = try? Data(contentsOf: calendarFile(for: login)),
           let current = try? decoder.decode(DiskEnvelope.self, from: CacheJSONCodec.unpack(data)) {
            envelope = current
            defaults.removeObject(forKey: key)
        } else if let data = defaults.data(forKey: key),
                  let legacy = try? decoder.decode(DiskEnvelope.self, from: CacheJSONCodec.unpack(data)) {
            envelope = legacy
            persistToDisk(legacy, login: login)
        } else {
            return
        }
        payload = envelope.payload
        lastFetchedAt = Date(timeIntervalSince1970: envelope.fetchedAt)
        onPayloadDidChange?()
        AppLog.network.debug("Contribution restored from disk: login=\(login, privacy: .public)")
    }
}
