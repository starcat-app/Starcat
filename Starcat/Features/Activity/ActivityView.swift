//
//  ActivityView.swift
//  Starcat
//
//  Activity 页中栏。
//
//  设计约束：
//  - 不复用 `RepoRowView`，因为 Activity 卡片的事实源不是单一 Repo；
//    但复用 RemoteAvatar / LanguageBadge / StarsBadge / MetaBadge / RelativeDateBadge。
//  - ViewModel 由本视图按 Environment 里的 AppDependencies 构造，避免把 Activity 专属依赖
//    继续透传进 RepoListView 的初始化参数。
//
//  ────────────────────────────────────────────────────────────────────────────
//  v1.9 修订（2026-06-10, dong4j「四场景统一 row」遗留 bug）：repo-backed kind 切 UnifiedRepoRow
//  ────────────────────────────────────────────────────────────────────────────
//
//  R-01「四个场景统一 row」原本只统一了 3 个（Manage / Trending / Weekly），Activity 全
//  走独立的 `ActivityRowView` —— Activity 的 `star` / `repository` / `suggestion` 这三
//  种**纯仓库型**卡片视觉与其它场景割裂。
//
//  v1.9 把这三种 kind 切到 `UnifiedRepoRow`，复用 `Repo.asCardData(badge: .activityKind(...))`：
//    - 头像角自带 kind icon 圆角标（UnifiedRepoRow.avatarWithKindBadge 已有逻辑）；
//    - chip 行 Lang / Stars / Forks 与 Manage / Trending / Weekly 完全对齐。
//
//  v2.0（2026-06-11 dong4j 决策）：卡片右上角 RelativeDateBadge **已整列删除**。
//  原 `.activityKind(category, createdAt)` 第二参 Date 在 kind 间语义漂移
//  （starredAt / pushedAt），`.all` 视图同框无法辨识，整列删除是承认时戳
//  维度不够强一致。Date 参数已从 enum case 删除（详见 RepoCardViewData.swift 注释）。
//
//  保留 `ActivityRowView` 渲染的两类（dong4j 决策）：
//    - `release`：title = release name(主位)+ subtitle = repo.fullName + body = release notes
//      摘录 + 未读 chip。视觉上「以 release 为主体」，与 UnifiedRepoRow「以仓库为主体」
//      语义冲突，强行切会丢 release name 视觉权重 + 未读 chip 渲染槽。
//    - `announcement`：item.repo == nil，根本无法构造 `RepoCardViewData`（必填 fullName /
//      owner / repo / ghRepoId）。视觉差异本就该有 —— 让用户一眼看出这是 GitHub 公告。
//    - `following`：当前 ActivityViewModel 未生产此 kind；预留入口，行为同 announcement。
//
//  `showStarredCheckmark` 不传 → 默认 false，与 Manage 同策略 ——`ActivityViewModel.filter {
//  $0.isStarred }` 已过滤 100% starred，挂 ✓ 视觉冗余。
//

import SwiftUI

struct ActivityView: View {

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppSettings.self) private var settings
    // R-01 §3.1.4 Step 7.3：refreshRow 改用 SyncIconButton 后顶层 reduceMotion 已不需要。
    // ActivityRowView 内部仍保留自己的 reduceMotion env 处理 isSelected 动画。

    @Binding var selectedCategory: ActivityCategory
    @Binding var selectedItem: ActivityItem?

    @State private var viewModel: ActivityViewModel?

    var body: some View {
        Group {
            // MUL-176：weekly 分类是远端分页数据，与本地聚合的其它分类完全不同源，
            // 所以这里整体切到 `WeeklyContentView`，绕开 ActivityViewModel 的本地路径。
            if selectedCategory == .weekly {
                WeeklyContentView()
            } else if let viewModel {
                content(viewModel)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: selectedCategory) {
            // weekly 分类的数据加载由 WeeklyContentView 自行 .task 触发，
            // 这里不该再去走 ActivityViewModel.load，否则会做无意义的本地聚合。
            guard selectedCategory != .weekly else { return }
            let model = ensureViewModel()
            await model.load(category: selectedCategory)
            restoreSelection(from: model.items)
        }
    }

    @ViewBuilder
    private func content(_ viewModel: ActivityViewModel) -> some View {
        if viewModel.isLoading {
            RepoSkeletonListView(rowCount: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.loadError, viewModel.items.isEmpty {
            emptyState(systemImage: "exclamationmark.triangle", title: "activity.error.title", subtitleText: error)
        } else if viewModel.items.isEmpty {
            emptyState(systemImage: selectedCategory.systemImage, title: "activity.empty.title", subtitle: emptySubtitle)
        } else {
            List {
                refreshRow(viewModel)
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        selectedItem = item
                    } label: {
                        rowContent(for: item)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .listRowReveal(index: index, snapshotID: viewModel.itemsRevision)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds()
        }
    }

    /// 按 `item.kind` 派发到 `UnifiedRepoRow`（repo-backed kind）或 `ActivityRowView`
    /// （announcement / following）。
    ///
    /// **派发规则**（设计 §3.1.5 + v1.9 dong4j 拍板 / v2.0 删时戳）：
    /// - `star` / `repository` / `suggestion` → `UnifiedRepoRow` 与 Manage/Trending/Weekly
    ///   100% 视觉同构（badge 走 `.activityKind(category)`，
    ///   头像角 kind icon 由 UnifiedRepoRow 承担；v2.0 已删右上 RelativeDateBadge）；
    /// - 其它 kind（release 主体 = release name 而非 repo / announcement 无 repo）走老路径。
    ///
    /// `item.repo` 为 nil 的 corner case（announcement、未来的 following）一律退化到老视觉，
    /// 因为 `RepoCardViewData` 必填 fullName / owner / repo / ghRepoId。
    @ViewBuilder
    private func rowContent(for item: ActivityItem) -> some View {
        if let repo = item.repo, isUnifiedRowKind(item.kind) {
            // v1.9：纯仓库型 kind 走 UnifiedRepoRow。`showStarredCheckmark` 不传（默认 false）
            // —— ActivityViewModel.filter { $0.isStarred } 已过滤 100% starred，挂 ✓ 视觉冗余。
            UnifiedRepoRow(
                card: repo.asCardData(
                    badge: .activityKind(item.category),
                    inlineMetadata: inlineMetadata(for: item)
                ),
                isSelected: selectedItem?.id == item.id
            )
        } else {
            ActivityRowView(
                item: item,
                isSelected: selectedItem?.id == item.id
            )
        }
    }

    /// 判定一个 kind 是否能用 UnifiedRepoRow 渲染（v1.9）。
    ///
    /// 出参为 false 的两类：
    /// - `release`：v2.1 起也按 repo 聚合展示，一 repo 一卡片；release-specific 时间
    ///   放在 fullName 同行的 inline metadata，不再走老的 release row。
    /// - `announcement` / `following`：无 `item.repo`，无法构造 `RepoCardViewData`。
    private func isUnifiedRowKind(_ kind: ActivityKind) -> Bool {
        switch kind {
        case .release, .star, .repository, .suggestion:
            return true
        case .announcement, .following:
            return false
        }
    }

    private func inlineMetadata(for item: ActivityItem) -> RepoCardInlineMetadata? {
        guard item.kind == .release, let date = item.createdAt else { return nil }
        return RepoCardInlineMetadata(systemImage: "calendar", text: Self.absoluteDate(date))
    }

    private func refreshRow(_ viewModel: ActivityViewModel) -> some View {
        // R-01 §3.1.4 Step 7.3：自写 rotationEffect + repeatForever 改用统一的
        // SyncIconButton（图标 / 旋转动画 / hover / disabled / reduceMotion 一并统一）。
        HStack {
            if let last = viewModel.lastRefreshedAt {
                Text(String(format: String(localized: "activity.lastRefreshedFormat"), Self.relativeDate(last)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SyncIconButton(
                isRefreshing: viewModel.isRefreshing,
                disabled: viewModel.isRefreshing,
                tooltip: String(localized: "activity.refresh")
            ) {
                Task {
                    await viewModel.refresh(category: selectedCategory)
                    restoreSelection(from: viewModel.items)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var emptySubtitle: LocalizedStringKey {
        switch selectedCategory {
        case .following:
            return "activity.empty.following"
        case .release:
            return "activity.empty.release"
        default:
            return "activity.empty.subtitle"
        }
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, subtitleText: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(verbatim: subtitleText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func ensureViewModel() -> ActivityViewModel {
        if let viewModel {
            return viewModel
        }
        let model = ActivityViewModel(
            repoRepository: dependencies.repoRepository,
            releaseRepository: dependencies.releaseRepository,
            releasePoller: dependencies.releasePoller
        )
        viewModel = model
        return model
    }

    private func restoreSelection(from items: [ActivityItem]) {
        if let selectedItem, items.contains(where: { $0.id == selectedItem.id }) {
            return
        }
        selectedItem = items.first
    }

    private static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func absoluteDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

// MARK: - Row

private struct ActivityRowView: View {
    let item: ActivityItem
    let isSelected: Bool

    var body: some View {
        // R-01 §3.1.1（2026-06-10 P1）：RepoListDensity 已删，直接渲染 card。
        ActivityRowSurface(item: item, isSelected: isSelected) {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            leadingIcon(size: 40)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(verbatim: item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.kind == .release, item.isRead == false {
                        MetaBadge(systemImage: "circle.fill", text: String(localized: "activity.unread"), tint: .accentColor)
                    }
                }

                if let subtitle = item.subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let body = item.body, !body.isEmpty {
                    Text(verbatim: body)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let repo = item.repo {
                        if let language = repo.language, !language.isEmpty {
                            LanguageBadge(language: language, style: .full)
                        }
                        StarsBadge(count: repo.starsCount, style: .full)
                    }
                    MetaBadge(systemImage: item.category.systemImage, text: item.category.localizedTitle, tint: .secondary)
                    if let date = item.createdAt {
                        RelativeDateBadge(date: date)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func leadingIcon(size: CGFloat) -> some View {
        if let repo = item.repo {
            RemoteAvatar(urlString: RepoAvatarURL.from(owner: repo.owner), size: size, showBorder: size > 24)
        } else {
            ZStack {
                Circle()
                    .fill(item.accentColor.opacity(0.18))
                Image(systemName: item.category.systemImage)
                    .font(.system(size: size > 24 ? 17 : 11, weight: .semibold))
                    .foregroundStyle(item.accentColor)
            }
            .frame(width: size, height: size)
        }
    }
}

private struct ActivityRowSurface<Content: View>: View {
    let item: ActivityItem
    let isSelected: Bool
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(item: ActivityItem, isSelected: Bool, @ViewBuilder content: () -> Content) {
        self.item = item
        self.isSelected = isSelected
        self.content = content()
    }

    private var accentColor: Color {
        item.accentColor
    }

    private var backgroundOpacity: Double {
        if isSelected { return 0.18 }
        if isHovered { return 0.08 }
        // R-01 §3.1.1：RepoListDensity 已删，统一使用 card 密度的非 hover/selected 透明度。
        return 0.045
    }

    var body: some View {
        // R-01 §3.1.1（2026-06-10 P1）：RepoListDensity 已删，全部走 card 密度
        // 的视觉常量（vertical 8 / horizontal 10 / cornerRadius 10）。
        content
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .padding(.leading, isSelected ? 5 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accentColor.opacity(backgroundOpacity))
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accentColor)
                    .frame(width: isSelected ? 3 : 0)
                    .padding(.vertical, 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(accentColor.opacity(isSelected ? 0.42 : (isHovered ? 0.18 : 0.10)), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.14)) {
                    isHovered = hovering
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: isSelected)
    }
}
