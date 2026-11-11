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
    /// 一次准备最多读取三页；整页被本地过滤后可由下次重试继续，不在启动时无限补页
    private static let pageBudget = 3
    private(set) var state = DailyRecommendationState()
    private(set) var accountID: Int64?
    private(set) var isLoading = false
    private(set) var errorKey: String?
    private(set) var emptyKey = "recommendations.daily.empty"
    private let disk: DailyRecommendationDiskStore
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var scopeRevision: UInt64?
    /// 偏好读盘完成即可编辑开关，不必等待推荐网络请求完成
    private(set) var hasLoadedState = false

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

    /// 设置页只读取账号文件，不取 Stars 或推荐候选；两处开关继续共享原有快照
    /// 主窗口与设置页可能同时读盘，后返回的旧快照不能覆盖先完成读取后产生的用户修改
    @discardableResult
    func loadPreferences(accountID: Int64, scopeRevision: UInt64) async -> Bool {
        guard !Task.isCancelled else { return false }
        activate(accountID: accountID, scopeRevision: scopeRevision)
        guard !hasLoadedState else { return true }
        let token = generation
        errorKey = nil
        do {
            let saved = try await disk.load(accountID: accountID)
            guard token == generation, !Task.isCancelled else { return false }
            if !hasLoadedState {
                state = saved
                hasLoadedState = true
            }
            return true
        } catch {
            if token == generation, !Task.isCancelled { errorKey = "recommendations.daily.failed" }
            return false
        }
    }

    /// 从跨天候选池选出未推荐项目，不足时在请求预算内补页，再冻结当天最多 10 张
    /// 推荐历史仅参与新批次筛选；当天重看只排除已 Star 和不感兴趣，不能清空自己的牌
    func load(
        accountID: Int64,
        scopeRevision: UInt64,
        date: Date = Date(),
        serviceScope: String,
        fetchStars: () async throws -> [Repo],
        fetchCandidates: ([Int64], String?) async throws -> DailyRecommendationResponse
    ) async {
        activate(accountID: accountID, scopeRevision: scopeRevision)
        guard !isLoading else { return }
        let token = generation
        let day = DailyRecommendationState.dayKey(date)
        isLoading = true
        errorKey = nil
        defer { if token == generation { isLoading = false } }
        guard await loadPreferences(accountID: accountID, scopeRevision: scopeRevision) else { return }
        do {
            // 昨日快照不伪装成今日推荐；离线时错误态仍可保留上一批及其真实日期。
            let repos = try await fetchStars()
            guard token == generation, !Task.isCancelled else { return }
            let starred = Set(repos.map(\.id))
            let excluded = starred.union(state.dismissedIDs)
            if state.serviceScope != serviceScope {
                state.items = []
                state.revealedIDs = []
                // 服务作用域代表推荐语料身份；变化后当日旧批次也不能继续冒充新批次。
                state.modelVersion = ""
            }
            if state.day == day, state.serviceScope == serviceScope, !state.modelVersion.isEmpty,
               !state.items.isEmpty || state.candidatePool?.hasMore != true {
                state.items.removeAll { excluded.contains($0.repoID) }
                if state.items.isEmpty { emptyKey = "recommendations.daily.noNew" }
                await persist()
                return
            }
            let seeds = DailyRecommendationState.seeds(from: repos).sorted()
            guard !seeds.isEmpty else {
                emptyKey = "recommendations.daily.coldStart"
                state.items = []
                return
            }
            var pool = state.candidatePool
            if pool?.seedIDs != seeds || pool?.serviceScope != serviceScope { pool = nil }
            var requests = 0
            while requests < Self.pageBudget {
                let needsProbe = pool == nil || pool?.checkedDay != day
                let exclusions = starred.union(state.dismissedIDs).union(state.recommendedIDs)
                if let current = pool, !needsProbe {
                    pool?.items = DailyRecommendationState.candidates(current.items, excluding: exclusions, limit: .max)
                    if (pool?.items.count ?? 0) >= 10 || !current.hasMore { break }
                }
                let cursor = needsProbe ? nil : pool?.nextCursor
                requests += 1
                let page: DailyRecommendationResponse
                do {
                    page = try await fetchCandidates(seeds, cursor)
                } catch let error as StarcatEnvelopeNetworkError {
                    if case .serverError(_, let code, _) = error, code == "CURSOR_EXPIRED", cursor != nil {
                        guard token == generation, !Task.isCancelled else { return }
                        pool = nil
                        continue
                    }
                    throw error
                }
                guard token == generation, !Task.isCancelled else { return }
                // 只探测第一页确认当天活动模型；版本不变时保留已推进的位置，不能每天回到前 100 条
                if cursor == nil, var current = pool, current.modelVersion == page.modelVersion {
                    current.items = page.items + current.items
                    current.checkedDay = day
                    pool = current
                } else if cursor == nil {
                    pool = DailyRecommendationCandidatePool(
                        seedIDs: seeds, serviceScope: serviceScope, modelVersion: page.modelVersion,
                        checkedDay: day, items: page.items, hasMore: page.hasMore, nextCursor: page.nextCursor
                    )
                } else {
                    guard pool?.modelVersion == page.modelVersion else { pool = nil; continue }
                    pool?.items.append(contentsOf: page.items)
                    pool?.hasMore = page.hasMore
                    pool?.nextCursor = page.nextCursor
                }
                // 等待网络期间用户仍可屏蔽项目或修改偏好，筛选必须读取当前内存中的反馈和历史
                let remaining = DailyRecommendationState.candidates(
                    pool?.items ?? [],
                    excluding: starred.union(state.dismissedIDs).union(state.recommendedIDs), limit: .max
                )
                pool?.items = remaining
            }
            guard let pool else {
                throw StarcatEnvelopeNetworkError.serverError(status: 409, code: "CURSOR_EXPIRED", message: "Recommendation model changed")
            }
            let items = DailyRecommendationState.candidates(
                pool.items, excluding: starred.union(state.dismissedIDs).union(state.recommendedIDs)
            )
            state.day = day
            state.serviceScope = serviceScope
            state.modelVersion = pool.modelVersion
            state.generatedAt = date
            state.items = items
            state.revealedIDs = []
            state.candidatePool = pool
            emptyKey = pool.hasMore ? "recommendations.daily.continueSearch" : "recommendations.daily.noNew"
            await persist()
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            errorKey = "recommendations.daily.failed"
        }
    }

    /// 真实覆盖层成功呈现后才登记整批项目，预取或失败请求不消耗推荐历史
    /// 同一天重开只更新进度，不反复写同一批历史；模型和候选缓存变化都不清空此记录
    func markPresented(date: Date = Date()) async {
        guard accountID != nil, hasLoadedState, !visibleItems.isEmpty else { return }
        let day = DailyRecommendationState.dayKey(date)
        var changed = false
        for item in visibleItems where state.recommendedDays[String(item.repoID)] != day {
            state.recommendedDays[String(item.repoID)] = day
            changed = true
        }
        if changed { await persist() }
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
        // 读盘前的默认值不能覆盖账号文件中的屏蔽反馈与翻牌记录
        guard accountID != nil, hasLoadedState else { return }
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
