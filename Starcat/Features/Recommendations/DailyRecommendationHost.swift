//
//  DailyRecommendationHost.swift
//  Starcat
//
//  主窗口集成层：账号/数据库就绪后准备每日批次，自动入口不阻塞登录、
//  首次引导和其它 Sheet；固定入口可显式重试，不靠假数据填充空卡片。
//

import SwiftUI
import AppKit
import Combine

/// 宿主只编排依赖和呈现；关闭或从详情返回时，批次由 AppDependencies 继续持有。
struct DailyRecommendationHost: ViewModifier {
    @Binding var isPresented: Bool
    let onOpen: (Repo) -> Void
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.locale) private var locale
    @Environment(\.firstRunOnboardingActive) private var onboarding
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var preparedIdentity: String?
    @State private var preparationRevision: UInt64 = 0
    @State private var syncCompletionTask: Task<Void, Never>?
    @State private var isParentWindowReady = false
    @State private var isOverlayWindowReady = false
    @State private var isCardContentReady = false
    /// 外部 Binding 是“请求打开”，只有批次理由已保存或明确兜底才真正创建推荐窗口。
    @State private var isReadyToPresent = false

    private var accountID: Int64? {
        guard let id = authSession.state.user?.id, dependencies.database.currentUserId == id else { return nil }
        return id
    }

    private var accountIdentity: String { "\(accountID ?? 0)|\(dependencies.databaseScopeRevision)" }
    private var identity: String {
        "\(accountIdentity)|\(DailyRecommendationState.dayKey(Date()))|\(onboarding)|\(locale.identifier)|\(dependencies.entitlementGate.isProUser)"
    }
    private var isOverlayPresented: Bool { isPresented && isReadyToPresent }

    func body(content: Content) -> some View {
        content.disabled(isOverlayPresented).accessibilityHidden(isOverlayPresented).background {
            DailyRecommendationOverlay(
                isPresented: isOverlayPresented,
                onClose: { isPresented = false },
                onPresentationChanged: {
                    isOverlayWindowReady = $0
                    if !$0 { isCardContentReady = false }
                },
                onParentWindowReady: { isParentWindowReady = $0 }
            ) {
                DailyRecommendationCardsView(
                    store: dependencies.dailyRecommendationStore,
                    onClose: { isPresented = false },
                    onOpen: onOpen,
                    onRetry: retry,
                    onNextBatch: { await prepare(replacingCurrentBatch: true, origin: .user) },
                    onPresented: {
                        isCardContentReady = true
                        recordPresentation()
                    }
                )
                .environment(dependencies)
                .environment(AppSettings.shared)
                .environment(\.starcatReduceMotion, reduceMotion)
                .environment(\.starcatInterfaceScale, interfaceScale)
                .environment(\.colorScheme, colorScheme)
            }
            .frame(width: 0, height: 0)
        }
        .task(id: "\(identity)|\(preparationRevision)") {
            guard !TestEnvironment.isRunning else { return }
            preparedIdentity = nil
            dependencies.dailyRecommendationStore.activate(
                accountID: accountID, scopeRevision: dependencies.databaseScopeRevision
            )
            if accountID == nil || onboarding { isPresented = false }
            // 日切和回到前台只准备下一次进入；用户正在看牌时不关闭舞台或替换其进度。
            guard accountID != nil, !onboarding, !isPresented else { return }
            let attempt = identity
            guard await prepare(replacingCurrentBatch: false),
                  !Task.isCancelled, identity == attempt else { return }
            preparedIdentity = attempt
            presentAutomaticallyIfReady()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
                .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
                .merge(with: NotificationCenter.default.publisher(for: .NSSystemClockDidChange))
                .merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
        ) { _ in
            // 和侧栏日期计数使用同一组通知，覆盖常驻跨零点、修改时区与休眠后恢复。
            preparationRevision &+= 1
        }
        .onChange(of: accountIdentity) { _, _ in
            syncCompletionTask?.cancel()
            dependencies.dailyRecommendationPreparation.cancel()
            isPresented = false
            isReadyToPresent = false
            preparedIdentity = nil
            isCardContentReady = false
        }
        .onChange(of: isParentWindowReady) { _, ready in
            if ready { presentAutomaticallyIfReady() }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                dependencies.dailyRecommendationPreparation.cancelUserPreparation()
                isReadyToPresent = false
                preparedIdentity = nil
                isCardContentReady = false
            }
        }
        .onChange(of: isOverlayWindowReady) { _, ready in
            if ready { recordPresentation() }
        }
        .onChange(of: dependencies.dailyRecommendationStore.state.items.map(\.repoID)) { _, _ in
            // 新批次和 Star/屏蔽后的下一张都要等待网页首帧，空白页不能消耗每日资格。
            isCardContentReady = false
        }
        .task(id: "\(isPresented)|\(identity)") {
            guard isPresented, !isReadyToPresent else { return }
            await load()
            guard !Task.isCancelled, isPresented else { return }
            // 包括取数失败和未登录的原有空态；LLM 失败本身不会让 prepare 失败。
            isReadyToPresent = true
        }
        .onDisappear {
            syncCompletionTask?.cancel()
            dependencies.dailyRecommendationPreparation.cancel()
        }
        .onChange(of: dependencies.syncManager.state) { _, state in
            // 只消费最终完成边沿，不能在第一页写入时使用不完整 Stars 兴趣快照。
            guard case .completed = state, !TestEnvironment.isRunning else { return }
            prepareAfterInitialStarsSync()
        }
        .onChange(of: dependencies.starredRegistry.ids) { _, ids in
            let account = accountIdentity
            Task {
                guard accountIdentity == account else { return }
                await dependencies.dailyRecommendationStore.excludeStarred(ids)
            }
        }
    }

    /// 每次请求先固定账号和服务作用域；账号切换会让 Store 的 generation 失效。
    private func load() async {
        _ = await prepare(replacingCurrentBatch: false, origin: .user)
    }

    /// 无有效种子的准备允许在首次同步后补试；已冻结或单纯网络失败的批次不自动换牌。
    private func prepareAfterInitialStarsSync() {
        let attempt = identity
        syncCompletionTask?.cancel()
        syncCompletionTask = Task {
            await dependencies.dailyRecommendationPreparation.waitUntilIdle()
            guard !Task.isCancelled, identity == attempt, accountID != nil, !onboarding,
                  dependencies.dailyRecommendationStore.needsInitialStars else { return }
            guard await prepare(replacingCurrentBatch: false, origin: isPresented ? .user : .background),
                  !Task.isCancelled, identity == attempt else { return }
            preparedIdentity = attempt
            if isPresented { isReadyToPresent = true }
            presentAutomaticallyIfReady()
        }
    }

    /// 保存失败重试当前选择；取数失败延续原操作，避免“换批失败 → 重试”只恢复旧缓存。
    private func retry() async {
        let store = dependencies.dailyRecommendationStore
        if store.errorKey == "recommendations.daily.saveFailed" {
            await store.retrySaving()
        } else {
            let retryReplacement = (store.errorKey != nil || store.batchMessageKey != nil) && store.retryReplacesCurrentBatch
            _ = await prepare(replacingCurrentBatch: retryReplacement, origin: .user, retryReasons: true)
        }
    }

    /// 数据和实际主窗口分别就绪后才展示；加载慢、最小化或其它 Sheet 不消费每日资格。
    private func presentAutomaticallyIfReady() {
        guard !TestEnvironment.isRunning, !onboarding, accountID != nil,
              preparedIdentity == identity, isParentWindowReady, NSApp.isActive, !isPresented,
              !dependencies.dailyRecommendationStore.isLoading,
              dependencies.dailyRecommendationStore.canAutomaticallyPresent() else { return }
        isReadyToPresent = true
        isPresented = true
    }

    /// 自动准备、失败重试与主动换批共用取数路径；换批的成功结果只用于重置舞台动画。
    private func prepare(
        replacingCurrentBatch: Bool, origin: DailyRecommendationPreparation.Origin = .background,
        retryReasons: Bool = false
    ) async -> Bool {
        guard let accountID, !TestEnvironment.isRunning else { return false }
        let key = "\(identity)|\(replacingCurrentBatch)|\(retryReasons)"
        let revision = dependencies.databaseScopeRevision
        let language = locale.identifier
        let isPro = dependencies.entitlementGate.isProUser
        return await dependencies.dailyRecommendationPreparation.run(key: key, origin: origin) {
            let scope = await dependencies.recommendAPI.recommendationCacheScope()
            guard accountID == self.accountID, revision == dependencies.databaseScopeRevision,
                  !Task.isCancelled else { return false }
            let prepared = await dependencies.dailyRecommendationStore.load(
                accountID: accountID, scopeRevision: revision, serviceScope: scope,
                replacingCurrentBatch: replacingCurrentBatch,
                fetchStars: { try await dependencies.repoRepository.fetchAllStarred() },
                fetchCandidates: { try await dependencies.recommendAPI.fetchDailyCandidates(seedIDs: $0, cursor: $1) },
                prepareItems: { items in
                    await dependencies.dailyRecommendationExplanationStore.prepareBatch(
                        items: items, accountID: accountID, revision: revision, locale: language, isPro: isPro,
                        retryFailed: retryReasons,
                        checkConfiguration: { try dependencies.repoAIInsightService.ensureRecommendationReasonReady() }
                    ) { input in
                        try await dependencies.repoAIInsightService.generateRecommendationReason(
                            input: input, outputLanguage: language
                        )
                    }
                }
            )
            guard accountID == self.accountID, revision == dependencies.databaseScopeRevision,
                  !Task.isCancelled else { return false }
            await dependencies.dailyRecommendationStore.excludeStarred(dependencies.starredRegistry.ids)
            // 取数失败时旧批次仍可读，只恢复原已保存理由，不为失败回退另开一轮模型请求。
            await dependencies.dailyRecommendationExplanationStore.loadSaved(
                items: dependencies.dailyRecommendationStore.visibleItems,
                accountID: accountID, revision: revision, locale: language, isPro: isPro
            )
            return prepared
        }
    }

    /// 手动和自动入口共用实际呈现回调；关闭或切换账号后不登记尚未展示的批次
    private func recordPresentation() {
        guard isOverlayPresented, isOverlayWindowReady, isCardContentReady, let accountID else { return }
        let revision = dependencies.databaseScopeRevision
        Task {
            guard !Task.isCancelled, isOverlayPresented, isOverlayWindowReady, isCardContentReady,
                  accountID == self.accountID, revision == dependencies.databaseScopeRevision else { return }
            await dependencies.dailyRecommendationStore.markPresented()
        }
    }
}

extension RepoRecommendationItem {
    /// 推荐精简快照；详情入口会先保证 repos 父行存在，但不创建 Star 或知识库关系。
    var dailyRecommendationRepo: Repo {
        let parts = fullName.split(separator: "/")
        return Repo(
            id: repoID, owner: parts.first.map(String.init) ?? "",
            name: parts.last.map(String.init) ?? "", fullName: fullName,
            description: description, language: language, starsCount: stars, forksCount: forks,
            watchersCount: 0, topics: nil, license: nil, homepage: nil,
            htmlUrl: githubURL?.absoluteString ?? "", cloneUrl: nil, sshUrl: nil,
            isPrivate: false, isFork: false, isArchived: archived, isStarred: false,
            pushedAt: nil, createdAt: nil, updatedAt: nil, starredAt: nil, cachedAt: nil
        )
    }
}
