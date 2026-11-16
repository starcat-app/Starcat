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
    /// 换批未找到新项目时保留原牌，用独立提示区说明原因，不把有效卡片切成空态。
    private(set) var batchMessageKey: String?
    private(set) var emptyKey = "recommendations.daily.empty"
    private let disk: DailyRecommendationDiskStore
    private let history: RecommendationHistoryRepository
    /// 卡片与历史列表共用同一份账号快照；Star 始终从注册表派生。
    private(set) var historyEntries: [RecommendationHistoryEntry] = []
    private var pendingHistory: [Int64: RecommendationHistoryEntry] = [:]
    private var pendingFeedback: [Int64: Bool] = [:]
    /// 连续点击和多个窗口可能同时保存；串行写入，避免旧反馈在较新操作之后落库。
    private var persistenceTask: Task<Bool, Never>?
    private var generation: UInt64 = 0
    private var revision: UInt64 = 0
    private var scopeRevision: UInt64?
    /// 偏好读盘完成即可编辑开关，不必等待推荐网络请求完成
    private(set) var hasLoadedState = false
    /// 重试延续失败操作；重开入口始终恢复当前批次，不顺带执行上次失败的换批。
    private(set) var retryReplacesCurrentBatch = false
    /// 冷启动先于首次 Stars 同步时没有公开种子；只在同步成功收尾后补试，不按分页触发。
    private(set) var needsInitialStars = false
    /// 完整数据库快照之外，合并请求等待期间注册表收到的新 Star，防止迟到候选重新露出。
    private var observedStarredIDs: Set<Int64> = []

    init(disk: DailyRecommendationDiskStore = DailyRecommendationDiskStore(), history: RecommendationHistoryRepository) {
        self.disk = disk
        self.history = history
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
        historyEntries = []
        pendingHistory = [:]
        pendingFeedback = [:]
        hasLoadedState = false
        isLoading = false
        errorKey = nil
        batchMessageKey = nil
        emptyKey = "recommendations.daily.empty"
        retryReplacesCurrentBatch = false
        needsInitialStars = false
        observedStarredIDs = []
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
            // 历史是持久化真值；批次 JSON 可以独立恢复，不能被当成历史读取的前置条件。
            let entries = try await history.fetchAll(accountID: accountID)
            guard token == generation, !Task.isCancelled else { return false }
            let saved = try await disk.load(accountID: accountID)
            guard token == generation, !Task.isCancelled else { return false }
            if !hasLoadedState {
                state = saved
                historyEntries = entries
                updateHistoryProjection()
                hasLoadedState = true
                await excludeStarred(observedStarredIDs)
            }
            return true
        } catch {
            if token == generation, !Task.isCancelled { errorKey = "recommendations.daily.failed" }
            return false
        }
    }

    /// 从跨天候选池选出未推荐项目，不足时在请求预算内补页，再冻结当天最多 10 张
    /// 推荐历史仅参与新批次筛选；当天重看只排除已 Star 和不感兴趣，不能清空自己的牌
    /// 主动换批在找到新项目后才替换快照；失败和耗尽都保留上一批及翻牌进度。
    @discardableResult
    func load(
        accountID: Int64,
        scopeRevision: UInt64,
        date: Date = Date(),
        serviceScope: String,
        replacingCurrentBatch: Bool = false,
        fetchStars: () async throws -> [Repo],
        fetchCandidates: ([Int64], String?) async throws -> DailyRecommendationResponse,
        prepareItems: ([RepoRecommendationItem]) async -> Void = { _ in }
    ) async -> Bool {
        activate(accountID: accountID, scopeRevision: scopeRevision)
        guard !isLoading, !Task.isCancelled else { return false }
        let token = generation
        let day = DailyRecommendationState.dayKey(date)
        isLoading = true
        errorKey = nil
        batchMessageKey = nil
        retryReplacesCurrentBatch = replacingCurrentBatch
        needsInitialStars = false
        defer { if token == generation { isLoading = false } }
        guard await loadPreferences(accountID: accountID, scopeRevision: scopeRevision) else { return false }
        // 候选池留在 catch 可见的作用域，后续页失败也能保存前面已成功取得的位置。
        var pool = state.candidatePool
        do {
            // 昨日快照不伪装成今日推荐；离线时错误态仍可保留上一批及其真实日期。
            let repos = try await fetchStars()
            guard token == generation, !Task.isCancelled else { return false }
            let starred = Set(repos.map(\.id))
            await excludeStarred(starred.union(observedStarredIDs))
            guard token == generation, !Task.isCancelled else { return false }
            let excluded = starred.union(observedStarredIDs).union(state.dismissedIDs)
            // 先过滤可读旧卡，再请求新数据；离线回退也不能显示刚 Star 的项目。
            state.items.removeAll { excluded.contains($0.repoID) }
            // 即使原批次尚未登记展示历史，主动换批也不能把同一组项目重新排列后交回去。
            let replacingIDs: Set<Int64> = replacingCurrentBatch ? Set(state.items.map(\.repoID)) : []
            if state.serviceScope != serviceScope, !replacingCurrentBatch {
                state.items = []
                state.hasGeneratedBatch = false
                state.revealedIDs = []
                // 服务作用域代表推荐语料身份；变化后当日旧批次也不能继续冒充新批次。
                state.modelVersion = ""
            }
            if !replacingCurrentBatch, state.day == day, state.serviceScope == serviceScope, !state.modelVersion.isEmpty,
               state.hasGeneratedBatch || state.candidatePool?.hasMore != true {
                if state.items.isEmpty { emptyKey = "recommendations.daily.noNew" }
                // 重开也要恢复整批理由；尚未完成准备的磁盘快照不能直接触发展示。
                await prepareItems(visibleItems)
                guard token == generation, !Task.isCancelled else { return false }
                await persist()
                return token == generation && !Task.isCancelled
            }
            let seeds = DailyRecommendationState.seeds(from: repos).sorted()
            guard !seeds.isEmpty else {
                emptyKey = "recommendations.daily.coldStart"
                if replacingCurrentBatch {
                    batchMessageKey = emptyKey
                } else {
                    needsInitialStars = true
                    state.items = []
                    state.hasGeneratedBatch = false
                    state.revealedIDs = []
                    state.candidatePool = nil
                    await persist()
                }
                return false
            }
            if pool?.seedIDs != seeds || pool?.serviceScope != serviceScope { pool = nil }
            var requests = 0
            while requests < Self.pageBudget {
                let needsProbe = pool == nil || pool?.checkedDay != day
                let exclusions = starred.union(observedStarredIDs).union(state.dismissedIDs)
                    .union(state.recommendedIDs).union(replacingIDs)
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
                        guard token == generation, !Task.isCancelled else { return false }
                        pool = nil
                        continue
                    }
                    throw error
                }
                guard token == generation, !Task.isCancelled else { return false }
                // 只展示当前正向公开 Stars 中真实命中的来源；保留本地名称快照而非推测种子关系。
                let sourceRepos = Dictionary(repos.filter { seeds.contains($0.id) }.map { ($0.id, $0) },
                                             uniquingKeysWith: { first, _ in first })
                let pageItems = page.items.map { item in
                    var copy = item
                    var seen = Set<Int64>()
                    copy.matchedSeeds = item.matchedSeeds?.compactMap { seed in
                        guard let repo = sourceRepos[seed.repoID], seen.insert(seed.repoID).inserted else { return nil }
                        return RecommendationSeed(repoID: seed.repoID, fullName: repo.fullName,
                                                  description: repo.description, language: repo.language,
                                                  reasons: seed.reasons)
                    }.prefix(3).map { $0 }
                    return copy
                }
                // 只探测第一页确认当天活动模型；版本不变时保留已推进的位置，不能每天回到前 100 条
                if cursor == nil, var current = pool, current.modelVersion == page.modelVersion {
                    current.items = pageItems + current.items
                    current.checkedDay = day
                    pool = current
                } else if cursor == nil {
                    pool = DailyRecommendationCandidatePool(
                        seedIDs: seeds, serviceScope: serviceScope, modelVersion: page.modelVersion,
                        checkedDay: day, items: pageItems, hasMore: page.hasMore, nextCursor: page.nextCursor
                    )
                } else {
                    guard pool?.modelVersion == page.modelVersion else { pool = nil; continue }
                    pool?.items.append(contentsOf: pageItems)
                    pool?.hasMore = page.hasMore
                    pool?.nextCursor = page.nextCursor
                }
                // 等待网络期间用户仍可屏蔽项目或修改偏好，筛选必须读取当前内存中的反馈和历史
                let remaining = DailyRecommendationState.candidates(
                    pool?.items ?? [],
                    excluding: starred.union(observedStarredIDs).union(state.dismissedIDs)
                        .union(state.recommendedIDs).union(replacingIDs), limit: .max
                )
                pool?.items = remaining
            }
            guard let pool else {
                throw StarcatEnvelopeNetworkError.serverError(status: 409, code: "CURSOR_EXPIRED", message: "Recommendation model changed")
            }
            let items = DailyRecommendationState.candidates(
                pool.items, excluding: starred.union(observedStarredIDs).union(state.dismissedIDs)
                    .union(state.recommendedIDs).union(replacingIDs)
            )
            state.candidatePool = pool
            emptyKey = pool.hasMore ? "recommendations.daily.continueSearch" : "recommendations.daily.noNew"
            if replacingCurrentBatch, items.isEmpty {
                // 保留已推进的 cursor，重试能继续；原批次的日期、模型与揭示状态保持一致。
                batchMessageKey = emptyKey
                await persist()
                return false
            }
            // 保留上一批至新批理由生成并保存（或明确兜底）完成，网页不会先露出没有理由的新卡。
            await prepareItems(items)
            guard token == generation, !Task.isCancelled else { return false }
            state.day = day
            state.serviceScope = serviceScope
            state.modelVersion = pool.modelVersion
            state.generatedAt = date
            // LLM 等待期间的新 Star / 负反馈仍然生效；不从候选池补入尚未准备理由的项目。
            state.items = items.filter { !observedStarredIDs.contains($0.repoID) && !state.dismissedIDs.contains($0.repoID) }
            state.hasGeneratedBatch = !state.items.isEmpty
            state.revealedIDs = []
            await persist()
            return token == generation && !Task.isCancelled
        } catch {
            guard token == generation, !Task.isCancelled else { return false }
            state.candidatePool = pool
            errorKey = "recommendations.daily.failed"
            await persist()
            return false
        }
    }

    /// 真实覆盖层成功呈现后才登记整批项目，预取或失败请求不消耗推荐历史
    /// 同一天重开只更新进度，不反复写同一批历史；模型和候选缓存变化都不清空此记录
    func markPresented(date: Date = Date()) async {
        guard accountID != nil, hasLoadedState, !visibleItems.isEmpty else { return }
        let day = DailyRecommendationState.dayKey(date)
        var changed = recordHistory(visibleItems, date: date)
        // 手动入口已让用户看到今日批次，随后启用开关或回到前台也不应再次自动打扰。
        // 昨日离线缓存不消费今日资格，仍按快照真实日期处理。
        if state.day == day, state.autoPresentedDay != day {
            state.autoPresentedDay = day
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
        guard hasLoadedState, !observedStarredIDs.contains(id),
              historyEntries.contains(where: { $0.id == id }) || visibleItems.contains(where: { $0.repoID == id }) else { return }
        // 用户能操作这张卡就已实际看到它；即使页面的 presented 回调尚在排队也不能丢反馈。
        if let item = visibleItems.first(where: { $0.repoID == id }) { _ = recordHistory([item], date: Date()) }
        state.dismissedIDs.insert(id)
        pendingFeedback[id] = true
        updateFeedback(id: id, dismissed: true)
        await persist()
    }

    /// 撤销负反馈不会删除历史，后续新批次仍按完整历史去重。
    func restoreInterest(_ id: Int64) async {
        guard hasLoadedState, state.dismissedIDs.contains(id) else { return }
        state.dismissedIDs.remove(id)
        pendingFeedback[id] = false
        updateFeedback(id: id, dismissed: false)
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
        observedStarredIDs = ids
        guard hasLoadedState else { return }
        let cleared = state.dismissedIDs.intersection(ids)
        for id in cleared {
            state.dismissedIDs.remove(id)
            pendingFeedback[id] = false
            updateFeedback(id: id, dismissed: false)
        }
        guard !cleared.isEmpty || state.items.contains(where: { ids.contains($0.repoID) }) else { return }
        state.items.removeAll { ids.contains($0.repoID) }
        await persist()
    }

    /// 重试内存中的最新选择，不读盘回滚反馈，也不为保存失败重新请求推荐。
    func retrySaving() async {
        await persist()
    }

    /// 恢复出厂先使内存意图失效，再排空串行写队列；必须在账号数据库关闭前执行。
    /// 调用方同时暂停准备任务，防止文件删除后被旧批次或反馈写回。
    func clearForFactoryReset(accountID: Int64) async throws {
        if self.accountID == accountID { activate(accountID: nil, scopeRevision: scopeRevision ?? 0) }
        _ = await persistenceTask?.value
        try await disk.remove(accountID: accountID)
    }

    private func persist() async {
        guard let accountID, hasLoadedState else { return }
        revision &+= 1
        let writeRevision = revision
        let token = generation
        let snapshot = state
        let records = Array(pendingHistory.values)
        let feedback = pendingFeedback
        let previous = persistenceTask
        let history = self.history
        let disk = self.disk
        let task = Task { @MainActor in
            _ = await previous?.value
            do {
                // 历史先提交，JSON 才能省去历史字段；失败保留内存意图供 retrySaving 重试。
                for entry in records {
                    if let item = entry.item, let date = entry.recommendedAt, let day = entry.recommendedDay {
                        try await history.record([item], day: day, date: date, batchID: entry.batchID ?? "", accountID: accountID)
                    }
                }
                for (id, dismissed) in feedback {
                    try await history.setDismissed(dismissed, id: id, accountID: accountID)
                }
                try await disk.save(snapshot, accountID: accountID, revision: writeRevision)
                return true
            } catch {
                return false
            }
        }
        persistenceTask = task
        let saved = await task.value
        guard token == generation, writeRevision == revision else { return }
        if saved {
            pendingHistory = [:]
            pendingFeedback = [:]
            if errorKey == "recommendations.daily.saveFailed" { errorKey = nil }
        } else {
            errorKey = "recommendations.daily.saveFailed"
        }
    }

    /// 第一次真实展示的时间冻结；旧记录未知的时间保持未知。
    @discardableResult
    private func recordHistory(_ items: [RepoRecommendationItem], date: Date) -> Bool {
        let existing = Set(historyEntries.map(\.id))
        let entries = items.filter { !existing.contains($0.repoID) }.map {
            RecommendationHistoryEntry(id: $0.repoID, item: $0, recommendedAt: date,
                                       recommendedDay: DailyRecommendationState.dayKey(date),
                                       batchID: "\(state.day)|\(state.modelVersion)|\(state.generatedAt?.timeIntervalSince1970 ?? 0)",
                                       isDismissed: false)
        }
        for entry in entries { pendingHistory[entry.id] = entry }
        historyEntries.append(contentsOf: entries)
        // 同一批展示时间相同，按 ID 稳定倒序，与重新读库后的顺序一致。
        historyEntries.sort {
            let leftDay = RecommendationHistoryRepository.sortDay($0.recommendedDay)
            let rightDay = RecommendationHistoryRepository.sortDay($1.recommendedDay)
            if leftDay != rightDay { return leftDay > rightDay }
            if $0.recommendedAt != $1.recommendedAt {
                return ($0.recommendedAt ?? .distantPast) > ($1.recommendedAt ?? .distantPast)
            }
            return $0.id > $1.id
        }
        updateHistoryProjection()
        return !entries.isEmpty
    }

    private func updateHistoryProjection() {
        state.recommendedDays = Dictionary(uniqueKeysWithValues: historyEntries.map { (String($0.id), $0.recommendedDay ?? "") })
        state.dismissedIDs = Set(historyEntries.filter(\.isDismissed).map(\.id))
    }

    private func updateFeedback(id: Int64, dismissed: Bool) {
        guard let index = historyEntries.firstIndex(where: { $0.id == id }) else { return }
        let entry = historyEntries[index]
        historyEntries[index] = RecommendationHistoryEntry(
            id: entry.id, item: entry.item, recommendedAt: entry.recommendedAt,
            recommendedDay: entry.recommendedDay, batchID: entry.batchID, isDismissed: dismissed
        )
    }
}
