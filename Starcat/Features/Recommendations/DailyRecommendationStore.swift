//
//  DailyRecommendationStore.swift
//  Starcat
//
//  所有主窗口共用的每日抽卡状态。网络、账号、持久化各自有身份边界，
//  迟到响应不写入新账户，关闭覆盖层不取消或丢弃已经翻开的卡片。
//

import Foundation
import Observation

/// 单一状态源：扇形牌堆、卡槽与重看入口只观察本对象，不另造展示批次。
@MainActor
@Observable
final class DailyRecommendationStore {
    private(set) var state = DailyRecommendationState()
    private(set) var accountID: Int64?
    private(set) var isLoading = false
    private(set) var errorKey: String?
    private(set) var emptyKey = "recommendations.daily.empty"
    private let disk: DailyRecommendationDiskStore
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var scopeRevision: UInt64?
    private var hasLoadedState = false

    init(disk: DailyRecommendationDiskStore = DailyRecommendationDiskStore()) {
        self.disk = disk
    }

    var visibleItems: [RepoRecommendationItem] {
        state.items.filter { !state.dismissedIDs.contains($0.repoID) }
    }

    var unrevealedItems: [RepoRecommendationItem] {
        visibleItems.filter { !state.revealedIDs.contains($0.repoID) }
    }

    /// 账号切换立即清内存，并使所有已启动任务失效；不等待网络回来才清旧卡。
    func activate(accountID: Int64?, scopeRevision: UInt64) {
        guard self.accountID != accountID || self.scopeRevision != scopeRevision else { return }
        generation &+= 1
        self.accountID = accountID
        self.scopeRevision = scopeRevision
        state = DailyRecommendationState()
        hasLoadedState = false
        isLoading = false
        errorKey = nil
    }

    /// 取最多 100 个既有后端候选，再在本地完整过滤并冻结最多 10 张。
    /// 不提供假换批：本轮 MVP 没有多仓 cursor，只有失败/空态重试。
    func load(
        accountID: Int64,
        scopeRevision: UInt64,
        date: Date = Date(),
        serviceScope: String,
        fetchStars: () async throws -> [Repo],
        fetchCandidates: ([Int64]) async throws -> DailyRecommendationResponse
    ) async {
        activate(accountID: accountID, scopeRevision: scopeRevision)
        guard !isLoading else { return }
        let token = generation
        let day = DailyRecommendationState.dayKey(date)
        isLoading = true
        errorKey = nil
        defer { if token == generation { isLoading = false } }
        do {
            if !hasLoadedState {
                let saved = try await disk.load(accountID: accountID)
                guard token == generation, !Task.isCancelled else { return }
                state = saved
                hasLoadedState = true
            }
            // 昨日快照不伪装成今日推荐；离线时错误态仍可保留上一批及其真实日期。
            let repos = try await fetchStars()
            guard token == generation, !Task.isCancelled else { return }
            let excluded = Set(repos.map(\.id)).union(state.dismissedIDs)
            if state.serviceScope != serviceScope {
                state.items = []
                state.revealedIDs = []
                // 服务作用域代表推荐语料身份；变化后当日旧批次也不能继续冒充新批次。
                state.modelVersion = ""
            }
            if state.day == day, state.serviceScope == serviceScope, !state.modelVersion.isEmpty {
                state.items.removeAll { excluded.contains($0.repoID) }
                await persist()
                return
            }
            let seeds = DailyRecommendationState.seeds(from: repos)
            guard !seeds.isEmpty else {
                emptyKey = "recommendations.daily.coldStart"
                state.items = []
                return
            }
            let result = try await fetchCandidates(seeds)
            guard token == generation, !Task.isCancelled else { return }
            let items = DailyRecommendationState.candidates(result.items, excluding: excluded)
            state.day = day
            state.serviceScope = serviceScope
            state.modelVersion = result.modelVersion
            state.generatedAt = date
            state.items = items
            state.revealedIDs = []
            emptyKey = "recommendations.daily.empty"
            await persist()
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            errorKey = "recommendations.daily.failed"
        }
    }

    /// 只在覆盖层成功呈现后消费当日自动展示资格。
    func canAutomaticallyPresent(date: Date = Date()) -> Bool {
        let day = DailyRecommendationState.dayKey(date)
        return hasLoadedState && state.showsOnLaunch && state.day == day
            && !visibleItems.isEmpty && state.autoPresentedDay != day
    }

    func claimAutomaticPresentation(date: Date = Date()) async -> Bool {
        let day = DailyRecommendationState.dayKey(date)
        guard canAutomaticallyPresent(date: date) else { return false }
        state.autoPresentedDay = day
        await persist()
        return true
    }

    /// 翻开仅改变查看进度，不执行远程写入。
    func reveal(_ id: Int64) async {
        guard visibleItems.contains(where: { $0.repoID == id }) else { return }
        state.revealedIDs.insert(id)
        await persist()
    }

    func revealAll() async {
        state.revealedIDs.formUnion(visibleItems.map(\.repoID))
        await persist()
    }

    func dismiss(_ id: Int64) async {
        state.dismissedIDs.insert(id)
        await persist()
    }

    func setShowsOnLaunch(_ enabled: Bool) async {
        state.showsOnLaunch = enabled
        await persist()
    }

    /// 现存批次中的已 Star 卡片移除，不自动换入新项目扰动卡槽顺序。
    func excludeStarred(_ ids: Set<Int64>) async {
        guard state.items.contains(where: { ids.contains($0.repoID) }) else { return }
        state.items.removeAll { ids.contains($0.repoID) }
        await persist()
    }

    private func persist() async {
        guard let accountID, hasLoadedState else { return }
        revision &+= 1
        let token = generation
        do {
            try await disk.save(state, accountID: accountID, revision: revision)
        } catch {
            if token == generation { errorKey = "recommendations.daily.saveFailed" }
        }
    }
}
