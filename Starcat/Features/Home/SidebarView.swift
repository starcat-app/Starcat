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
    /// Trending 语言列表展开/收起状态。和 Manage 的 Languages 分开，避免互相影响。
    @State private var trendingLanguagesExpanded: Bool = true
    /// Activity 分类列表展开/收起状态。Activity 是独立 root，不能复用 Trending 的展开态。
    @State private var activityCategoriesExpanded: Bool = true

    @Binding var selectedPage: SidebarRootPage
    @Binding var selectedTrendingLanguage: TrendingLanguage
    @Binding var selectedActivityCategory: ActivityCategory
    @Binding var showTagManagement: Bool
    /// HOM-47：触发 Release 时间线 sheet。
    @Binding var showReleaseTimeline: Bool

    /// 当前在 Trending 页面选中的 repo，仅用于透传给 `SidebarHeaderView` 让头像背景的
    /// 语言色在 Trending 页也能联动（2026-06-02 21:38 接入）。Manage 页面应为 nil。
    /// 真源在 `HomeView.@State selectedTrendingRepo`，通过普通参数（非 binding）透传。
    var currentTrendingRepo: TrendingRepo?

    /// HOM-73：控制登录 sheet 的显示。
    @State private var showLoginSheet: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            sidebarFixedHeader
            sidebarList
        }
        .background(.bar)
        .sheet(isPresented: $showLoginSheet) {
            GithubAuthView()
        }
    }

    /// Sidebar 固定顶部区：用户卡 + 一级入口。
    ///
    /// 这里不再用 `safeAreaInset`，因为新增一级入口后列表滚动内容会进入 inset 区域下方，
    /// 视觉上和入口行重叠。固定 header 与下方 List 分开布局，可以让滚动边界由 SwiftUI
    /// 正常计算，同时统一背景材质，避免统计数据与入口行之间出现色差。
    private var sidebarFixedHeader: some View {
        VStack(spacing: 0) {
            SidebarHeaderView(trendingRepo: currentTrendingRepo)
            rootNavigationBar
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 8)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var sidebarList: some View {
        @Bindable var vm = viewModel

        switch selectedPage {
        case .manage:
            List(selection: $vm.selection) {
                manageSidebarContent
            }
            .listStyle(.sidebar)
        case .trending:
            List(selection: $selectedTrendingLanguage) {
                trendingSidebarContent
            }
            .listStyle(.sidebar)
        case .activity:
            List(selection: $selectedActivityCategory) {
                activitySidebarContent
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var manageSidebarContent: some View {
        if authSession.state.isAuthenticated {
            Section("sidebar.mainNavigation") {
                row(.allStars, count: viewModel.totalCount)
                row(.untagged, count: viewModel.untaggedCount)
                // HOM-47：Release 时间线入口（独立 sheet 承载，避免与三栏导航 selection 冲突）
                releaseTimelineRow
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
        } else {
            Section {
                Text("sidebar.loginPrompt")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var trendingSidebarContent: some View {
        Section {
            trendingLanguageRow(.all)

            if trendingLanguagesExpanded {
                ForEach(trendingLanguages) { language in
                    trendingLanguageRow(language)
                }
            }
        } header: {
            trendingLanguageSectionHeader
        }
    }

    @ViewBuilder
    private var activitySidebarContent: some View {
        Section {
            activityCategoryRow(.all)

            if activityCategoriesExpanded {
                ForEach(activityLeafCategories) { category in
                    activityCategoryRow(category)
                }
            }
        } header: {
            activityCategorySectionHeader
        }
    }

    private var activityCategorySectionHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                activityCategoriesExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("activity.category.section")
                    .font(.headline)

                Spacer(minLength: 8)

                Text(activityLeafCategories.count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                disclosureChevron(isExpanded: activityCategoriesExpanded)
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(disclosureHelp(isExpanded: activityCategoriesExpanded))
    }

    /// Activity 的 All 行常驻在 section 顶部，header 计数只统计可展开的具体分类；
    /// 这个口径与 Trending 的 Languages header 一致：`全部语言` 不计入右侧数字。
    private var activityLeafCategories: [ActivityCategory] {
        ActivityCategory.allCases.filter { $0 != .all }
    }

    @ViewBuilder
    private func activityCategoryRow(_ category: ActivityCategory) -> some View {
        Label {
            Text(category.titleKey)
                .lineLimit(1)
        } icon: {
            LanguageIconView(language: category.iconLanguage, size: 14)
        }
        .tag(category)
    }

    /// 头像 / 统计数据下方的三入口切换。
    ///
    /// 使用独立按钮而不是 `Picker`，是为了匹配参考图里"图标在上、文字在下"的入口形态。
    private var rootNavigationBar: some View {
        HStack(spacing: 0) {
            ForEach(SidebarRootPage.allCases) { page in
                rootNavigationButton(page)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func rootNavigationButton(_ page: SidebarRootPage) -> some View {
        let isSelected = selectedPage == page
        // HOM-73：Manage 需要登录才能访问；Trending 和 Activity 都有公开/本地空态，始终可打开。
        let needsLogin = !authSession.state.isAuthenticated
            && page == .manage

        return Button {
            if needsLogin {
                showLoginSheet = true
            } else {
                selectRootPage(page)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 24, weight: .regular))
                    .frame(height: 28)
                Text(page.titleKey)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.accentColor : (needsLogin ? Color.primary.opacity(0.3) : Color.primary.opacity(0.75)))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // 2026-06-02 dong4j 要求统一 hover 反馈：sidebar 三入口（Manage / Trending / Search）
        // 加 `.pressableHover()`，与详情页 / sidebar 头像 / Stats 保持同款交互反馈。
        // 关键约束：scale 1.06 + opacity 0.7 是临时反馈，鼠标移开恢复，不影响 isSelected
        // 的 accent color 视觉表达；needsLogin 的灰态按钮（点击会触发登录 sheet）也加 hover，
        // 因为它仍然是可点击元素。
        .pressableHover()
    }

    private func selectRootPage(_ page: SidebarRootPage) {
        guard selectedPage != page else { return }
        selectedPage = page
    }

    /// HOM-43：Tags header 需要同时有"整行可折叠"和独立的标签管理按钮。
    /// 避免把 `Button` 嵌在另一个 `Button` 里，否则 SwiftUI 事件命中会不稳定。
    private var tagSectionHeader: some View {
        HStack(spacing: 6) {
            Button {
                toggleTags()
            } label: {
                HStack(spacing: 4) {
                    Text("sidebar.tags")
                        .font(.headline)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(disclosureHelp(isExpanded: tagsExpanded))

            Button {
                showTagManagement = true
            } label: {
                Image(systemName: "plus")
                    .imageScale(.small)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text("sidebar.tagManagement"))

            Button {
                toggleTags()
            } label: {
                disclosureChevron(isExpanded: tagsExpanded)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(disclosureHelp(isExpanded: tagsExpanded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 6)
    }

    /// HOM-43：Languages 数字是"语言类别数量"，放在右侧 accessory 区域，
    /// 与 Tags header 的 `+` 按钮占位一致，而不是紧跟标题。
    private var languageSectionHeader: some View {
        Button {
            toggleLanguages()
        } label: {
            HStack(spacing: 6) {
                Text("sidebar.languages")
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
        .focusEffectDisabled()
        .help(disclosureHelp(isExpanded: languagesExpanded))
    }

    private var trendingLanguageSectionHeader: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                trendingLanguagesExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("sidebar.languages")
                    .font(.headline)

                Spacer(minLength: 8)

                Text(trendingLanguages.count.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                disclosureChevron(isExpanded: trendingLanguagesExpanded)
                    .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(disclosureHelp(isExpanded: trendingLanguagesExpanded))
    }

    private func disclosureHelp(isExpanded: Bool) -> Text {
        isExpanded ? Text("sidebar.collapse") : Text("sidebar.expand")
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

    /// Trending 语言优先来自本地 Stars 的语言聚合；未登录或尚未同步时给一组常用语言兜底，
    /// 保证 Trending 入口第一次打开也有可探索的分类。
    private var trendingLanguages: [TrendingLanguage] {
        let localLanguages = viewModel.languageStats.compactMap(\.languageOrNil)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let names = localLanguages.isEmpty
            ? ["JavaScript", "Java", "Python", "CSS", "PHP", "Ruby", "C++", "C", "Shell", "Objective-C", "R", "Go", "Swift"]
            : localLanguages

        return names.map { TrendingLanguage($0) }
    }

    @ViewBuilder
    private func trendingLanguageRow(_ language: TrendingLanguage) -> some View {
        Label {
            trendingLanguageTitle(language)
                .lineLimit(1)
        } icon: {
            if language == .all {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
            } else {
                LanguageIconView(language: language.rawValue, size: 14)
            }
        }
        .tag(language)
    }

    @ViewBuilder
    private func trendingLanguageTitle(_ language: TrendingLanguage) -> some View {
        if language == .all {
            Text("trending.allLanguages")
        } else {
            Text(verbatim: language.rawValue)
        }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem,
                     displayOverride: String? = nil,
                     count: Int? = nil) -> some View {
        Label {
            HStack(spacing: 4) {
                if let override = displayOverride {
                    Text(verbatim: override)
                        .lineLimit(1)
                } else {
                    Text(item.displayName)
                        .lineLimit(1)
                }

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
        // HOM-46 优化：鼠标悬停时预取相邻分类数据，降低点击后的感知延迟
        .onHover { isHovering in
            if isHovering {
                for candidate in item.prefetchCandidates {
                    viewModel.prefetch(selection: candidate)
                }
            }
        }
    }

    /// HOM-47：Release 时间线入口行。
    ///
    /// 设计取舍：把入口放在 Manage 的"主导航"段而不是单独的根页（`SidebarRootPage`），
    /// 是因为 Release 时间线属于 Stars 数据的衍生视图，跟 All Stars / Untagged 同源；
    /// 用 `Button` + sheet 而不是 `selection` 行，避免插入新 case 牵动 HomeViewModel
    /// reload 路径。
    @ViewBuilder
    private var releaseTimelineRow: some View {
        Button {
            showReleaseTimeline = true
        } label: {
            Label {
                Text("sidebar.releaseTimeline")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: {
                Image(systemName: "shippingbox.fill")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }

    /// W4 A6：tag 专属行——
    /// 用户配色（左侧色块）+ 用户自定义图标（若有）+ 名字 + 计数
    /// 复用通用 row() 不合适，因为 tag 的图标 / 颜色都是动态的
    @ViewBuilder
    private func tagRow(tag: Tag, count: Int) -> some View {
        let item = SidebarItem.tag(tag.id)
        Label {
            HStack {
                Text(verbatim: tag.name).lineLimit(1)
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
        .tag(item)
        // HOM-46 优化：hover 时预取相邻分类
        .onHover { isHovering in
            if isHovering {
                for candidate in item.prefetchCandidates {
                    viewModel.prefetch(selection: candidate)
                }
            }
        }
    }

    /// Languages 专属行——
    /// 每个语言显示对应的彩色圆形图标（与 GitHub 语言点风格一致）+ 语言名 + 计数
    @ViewBuilder
    private func languageRow(_ stat: LanguageStat) -> some View {
        let item = SidebarItem.language(stat.languageOrNil)
        Label {
            HStack {
                Text(verbatim: stat.displayName)
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
        // HOM-46 优化：hover 时预取相邻分类
        .onHover { isHovering in
            if isHovering {
                for candidate in item.prefetchCandidates {
                    viewModel.prefetch(selection: candidate)
                }
            }
        }
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
        .focusEffectDisabled()
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

    private var helpText: Text {
        switch syncManager.state {
        case .syncing:
            return Text("action.cancelSync")
        case .rateLimited:
            return Text("action.syncRateLimited")
        case .idle, .completed, .failed:
            return Text("action.syncInProgress")
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
