//
//  RecommendationHistoryListView.swift
//  Starcat
//
//  正常三栏导航中的推荐历史。读取本地历史不请求推荐，也不消费每日展示资格。
//

import SwiftUI

/// 复用仓库行、快速搜索工具栏和统一分页；卡片覆盖层只有“今日推荐”显式打开。
struct RecommendationHistoryListView: View {
    @Bindable var model: RecommendationHistoryListModel
    let onShowDailyRecommendations: () -> Void
    let onCountChange: (Int) -> Void
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AuthSession.self) private var authSession
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @State private var quickSearchDraft = ""
    @State private var isQuickSearchExpanded = false
    @Namespace private var selectionNamespace

    private var store: DailyRecommendationStore { dependencies.dailyRecommendationStore }
    private var accountID: Int64? {
        guard let id = authSession.state.user?.id, id == dependencies.database.currentUserId else { return nil }
        return id
    }
    private var scope: String { "\(accountID.map(String.init) ?? "anonymous")|\(dependencies.databaseScopeRevision)" }
    private var queryIdentity: String { "\(model.dateScope.identity)|\(model.filter.rawValue)|\(model.search)" }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            content
                .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: store.hasLoadedState)
        }
        .task(id: scope) {
            model.activate(scope: scope)
            quickSearchDraft = model.search
            isQuickSearchExpanded = !model.search.isEmpty
            guard let accountID else { return }
            _ = await store.loadPreferences(accountID: accountID, scopeRevision: dependencies.databaseScopeRevision)
            guard !Task.isCancelled else { return }
            rebuild()
        }
        .onChange(of: store.historyEntries) { _, _ in rebuild() }
        .onChange(of: dependencies.starredRegistry.ids) { _, _ in rebuild() }
        .onChange(of: queryIdentity) { _, _ in rebuild() }
    }

    private var filterBar: some View {
        QuickSearchToolbarContent(
            isExpanded: $isQuickSearchExpanded, draft: $quickSearchDraft,
            committedQuery: model.search, placeholder: "list.quickSearch.placeholder",
            onSubmit: { model.search = QuickSearchTextMatcher.normalized($0) },
            onClear: { model.search = ""; quickSearchDraft = "" }
        ) {
            Picker("recommendations.daily.navigationTitle", selection: $model.filter) {
                ForEach(RecommendationHistoryFilter.allCases) { filter in
                    Text(LocalizedStringKey(filter.titleKey)).tag(filter)
                }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
                .layoutPriority(AdaptiveToolbarStatusText.spacerPriority)
            Button("recommendations.history.today", action: onShowDailyRecommendations)
                .disabled(accountID == nil)
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.top, ManageListFilterBarMetrics.topPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
    }

    @ViewBuilder
    private var content: some View {
        if accountID == nil {
            ContentUnavailableView("sidebar.loginPrompt", systemImage: "person.crop.circle")
        } else if !store.hasLoadedState {
            if store.errorKey != nil {
                ContentUnavailableView {
                    Label("error.loadFailed", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("action.retry") {
                        Task {
                            guard let accountID else { return }
                            await store.loadPreferences(accountID: accountID, scopeRevision: dependencies.databaseScopeRevision)
                            rebuild()
                        }
                    }
                }
            } else {
                RepoSkeletonListView(rowCount: 8)
                    .transition(.opacity)
            }
        } else {
            if store.errorKey == "recommendations.daily.saveFailed" {
                HStack {
                    Text("recommendations.daily.saveFailed").foregroundStyle(.secondary)
                    Spacer()
                    Button("action.retry") { Task { await store.retrySaving() } }
                }
                .font(.caption)
                .padding(8)
            }
            if model.filtered.isEmpty {
                ContentUnavailableView {
                    Label("recommendations.history.empty", systemImage: "clock")
                } description: {
                    Text(LocalizedStringKey(store.historyEntries.isEmpty ? "recommendations.history.emptyDescription" : "list.quickSearch.empty"))
                }
            } else {
                historyList
                    .transition(.opacity)
            }
        }
    }

    private var historyList: some View {
        let rows = model.rows
        return List {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)) {
                        model.selectedID = entry.id
                    }
                } label: {
                    row(entry)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .contextMenu { feedbackActions(entry) }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowReveal(index: index, snapshotID: model.revision)
                .automaticListPagination(
                    appearingIndex: index, visibleItemCount: rows.count,
                    loadedItemCount: rows.count, hasMore: model.hasMore, isLoading: false,
                    identity: model.paginationIdentity.uuidString
                ) { model.loadMore() }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .scrollContentBackground(.hidden)
        .id(model.paginationIdentity)
        .automaticListPaginationFill(
            visibleItemCount: rows.count, loadedItemCount: rows.count,
            hasMore: model.hasMore, isLoading: false, identity: model.paginationIdentity.uuidString
        ) { model.loadMore() }
    }

    @ViewBuilder
    private func row(_ entry: RecommendationHistoryEntry) -> some View {
        if let item = entry.item {
            UnifiedRepoRow(
                card: item.asCardData(
                    registry: dependencies.starredRegistry,
                    inlineMetadata: nil,
                    footerMetadata: entry.feedback(starredIDs: dependencies.starredRegistry.ids) == .dismissed
                        ? RepoCardInlineMetadata(systemImage: "hand.thumbsdown", text: String.l10n("recommendations.history.dismissed")) : nil
                ),
                isSelected: model.selectedID == entry.id,
                selectionNamespace: selectionNamespace
            )
        } else {
            RepoRowSurface(isSelected: model.selectedID == entry.id, selectionNamespace: selectionNamespace) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("recommendations.history.unavailable").font(.subheadline.weight(.semibold))
                    Text("#\(entry.id)").font(.caption).foregroundStyle(.secondary)
                    if entry.feedback(starredIDs: dependencies.starredRegistry.ids) == .dismissed {
                        Text("recommendations.history.dismissed").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 反馈为本场景操作，不写用户 Tags，也不调用 Unstar。
    @ViewBuilder
    private func feedbackActions(_ entry: RecommendationHistoryEntry) -> some View {
        if entry.feedback(starredIDs: dependencies.starredRegistry.ids) == .dismissed {
            Button("recommendations.history.restore") { Task { await store.restoreInterest(entry.id) } }
        } else if !dependencies.starredRegistry.contains(ghRepoId: entry.id) {
            Button("recommendations.history.dismissed") { Task { await store.dismiss(entry.id) } }
        }
    }

    private func rebuild() {
        model.rebuild(entries: store.historyEntries, starredIDs: dependencies.starredRegistry.ids)
        onCountChange(model.filtered.count)
    }
}
