//
//  DailyRecommendationHost.swift
//  Starcat
//
//  主窗口集成层：账号/数据库就绪后准备每日批次，自动入口不阻塞登录、
//  首次引导和其它 Sheet；固定入口可显式重试，不靠假数据填充空卡片。
//

import SwiftUI
import AppKit

/// 宿主只编排依赖和呈现；关闭或从详情返回时，批次由 AppDependencies 继续持有。
struct DailyRecommendationHost: ViewModifier {
    @Binding var isPresented: Bool
    let onOpen: (Repo) -> Void
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.firstRunOnboardingActive) private var onboarding
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme
    @State private var autoAttemptedIdentity: String?
    @State private var automaticPresentationIdentity: String?
    @State private var isOverlayWindowReady = false

    private var accountID: Int64? {
        guard let id = authSession.state.user?.id, dependencies.database.currentUserId == id else { return nil }
        return id
    }

    private var identity: String {
        "\(accountID ?? 0)|\(dependencies.databaseScopeRevision)|\(DailyRecommendationState.dayKey(Date()))|\(onboarding)"
    }

    func body(content: Content) -> some View {
        content.disabled(isPresented).accessibilityHidden(isPresented).background {
            DailyRecommendationOverlay(
                isPresented: isPresented,
                onClose: { isPresented = false },
                onPresentationChanged: { isOverlayWindowReady = $0 }
            ) {
                DailyRecommendationCardsView(
                    store: dependencies.dailyRecommendationStore,
                    onClose: { isPresented = false },
                    onOpen: onOpen,
                    onRetry: load
                )
                .environment(dependencies)
                .environment(AppSettings.shared)
                .environment(\.starcatReduceMotion, reduceMotion)
                .environment(\.starcatInterfaceScale, interfaceScale)
                .environment(\.colorScheme, colorScheme)
            }
            .frame(width: 0, height: 0)
        }
        .task(id: identity) {
            guard !TestEnvironment.isRunning else { return }
            isPresented = false
            dependencies.dailyRecommendationStore.activate(
                accountID: accountID, scopeRevision: dependencies.databaseScopeRevision
            )
            guard accountID != nil, !onboarding else { return }
            let attempt = identity
            guard autoAttemptedIdentity != attempt else { return }
            autoAttemptedIdentity = attempt
            let started = ContinuousClock.now
            await load()
            guard !Task.isCancelled, identity == attempt,
                  started.duration(to: .now) < .seconds(5),
                  !isPresented, NSApp.isActive,
                  NSApp.keyWindow?.attachedSheet == nil else { return }
            // 先确认真实子窗口已安装，再消费每日一次的自动展示资格。
            if dependencies.dailyRecommendationStore.canAutomaticallyPresent() {
                automaticPresentationIdentity = attempt
                isPresented = true
            }
        }
        .onChange(of: isOverlayWindowReady) { _, ready in
            guard ready,
                  let attempt = automaticPresentationIdentity,
                  identity == attempt,
                  isPresented else { return }
            Task {
                guard await dependencies.dailyRecommendationStore.claimAutomaticPresentation() else { return }
                guard !Task.isCancelled, identity == attempt else { return }
            }
        }
        .task(id: isPresented) {
            guard isPresented else { return }
            await load()
        }
        .onChange(of: dependencies.starredRegistry.ids) { _, ids in
            Task { await dependencies.dailyRecommendationStore.excludeStarred(ids) }
        }
    }

    /// 每次请求先固定账号和服务作用域；账号切换会让 Store 的 generation 失效。
    private func load() async {
        guard let accountID, !TestEnvironment.isRunning else { return }
        let revision = dependencies.databaseScopeRevision
        let scope = await dependencies.recommendAPI.recommendationCacheScope()
        guard accountID == self.accountID, revision == dependencies.databaseScopeRevision, !Task.isCancelled else { return }
        await dependencies.dailyRecommendationStore.load(
            accountID: accountID, scopeRevision: revision, serviceScope: scope,
            fetchStars: { try await dependencies.repoRepository.fetchAllStarred() },
            fetchCandidates: { try await dependencies.recommendAPI.fetchDailyCandidates(seedIDs: $0) }
        )
        guard accountID == self.accountID else { return }
        await dependencies.dailyRecommendationStore.excludeStarred(dependencies.starredRegistry.ids)
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
