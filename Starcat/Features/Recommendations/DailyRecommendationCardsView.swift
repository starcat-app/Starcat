//
//  DailyRecommendationCardsView.swift
//  Starcat
//
//  每日发现的原生业务宿主。WKWebView 呈现大圆角卡片，推荐批次、写入确认和详情
//  继续使用原生权威路径；网页不保存另一份 Star、反馈或浏览进度。
//

import SwiftUI

/// 保留整窗透明材质与原生确认，仅将项目卡片的布局和动画交给本地网页。
struct DailyRecommendationCardsView: View {
    @Bindable var store: DailyRecommendationStore
    let onClose: () -> Void
    let onOpen: (Repo) -> Void
    let onRetry: () async -> Void
    let onNextBatch: () async -> Bool
    let onPresented: () -> Void

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var pendingStar: RepoRecommendationItem?
    @State private var starringID: Int64?
    @State private var openingDetail = false
    @State private var actionFailed = false
    @State private var isPerformingAction = false
    @State private var isVisible = false
    @State private var rendererFailed = false
    @State private var rendererRevision = 0
    @State private var actionTask: Task<Void, Never>?
    @State private var detailTask: Task<Void, Never>?

    private var controlsBusy: Bool {
        store.isLoading || isPerformingAction || openingDetail || starringID != nil || pendingStar != nil
    }

    private var context: String {
        DailyRecommendationWebSnapshot.context(
            accountID: store.accountID, revision: dependencies.databaseScopeRevision, state: store.state
        )
    }

    /// 快照只包含可显示项目，完整 Stars、候选池、账户凭据和内部模型分数不传网页。
    private var snapshot: DailyRecommendationWebSnapshot {
        let emptyKey = store.accountID == nil ? "sidebar.loginPrompt" :
            store.errorKey ?? store.batchMessageKey ??
            (store.state.hasGeneratedBatch ? "recommendations.daily.done" : store.emptyKey)
        return DailyRecommendationWebSnapshot(
            context: context,
            items: store.visibleItems.map { item in
                .init(item, revealed: store.state.revealedIDs.contains(item.repoID),
                      explanation: dependencies.dailyRecommendationExplanationStore.text(
                         for: item, locale: locale.identifier, isPro: dependencies.entitlementGate.isProUser),
                       canRetryExplanation: dependencies.dailyRecommendationExplanationStore.canRetry(
                         for: item, locale: locale.identifier, isPro: dependencies.entitlementGate.isProUser))
            },
            labels: DailyRecommendationWebSnapshot.localizedLabels,
            date: store.state.generatedAt.map { $0.formatted(.dateTime.year().month().day().locale(locale)) } ?? "",
            locale: locale.identifier.replacingOccurrences(of: "_", with: "-").components(separatedBy: "@")[0],
            dark: colorScheme == .dark, reduceMotion: reduceMotion, scale: Double(interfaceScale.multiplier),
            loading: store.isLoading, busy: controlsBusy,
            message: (store.errorKey ?? store.batchMessageKey).map { String.l10n($0) },
            emptyMessage: String.l10n(emptyKey),
            canRetry: store.accountID != nil,
            canChangeBatch: store.accountID != nil && (!store.visibleItems.isEmpty || store.state.candidatePool != nil),
            canSetAutoShow: store.accountID != nil && store.hasLoadedState,
            showsOnLaunch: store.state.showsOnLaunch
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            DailyRecommendationBackdrop()
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            DailyRecommendationWebView(snapshot: snapshot, onAction: handle, onFailure: { rendererFailed = true })
                .id(rendererRevision)
                .ignoresSafeArea()
            if rendererFailed {
                VStack(spacing: 14) {
                    Text("recommendations.daily.failed")
                        .foregroundStyle(.secondary)
                    Button("recommendations.daily.retry") {
                        rendererFailed = false
                        rendererRevision += 1
                    }
                    .buttonStyle(.bordered)
                }
                .font(interfaceScale.font(.body))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
            }
            header
                .padding(.horizontal, 22)
                .padding(.top, 22)
        }
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            actionTask?.cancel()
            detailTask?.cancel()
        }
        .alert("recommendations.daily.starConfirm", isPresented: Binding(
            get: { pendingStar != nil },
            set: { if !$0 { pendingStar = nil } }
        )) {
            Button("common.cancel", role: .cancel) { pendingStar = nil }
            Button("recommendations.daily.star") {
                if let item = pendingStar { actionTask = Task { await star(item) } }
                pendingStar = nil
            }
        } message: {
            Text(verbatim: pendingStar?.fullName ?? "")
        }
        .alert("recommendations.daily.operationFailed", isPresented: $actionFailed) {
            Button("common.ok", role: .cancel) {}
        }
        .onExitCommand(perform: onClose)
    }

    /// 品牌、日期与关闭共用原生页头，避免网页内容宽度把日期和窗口关闭按钮拉开。
    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                // 读取当前渠道的正式图标，与 About、启动页保持一致，不再使用网页占位标记。
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text(verbatim: "Starcat")
                    .font(interfaceScale.font(.bodyEmphasis))
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 16)
            Text(verbatim: snapshot.date)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.primary)
                .lineLimit(1)
            SheetCloseButton(action: onClose)
        }
        // 局部材质为品牌、日期和系统关闭按钮提供稳定底色，不再依赖整窗灰幕衬托。
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// 浏览确认来自实际渲染的卡片；读取进度不等待整个批次浏览完成才落盘。
    private func handle(_ action: DailyRecommendationWebAction) {
        guard isVisible else { return }
        if action == .close { onClose(); return }
        if case let .presented(id) = action {
            onPresented()
            guard !store.state.revealedIDs.contains(id) else { return }
            let identity = context
            Task {
                guard isVisible, context == identity else { return }
                await store.reveal(id)
            }
            return
        }
        guard !controlsBusy else { return }
        switch action {
        case let .star(id):
            pendingStar = store.visibleItems.first { $0.repoID == id }
        case let .details(id):
            if let item = store.visibleItems.first(where: { $0.repoID == id }) { openDetail(item) }
        case .dismiss, .revealAll, .nextBatch, .retry, .setAutoShow:
            let identity = context
            isPerformingAction = true
            actionTask = Task {
                defer { isPerformingAction = false }
                guard !Task.isCancelled, isVisible, context == identity else { return }
                switch action {
                case let .dismiss(id): await store.dismiss(id)
                case .revealAll: await store.revealAll()
                case .nextBatch: _ = await onNextBatch()
                case .retry:
                    if store.errorKey == nil, store.state.candidatePool != nil, store.visibleItems.isEmpty {
                        _ = await onNextBatch()
                    } else { await onRetry() }
                case let .setAutoShow(enabled): await store.setShowsOnLaunch(enabled)
                default: break
                }
            }
        default: break
        }
    }

    /// Manage README 缓存以 repos 为外键父表，必须先补元数据，再允许详情开始加载。
    /// 关闭抽卡层或切账号后不再导航；写入失败留在当前卡片，沿用已有错误提示。
    private func openDetail(_ item: RepoRecommendationItem) {
        guard !openingDetail, let account = store.accountID,
              dependencies.database.currentUserId == account else { return }
        let revision = dependencies.databaseScopeRevision
        openingDetail = true
        detailTask = Task {
            defer { openingDetail = false }
            guard !Task.isCancelled, store.accountID == account,
                  dependencies.databaseScopeRevision == revision else { return }
            do {
                let repo = try await dependencies.repoRepository.upsertRepoMetadataForLibrary(
                    repo: item.dailyRecommendationRepo, syncedAt: Date(), preservingExisting: true
                )
                guard !Task.isCancelled, store.accountID == account,
                      dependencies.database.currentUserId == account,
                      dependencies.databaseScopeRevision == revision else { return }
                onOpen(repo)
            } catch {
                guard !Task.isCancelled, store.accountID == account,
                      dependencies.databaseScopeRevision == revision else { return }
                actionFailed = true
            }
        }
    }

    /// 只有用户确认后才调用 Star 的既有权威写入路径，失败保留原卡片供重试。
    private func star(_ item: RepoRecommendationItem) async {
        guard starringID == nil,
              let account = store.accountID,
              dependencies.database.currentUserId == account,
              !dependencies.starredRegistry.contains(ghRepoId: item.repoID) else { return }
        let parts = item.fullName.split(separator: "/")
        guard parts.count == 2 else { return }
        let revision = dependencies.databaseScopeRevision
        starringID = item.repoID
        defer { starringID = nil }
        do {
            _ = try await dependencies.starActionService.star(
                owner: String(parts[0]), repo: String(parts[1]), displayedStarsCount: item.stars
            )
            guard store.accountID == account, dependencies.databaseScopeRevision == revision else { return }
            await store.excludeStarred(dependencies.starredRegistry.ids)
        } catch {
            if store.accountID == account, dependencies.databaseScopeRevision == revision { actionFailed = true }
        }
    }
}
