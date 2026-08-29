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
//                          │  cache (内存 + UserDefaults 持久化)
//                          ▼
//                   GitHubAPIClient.graphql
//
//  缓存策略：
//  - **内存**：service 实例持有最新一份 `payload`；@Observable 让 SidebarView 自动重渲染。
//  - **磁盘**（UserDefaults）：把 payload + 时间戳序列化为 JSON。下次启动先 `restore()`
//    秒显（避免冷启动空白），再异步触发后台刷新。
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

    /// 缓存 key 前缀；按 login 分桶（同一台机器可能切换账号登录）。
    private let cacheKeyPrefix = "contribution.calendar."

    /// TTL：3 小时（与 GitHub 草坪刷新粒度同量级，避免无意义高频请求）。
    private let ttl: TimeInterval = 3 * 60 * 60

    /// 当前进行中的 Task；同 login 重复 load 时直接 await 已在飞的请求。
    private var inflightTask: Task<Void, Never>?

    // MARK: - 初始化

    init(apiClient: GitHubAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - 公开 API

    /// 加载指定 login 的贡献草坪。
    ///
    /// - Parameters:
    ///   - login: GitHub 登录名（一般是当前登录用户）。
    ///   - force: true = 跳过 TTL 强制刷新（用户点刷新按钮）；false = 命中 TTL 直接复用缓存。
    ///
    /// 行为：
    /// 1. 若内存中无 payload，先尝试从磁盘 restore（秒显历史草坪）。
    /// 2. 若 !force && 缓存仍在 TTL 内 → 直接返回不发请求。
    /// 3. 否则发 GraphQL 请求，成功后更新内存 + 磁盘。
    /// 4. 失败保留旧数据 + 设 `lastError`。
    func load(login: String, force: Bool = false) {
        // 先尝试磁盘恢复（首次调用时把上次成功的 payload 秒显出来）
        if payload == nil {
            restoreFromDisk(login: login)
        }

        // TTL 命中且非强制 → 直接 no-op
        if !force, let last = lastFetchedAt, Date().timeIntervalSince(last) < ttl {
            return
        }

        // 已有 inflight 任务 → 不重复发起
        if inflightTask != nil { return }

        // 仅在没有缓存时显示 loading，避免后台刷新闪烁
        if payload == nil {
            isLoading = true
        }

        inflightTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoading = false
                self.inflightTask = nil
            }
            do {
                let fetched = try await self.apiClient.contributionCalendar(login: login)
                self.payload = fetched
                self.lastFetchedAt = Date()
                self.lastError = nil
                self.persistToDisk(login: login, payload: fetched, fetchedAt: Date())
                self.onPayloadDidChange?()
                AppLog.network.info("Contribution calendar fetched: login=\(login, privacy: .public), total=\(fetched.totalContributions, privacy: .public)")
            } catch is CancellationError {
                AppLog.network.info("Contribution fetch cancelled: login=\(login, privacy: .public)")
            } catch let err as LocalizedError {
                self.lastError = err
                AppLog.network.error("Contribution fetch failed: \(err.localizedDescription, privacy: .public)")
            } catch {
                AppLog.network.error("Contribution fetch failed (unknown): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 清空内存数据（一般用于登出）。磁盘缓存按 login 分桶，登出时也清。
    func reset(login: String?) {
        inflightTask?.cancel()
        inflightTask = nil
        payload = nil
        isLoading = false
        lastError = nil
        lastFetchedAt = nil
        if let login {
            UserDefaults.standard.removeObject(forKey: cacheKey(for: login))
        }
    }

    // MARK: - 磁盘缓存

    private func cacheKey(for login: String) -> String {
        cacheKeyPrefix + login.lowercased()
    }

    /// 落盘格式：`{ "fetchedAt": <epoch>, "payload": <jsonEncoded ContributionCalendarPayload> }`。
    /// 用 JSONEncoder 而非 PropertyListEncoder，统一文本调试可读。
    private struct DiskEnvelope: Codable {
        let fetchedAt: TimeInterval
        let payload: ContributionCalendarPayload
    }

    private func persistToDisk(login: String, payload: ContributionCalendarPayload, fetchedAt: Date) {
        let envelope = DiskEnvelope(fetchedAt: fetchedAt.timeIntervalSince1970, payload: payload)
        do {
            let data = try JSONEncoder().encode(envelope)
            UserDefaults.standard.set(data, forKey: cacheKey(for: login))
        } catch {
            AppLog.network.warning("Contribution persist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restoreFromDisk(login: String) {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(for: login)) else { return }
        do {
            let envelope = try JSONDecoder().decode(DiskEnvelope.self, from: data)
            self.payload = envelope.payload
            self.lastFetchedAt = Date(timeIntervalSince1970: envelope.fetchedAt)
            self.onPayloadDidChange?()
            AppLog.network.debug("Contribution restored from disk: login=\(login, privacy: .public)")
        } catch {
            // 解码失败（schema 演进 / 损坏）→ 清掉脏数据
            UserDefaults.standard.removeObject(forKey: cacheKey(for: login))
            AppLog.network.warning("Contribution disk decode failed, dropping cache: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// 注：Encodable conformance 已在 ContributionsAPI.swift 中声明（合成必须与类型同源文件）。
