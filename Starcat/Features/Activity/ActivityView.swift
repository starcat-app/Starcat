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
            RepoSkeletonListView(density: settings.listDensity, rowCount: 8)
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
                        ActivityRowView(
                            item: item,
                            density: settings.listDensity,
                            isSelected: selectedItem?.id == item.id
                        )
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
}

// MARK: - Row

private struct ActivityRowView: View {
    let item: ActivityItem
    let density: RepoListDensity
    let isSelected: Bool

    var body: some View {
        // R-01 §3.1.1：仅 .card 单 case 保留，紧凑布局已删。
        ActivityRowSurface(item: item, density: density, isSelected: isSelected) {
            switch density {
            case .card:
                card
            }
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
    let density: RepoListDensity
    let isSelected: Bool
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(item: ActivityItem, density: RepoListDensity, isSelected: Bool, @ViewBuilder content: () -> Content) {
        self.item = item
        self.density = density
        self.isSelected = isSelected
        self.content = content()
    }

    private var accentColor: Color {
        item.accentColor
    }

    private var backgroundOpacity: Double {
        if isSelected { return 0.18 }
        if isHovered { return 0.08 }
        return density == .card ? 0.045 : 0.0
    }

    var body: some View {
        content
            .padding(.vertical, density == .card ? 8 : 4)
            .padding(.horizontal, density == .card ? 10 : 8)
            .padding(.leading, isSelected ? 5 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: density == .card ? 10 : 8, style: .continuous)
                    .fill(accentColor.opacity(backgroundOpacity))
            }
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accentColor)
                    .frame(width: isSelected ? 3 : 0)
                    .padding(.vertical, 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: density == .card ? 10 : 8, style: .continuous)
                    .stroke(accentColor.opacity(isSelected ? 0.42 : (isHovered ? 0.18 : 0.10)), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: density == .card ? 10 : 8, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.14)) {
                    isHovered = hovering
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: isSelected)
    }
}
