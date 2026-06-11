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
    /// HOM-PROFILE 2026-06-05：贡献草坪数据来源。@Observable，payload 变化时 sidebar 自动重渲染。
    @Environment(ContributionService.self) private var contributionService
    /// 2026-06-06 A 方案：用户 profile 缓存服务。Sidebar `.task(id: user.login)`
    /// 会调 `load(login:force: false)` 让 30min TTL 到期后自动后台刷新。
    /// 数据通过 service 拉到后反向 push 给 `AuthSession.acceptRefreshedUser` →
    /// sidebar 观察 `authSession.state` 自动更新，本视图不直接读 service.profile。
    @Environment(UserProfileService.self) private var userProfileService
    /// HOM-126：自动整理调度器。Sidebar 底部观察 `isAutoTidyRunning` 决定是否
    /// 显示「AI 自动整理中 N/M」轻量行。这是该功能的唯一可视入口（不弹 sheet / panel）。
    @Environment(AutoTidyScheduler.self) private var autoTidyScheduler
    /// MUL-176 followup：周刊分类计数徽章数据源。
    /// 仅在 Activity 选中 .weekly 时使用，其余路径完全不读，开销可忽略。
    @Environment(AppDependencies.self) private var dependencies

    /// 当前打开/收起 Languages 组的状态。
    @State private var languagesExpanded: Bool = true
    /// W4 A6：Tags 组展开/收起状态。
    /// 默认 **折叠**（2026-06-11 dong4j 体验优化）：tag 数量多时全展开会挤掉
    /// Languages / Activity / Trending 等同级 section 的视觉权重，初始折叠让用户
    /// 一眼看到全局结构，需要时再展开。会话内的展开状态由 @State 保持（不持久化，
    /// 与下方 languagesExpanded / trendingLanguagesExpanded / activityCategoriesExpanded
    /// 行为一致：重启 App 后回到折叠默认值）。
    @State private var tagsExpanded: Bool = false
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
    /// 当前 Activity 选中卡片的强调色，透传给顶部头像卡背景。
    ///
    /// 只传最终颜色而不传 `ActivityItem`，避免 Sidebar 需要理解 Activity 的详情模型。
    var currentActivityTintColor: Color?

    /// HOM-73：控制登录 sheet 的显示。
    @State private var showLoginSheet: Bool = false

    /// row() / tagRow() 内 trailing 区域（sync icon + count）的**整体固定宽度**（pt）。
    ///
    /// 2026-06-06 抖动**三次**修复（这次彻底）：
    ///
    /// 演进史：
    /// - v1：count Text 没保护 → 数字溢出 sidebar 右沿
    /// - v2：count Text 加 `.fixedSize(horizontal: true)` + trailing HStack 整体 `.fixedSize`
    ///   → 修了溢出和同位数同步累加抖动，但**漏掉跨位数（9 → 10、999 → 1000）抖动**
    /// - v3：count Text 改 `.frame(minWidth: 40, alignment: .trailing)` 配合外层
    ///   `.fixedSize` → 跨位数不抖了，**但** List selection 切换时 SwiftUI 在
    ///   `fixedSize`+`minWidth` 的双约束下做 layout 重测，反复在 ideal 和 minimum
    ///   之间插值，引发"切到 Languages 后 All Stars 数字闪烁 / 切回 All Stars 后
    ///   数字从右往左反复移动"的新现象（dong4j 2026-06-06 21:09 反馈）
    /// - **v4（当前）**：放弃 `fixedSize` + `minWidth` 的组合，直接把 trailing 整体
    ///   用 `.frame(width:, alignment: .trailing)` 锁死。内部用 `Spacer` 把 sync icon
    ///   推到左、count 推到右；不管 count 几位、不管 sync icon 是否显示，trailing
    ///   容器对外宽度永远是这个常量值，外部 layout 完全感知不到内部变化 → 100% 不抖。
    ///
    /// 关键 lesson：`fixedSize` 在 List 内不可靠——List 会因 selection / inset / scroll
    /// 等多种原因在 row 上反复发起 layout 测量，`fixedSize` 子树的"ideal width"
    /// 每次测量都会被重新求值，如果该 ideal 不是真正常量（如依赖 Text 内容长度）
    /// 就会反复插值。**真正常量化的方式只有 `.frame(width:)` 锁死整个外层容器。**
    ///
    /// 数值 60 的取值依据：sync icon(18) + spacing(4) + count Text 预留宽度(38) ≈ 60pt。
    /// 38pt 在 `.caption` + `monospacedDigit` 下能容纳 "99,999" 等 6 字符（5 位数 + 千分位
    /// 逗号），对绝大多数 starred 数都够。超过时 Text 会被截到 60pt 容器内，但实际
    /// 用户超过 100,000 stars 概率极低，不需要为此牺牲稳定性。
    private static let trailingFixedWidth: CGFloat = 60

    var body: some View {
        VStack(spacing: 0) {
            sidebarFixedHeader
            sidebarList
            // HOM-126：自动整理底部轻量指示。仅当调度器正在跑「自动模式」时显示，
            // 跑完自动消失。视觉权重故意做小（10pt 字 + 浅灰背景 + 单行）—
            // 自动整理本意是"用户感知不到地完成"，强提示反而违反设计。
            autoTidyFooter
        }
        .background(.bar)
        .sheet(isPresented: $showLoginSheet) {
            GithubAuthView()
        }
    }

    // MARK: - HOM-126：自动整理底部指示

    /// 自动整理"占位行 + 实时进度"。
    ///
    /// 设计：
    /// - 仅在 `autoTidyScheduler.isAutoTidyRunning == true` 时挂入，跑完整体消失。
    ///   零进度时也立刻消失而非保留"上次跑了 X"残留——那是设置页「运行状态」区的
    ///   职责，sidebar 只反映"当前是否在跑"。
    /// - 不接 hover popover、不接点击跳转：HOM-126 任务描述写"hover 显示 popover
    ///   看详情，点击进入设置「运行状态」区域"，但 macOS Settings scene 缺乏程序化
    ///   切换到指定 Tab 的标准入口（NSApplication.shared.sendAction(#selector:Settings 
    ///   缺自定义 selector）。第一版只放静态指示行，hover/click 留 P2。
    /// - 没有 .padding(.bottom) 是因为 background(.bar) 已经画到底；放在 VStack
    ///   末尾天然贴底，与 sidebarList 之间有 4pt 视觉间隙（通过 padding(.top, 4) 实现）。
    @ViewBuilder
    private var autoTidyFooter: some View {
        if autoTidyScheduler.isAutoTidyRunning {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    // 让 indeterminate spinner 与文字基线对齐（macOS 默认会偏高 1-2pt）
                    .frame(width: 12, height: 12)
                Text(String(format: String(localized: "sidebar.autoTidy.runningFormat"),
                            autoTidyScheduler.autoTidyProgressText))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.06))
            .help(Text("sidebar.autoTidy.tooltip"))
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: autoTidyScheduler.isAutoTidyRunning)
        }
    }

    /// Sidebar 固定顶部区：用户卡 + 贡献草坪 + 一级入口。
    ///
    /// 这里不再用 `safeAreaInset`，因为新增一级入口后列表滚动内容会进入 inset 区域下方，
    /// 视觉上和入口行重叠。固定 header 与下方 List 分开布局，可以让滚动边界由 SwiftUI
    /// 正常计算，同时统一背景材质，避免统计数据与入口行之间出现色差。
    ///
    /// HOM-PROFILE 2026-06-05：在 rootNavigationBar 上方插入贡献草坪。
    /// 仅当已登录时显示（未登录拿不到 user.login，也没必要展示）。
    private var sidebarFixedHeader: some View {
        VStack(spacing: 0) {
            SidebarHeaderView(
                trendingRepo: currentTrendingRepo,
                activityTintColor: currentActivityTintColor
            )

            // 贡献草坪：登录后才有效；首次显示触发 .task 拉取（命中 TTL 自动 no-op）。
            // 2026-06-05 follow-up：透传 `lastFetchedAt` 给草坪显示"更新于 X 分前"。
            if case .authenticated(let user) = authSession.state {
                ContributionGraphView(
                    payload: contributionService.payload,
                    isLoading: contributionService.isLoading,
                    lastFetchedAt: contributionService.lastFetchedAt,
                    login: user.login
                )
                .padding(.horizontal, 14)
                .padding(.top, 4)
                // 2026-06-05 v3 follow-up：dong4j 反馈"管理/趋势/活动 再上移 1/3"。
                // 原 .bottom 8 + rootNavigationBar.top 10 = 18pt 间距，减 1/3 → 12pt。
                // 拆成 bottom 4 + top 8 = 12pt，对称收缩、视觉更聚拢。
                .padding(.bottom, 4)
                .task(id: user.login) {
                    // 用 user.login 作为 task id：账号切换时自动重新加载。
                    // ContributionService / UserProfileService 内部各自做 TTL 与 inflight 互斥，重复调用安全。
                    contributionService.load(login: user.login)
                    // 2026-06-06 A 方案：profile TTL 到期后自动后台刷新（30min）；
                    // 命中 TTL 直接 no-op，无网络。
                    userProfileService.load(login: user.login)
                }
            }

            rootNavigationBar
                .padding(.horizontal, 8)
                .padding(.top, 8)
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
            // HOM-179：改为标签墙形式，横向排列自动换行；多选 OR 过滤。
            // HOM-43：折叠按钮始终可见，不依赖 hover；图标在右侧；点击整个区域可折叠
            Section {
                if tagsExpanded && !viewModel.tags.isEmpty {
                    TagWallView(
                        tags: viewModel.tags,
                        tagCounts: viewModel.tagCounts,
                        selectedTagIds: viewModel.selectedTagIds,
                        onTagTap: { tagId in
                            viewModel.toggleSelectedTag(tagId)
                        }
                    )
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
            // MUL-176 followup：周刊分类右侧带计数徽章（仿 Trending Languages 同款样式）。
            // 计数来自 `WeeklySelectionService.total`，由 `WeeklyContentViewModel`
            // 拉取分页结果时回写。total 为 nil 时（首次进入还没拉过）只显示分类名，
            // 不预占位、不显示 0，避免新用户首屏看到 "0 项" 误以为列表为空。
            if category == .weekly, let total = dependencies.weeklySelectionService.total, total > 0 {
                HStack {
                    Text(category.titleKey)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Spacer(minLength: 0)
                        Text(total.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .frame(width: Self.trailingFixedWidth, alignment: .trailing)
                }
            } else {
                Text(category.titleKey)
                    .lineLimit(1)
            }
        } icon: {
            // 分类色点：故意不复用 LanguageIconView，因为后者会优先匹配 Devicon SVG，
            // 渲染出 Swift / JS / Go 这类语言 logo，与"分类"语义冲突。
            // 这里直接画 14pt 实心圆，与 Manage / Trending 的语言图标视觉尺寸保持一致。
            Circle()
                .fill(category.iconColor)
                .frame(width: 14, height: 14)
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
        // HOM-73 / HOM-163：Manage 和 Activity 需要登录才能访问；Trending 有公开/本地空态，始终可打开。
        let needsLogin = !authSession.state.isAuthenticated
            && (page == .manage || page == .activity)

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

            // HOM-179：仅当有 tag 被选中时显示"清除"按钮，避免空状态下噪声。
            // 与 `+` / chevron 同款 14pt hierarchical 语言，hover 反馈复用 pressableHover。
            if !viewModel.selectedTagIds.isEmpty {
                Button {
                    viewModel.clearSelectedTags()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(Text("sidebar.clearSelectedTags"))
            }

            Button {
                showTagManagement = true
            } label: {
                // 2026-06-06 dong4j 反馈：原来的细线 `plus`(.small) 在 sidebar headline
                // 字号下视觉过弱，与右侧 chevron 几乎齐平，看不出是个可点击按钮。
                // 换成 `plus.circle.fill` + hierarchical + .secondary，14pt medium。
                // 与 SidebarHeaderView 的 ellipsis.circle.fill / square.and.arrow.up
                // 保持同款"填充圆形 hierarchical"语言，加强 affordance 同时不喧宾夺主。
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
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
            // Sidebar count 溢出 + 抖动 bugfix（dong4j 2026-06-06 三次修复，演进史见
            // `trailingFixedWidth` 常量上方的大注释）。
            //
            // 当前 v4 策略：trailing 整体用 `.frame(width: trailingFixedWidth, alignment: .trailing)`
            // 锁死宽度，**完全放弃** `.fixedSize` + `.minWidth` 的组合（在 List 内不可靠，
            // selection 切换时 SwiftUI 反复发起 layout 测量、在 ideal/minimum 之间插值，
            // 引发"切 Languages 后数字闪烁 + 切 All Stars 后数字从右往左反复"的新现象）。
            //
            // 新 trailing 内部结构：
            //   [sync icon(18×18, 仅 .allStars)] [Spacer(0)] [count Text 右对齐]
            //
            // - 有 sync icon：icon 贴左、count 贴右、中间 Spacer 自动撑开
            // - 无 sync icon：Spacer 占满左半部，count 仍紧贴右边
            // - count 位数变化（9 → 10 → 100）：仅在 Text intrinsic 内部伸缩，对外宽度不变
            // - sync icon SF Symbol 切换：外层 18×18 frame 锁死，对外宽度不变
            //
            // trailing 容器对外宽度永远 = trailingFixedWidth = 60pt，外层 HStack 看到的
            // layout 完全恒定 → 真正"零抖动"。
            //
            // 三个**关键**约束（已踩坑）：
            //  1. **不要**给 trailing HStack 用 `.fixedSize(horizontal: true)`——在 List 内
            //     SwiftUI 会反复测量 ideal width，若 ideal 依赖 Text 内容长度就会反复插值
            //  2. **不要**给 count Text 用 `.frame(minWidth:, alignment:)`——同上原因
            //  3. **必须**用 `.frame(width:)` 显式锁死外层容器宽度——这是 List 内**唯一**
            //     可靠的"对外宽度恒定"方式
            //
            // 副作用：60pt 对所有 row 生效，count 较小时右侧留空白；这其实让所有 sidebar row
            // 的数字纵向严格对齐，视觉反而更整齐——有意保留。
            HStack(spacing: 4) {
                if let override = displayOverride {
                    Text(verbatim: override)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(item.displayName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    if item == .allStars {
                        SidebarSyncButton()
                    }

                    Spacer(minLength: 0)

                    if let count {
                        Text(count.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .frame(width: Self.trailingFixedWidth, alignment: .trailing)
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
            // Sidebar count bugfix v4：与 row() 同款保护——trailing 容器整体用
            // `.frame(width: trailingFixedWidth)` 锁死，避免 List selection 切换时
            // SwiftUI 反复发起 layout 测量引起的"数字反复移动 / 闪烁"。
            // 详细根因 + 演进史见 `trailingFixedWidth` 常量上方的大注释。
            HStack {
                Text(verbatim: tag.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(width: Self.trailingFixedWidth, alignment: .trailing)
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
            // Sidebar count bugfix v4：与 row() 同款保护——trailing 容器整体 fixed width 锁死。
            // 详细根因见 `trailingFixedWidth` 常量上方的大注释。
            HStack {
                Text(verbatim: stat.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(stat.count.formatted())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(width: Self.trailingFixedWidth, alignment: .trailing)
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
            // 注：曾尝试给 Image 加 `.frame(width: 16, height: 16)` 解决"不同 SF Symbol
            // 几何中心在 18×18 容器内居中渲染时视觉位置偏移"的问题；但实测发现：
            // ① 主要抖动其实来自 List selection 切换时 trailing 容器 layout 重测（已通过
            //    外层 `.frame(width: trailingFixedWidth)` 在 row()/tagRow()/languageRow()
            //    侧统一锁死解决）
            // ② 加内层 frame 会在 selection 切换时增加 layout 工作量，反而可能加剧抖动
            // 所以保持最简：Image 不加 frame，由外层 .frame(18, 18) 锁 Button 容器即可。
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
