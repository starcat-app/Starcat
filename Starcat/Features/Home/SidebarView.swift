//
//  SidebarView.swift
//  Starcat
//
//  左栏：侧边栏。
//
//  Week 3 三个分组：
//  - 主：All Stars / Untagged
//  - Languages：按语言聚合，每项带计数
//
//  设计约束：
//  - 不直接做查询，数据来自 HomeViewModel
//  - 用 NavigationSplitView 的 selection binding 与 ViewModel 联动
//  - Languages 行点击 → 设置 selection 为 .language(lang)
//

import SwiftUI

struct SidebarView: View {

    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AuthSession.self) private var authSession

    /// 当前打开/收起 Languages 组的状态。
    @State private var languagesExpanded: Bool = true
    /// W4 A6：Tags 组展开/收起状态。
    @State private var tagsExpanded: Bool = true

    @Binding var showTagManagement: Bool

    var body: some View {
        @Bindable var vm = viewModel

        List(selection: $vm.selection) {
            Section("发现") {
                row(.trending)
            }

            if authSession.state.isAuthenticated {
                Section("主导航") {
                    row(.allStars, count: viewModel.totalCount)
                    row(.untagged, count: viewModel.untaggedCount)
                }

                // W4 A6：Tags 段。
                // 行为：每个用户自定义标签一行，点击 → selection = .tag(id) → 列表过滤
                // HOM-43：折叠按钮始终可见，不依赖 hover；图标在右侧；点击整个区域可折叠
                Section {
                    if tagsExpanded && !viewModel.tags.isEmpty {
                        ForEach(viewModel.tags) { tag in
                            tagRow(tag: tag, count: viewModel.tagCounts[tag.id] ?? 0)
                        }
                    }
                } header: {
                    tagSectionHeader
                }

                if !viewModel.languageStats.isEmpty {
                    // HOM-43：折叠按钮始终可见，不依赖 hover；图标在右侧；点击整个区域可折叠
                    Section {
                        if languagesExpanded {
                            ForEach(viewModel.languageStats) { stat in
                                languageRow(stat)
                            }
                        }
                    } header: {
                        languageSectionHeader
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // 用 safeAreaInset 把用户卡固定在 Sidebar 顶部，下面的 List 内容仍可滚动
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarHeaderView()
        }
    }

    /// HOM-43：Tags header 需要同时有“整行可折叠”和独立的标签管理按钮。
    /// 避免把 `Button` 嵌在另一个 `Button` 里，否则 SwiftUI 事件命中会不稳定。
    private var tagSectionHeader: some View {
        HStack(spacing: 6) {
            Button {
                toggleTags()
            } label: {
                HStack(spacing: 4) {
                    Text("Tags")
                        .font(.headline)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tagsExpanded ? "折叠 Tags" : "展开 Tags")

            Button {
                showTagManagement = true
            } label: {
                Image(systemName: "plus")
                    .imageScale(.small)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("标签管理")

            Button {
                toggleTags()
            } label: {
                disclosureChevron(isExpanded: tagsExpanded)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tagsExpanded ? "折叠 Tags" : "展开 Tags")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 6)
    }

    /// HOM-43：Languages 数字是“语言类别数量”，放在右侧 accessory 区域，
    /// 与 Tags header 的 `+` 按钮占位一致，而不是紧跟标题。
    private var languageSectionHeader: some View {
        Button {
            toggleLanguages()
        } label: {
            HStack(spacing: 6) {
                Text("Languages")
                    .font(.headline)

                Spacer(minLength: 8)

                Text(viewModel.languageStats.count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                disclosureChevron(isExpanded: languagesExpanded)
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(languagesExpanded ? "折叠 Languages" : "展开 Languages")
    }

    private func disclosureChevron(isExpanded: Bool) -> some View {
        Image(systemName: "chevron.right")
            .font(.caption)
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    private func toggleTags() {
        withAnimation(.easeInOut(duration: 0.2)) {
            tagsExpanded.toggle()
        }
    }

    private func toggleLanguages() {
        withAnimation(.easeInOut(duration: 0.2)) {
            languagesExpanded.toggle()
        }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem,
                     displayOverride: String? = nil,
                     count: Int? = nil) -> some View {
        Label {
            HStack(spacing: 4) {
                Text(displayOverride ?? item.displayName)
                    .lineLimit(1)

                Spacer()

                if item == .allStars {
                    SidebarSyncButton()
                }

                if let count {
                    Text(count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } icon: {
            Image(systemName: item.systemImage)
        }
        .tag(item)
    }

    /// W4 A6：tag 专属行——
    /// 用户配色（左侧色块）+ 用户自定义图标（若有）+ 名字 + 计数
    /// 复用通用 row() 不合适，因为 tag 的图标 / 颜色都是动态的
    @ViewBuilder
    private func tagRow(tag: Tag, count: Int) -> some View {
        Label {
            HStack {
                Text(tag.name).lineLimit(1)
                Spacer()
                Text(count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            // 优先 user-defined SF Symbol；否则 fallback "tag.fill"
            Image(systemName: tag.icon ?? "tag.fill")
                .foregroundStyle(Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor)
        }
        .tag(SidebarItem.tag(tag.id))
    }

    /// Languages 专属行——
    /// 每个语言显示对应的彩色圆形图标（与 GitHub 语言点风格一致）+ 语言名 + 计数
    @ViewBuilder
    private func languageRow(_ stat: LanguageStat) -> some View {
        let item = SidebarItem.language(stat.languageOrNil)
        Label {
            HStack {
                Text(stat.displayName)
                    .lineLimit(1)
                Spacer()
                Text(stat.count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            // 使用语言对应的彩色圆形图标
            if let lang = stat.languageOrNil, !lang.isEmpty {
                LanguageIconView(language: lang, size: 14)
            } else {
                // 无主语言（nil / Unknown）显示问号占位
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .tag(item)
    }
}

/// 放置在「全部 Stars」右侧的同步按钮
private struct SidebarSyncButton: View {
    @Environment(SyncManager.self) private var syncManager
    @Environment(AuthSession.self) private var authSession
    @State private var isHovering = false

    // 我们用单独的 state 追踪动画状态，确保旋转顺滑
    @State private var rotation: Double = 0

    var body: some View {
        Button {
            if syncManager.state == .syncing {
                syncManager.cancel()
            } else if case .rateLimited = syncManager.state {
                syncManager.cancel()
            } else {
                if case .authenticated(let user) = authSession.state {
                    syncManager.performFullSync(userID: user.id)
                }
            }
        } label: {
            Image(systemName: iconName)
                .font(.caption)
                .rotationEffect(.degrees(rotation))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
        .onAppear {
            updateRotation(isSyncing: isSyncing)
        }
        .onChange(of: isSyncing) { _, newValue in
            updateRotation(isSyncing: newValue)
        }
        .help(helpText)
    }

    private var isSyncing: Bool {
        if case .syncing = syncManager.state { return true }
        return false
    }

    private var iconName: String {
        switch syncManager.state {
        case .syncing:
            return isHovering ? "xmark.circle.fill" : "arrow.triangle.2.circlepath"
        case .rateLimited:
            return isHovering ? "xmark.circle.fill" : "hourglass"
        case .idle, .completed, .failed:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var helpText: String {
        switch syncManager.state {
        case .syncing:
            return "取消同步"
        case .rateLimited:
            return "配额恢复中，点击取消"
        case .idle, .completed, .failed:
            return "拉取 GitHub Stars"
        }
    }

    private func updateRotation(isSyncing: Bool) {
        if isSyncing {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                rotation = 0
            }
        }
    }
}
