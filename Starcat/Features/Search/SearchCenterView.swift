//
//  SearchCenterView.swift
//  Starcat
//
//  主窗口级搜索浮层。结果行复用 UnifiedRepoRow，网页资料保持独立样式，避免把网页
//  结果伪装成仓库。业务动作由宿主注入，搜索模块不直接依赖 HomeViewModel。
//

import SwiftUI

struct SearchCenterView: View {
    @Bindable var viewModel: SearchCenterViewModel
    /// 直接复用 Manage 本地 Star 仓库的语言统计，避免搜索筛选维护第二份固定语言表。
    let languages: [LanguageStat]
    let onOpenCandidate: (SearchCandidate) -> Void
    let onOpenURL: (RepositoryCandidate) -> Void
    let onCopyURL: (RepositoryCandidate) -> Void
    let onOpenAI: (Repo) -> Void
    let onToggleStar: (Repo) async throws -> Bool
    let isStarred: (Int64) -> Bool
    let isGitHubAuthenticated: Bool

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var homeViewModel
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @FocusState private var isSearchFocused: Bool
    /// SEARCH-RICH 2026-06-14：从 `Repo?` 改为 `RepositoryCandidate?` —— 弹窗
    /// 新增需要展示 `remoteExtras`（disabled / isTemplate / score）以及 sort 模式
    /// 来决定是否渲染匹配度，单纯的 `Repo` 不够用，必须把整张候选传进去。
    @State private var remoteDetailCandidate: RepositoryCandidate?
    // hover 高亮由 row 内层的 RepoRowSurface 自带（`UnifiedRepoRow` 与 reference
    // 卡片均复用同一容器），SearchCenterView 不再单独维护 `hoveredCandidateID`。
    // 设计意图未变：键盘 selectedIndex 与鼠标 hover 仍互不干扰——
    // hover 是 row 内部 `@State`，移开自动清空；selectedIndex 由 `.onKeyPress` 写入。
    /// 清空全部历史的二次确认对话框可见性。
    /// 放在视图层是因为"是否要二次确认"是 UI 决策而非业务状态；ViewModel 的
    /// `clearHistory()` 仍保持单纯执行删除，不被弹窗逻辑污染。
    @State private var showingClearHistoryAlert = false
    /// 高级筛选右侧抽屉可见性。
    ///
    /// 这是纯视图状态，不放进 `SearchCenterViewModel`：筛选值本身仍由 ViewModel 持有，
    /// 但“抽屉是否展开”只影响当前浮层布局。Local scope 没有 GitHub / Web 筛选，
    /// 切过去时会自动收起，避免右侧出现空抽屉。
    @State private var isFilterDrawerPresented = false
    /// GitHub「最低 Stars」输入草稿；点「应用筛选」时写入 `githubFilters.minimumStars`。
    @State private var minStarsDraft = ""
    /// Web「结果数」输入草稿；点「应用筛选」时写入 `anySearchFilters.maxResults`。
    @State private var maxResultsDraft = ""
    /// External Search 域名白名单输入草稿；逗号或空白分隔。
    @State private var includeDomainsDraft = ""
    /// External Search 域名黑名单输入草稿；逗号或空白分隔。
    @State private var excludeDomainsDraft = ""
    /// Search Center 行内 ❤️ 操作中的 repo。用 repo id 控制单按钮 loading，避免
    /// 点击一个结果时把整张搜索列表都置灰。
    @State private var libraryOperationRepoID: Int64?
    @State private var pendingUsingRemovalCandidate: RepositoryCandidate?
    @State private var isConfirmingUsingLibraryRemoval = false
    @State private var libraryToast: String?

    var body: some View {
        ZStack {
            // 模态遮罩（dong4j 2026-06-14 第四次调整，对齐 Spotlight 真实意图）：
            // - 历次反复：0.42 → 0.20 → 0.05 三步降下来，但 dong4j 真实诉求是
            //   「主窗口变暗、浮层变亮」（即 macOS Spotlight 的视觉模型），
            //   不是「主窗口保持亮、浮层也保持亮」。前 3 次降 dim 是误读需求。
            // - 0.40 让主窗口明显「退到后景」，给浮层留出强烈焦点感。tap-to-dismiss
            //   命中区也兼具焦点反馈，与 Spotlight / Raycast 等命令面板一致。
            Color.black.opacity(0.40)
                .ignoresSafeArea()
                .onTapGesture { viewModel.dismiss() }
                // dim 蒙层走纯 opacity 淡入淡出；与浮层 VStack 的 scale+opacity transition
                // 同步播放，避免「浮层缩放出现时遮罩瞬切」造成的视觉割裂。
                .transition(.opacity)

            VStack(spacing: 0) {
                searchHeader
                themedSeparator
                scopePicker
                themedSeparator
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        resultContent
                        webResultFooter
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if shouldShowFilterDrawer {
                        themedVerticalSeparator
                        filterDrawer
                            .frame(width: 250)
                            // 抽屉内容（含 ScrollView 滚动条）必须裁在面板圆角内；
                            // 否则 macOS overlay scrollbar 会画到浮层外侧。
                            .clipped()
                            .transition(reduceMotion ? .identity : .opacity)
                    }
                }
            }
            .frame(width: searchPanelWidth, height: 620)
            .animation(
                reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.90),
                value: shouldShowFilterDrawer
            )
            // 浮层背景（dong4j 2026-06-14 终版）：
            // 极简：用 `windowBackgroundColor` 实底，浮层颜色直接 = 主窗口未压暗时的颜色。
            // 主窗口被 dim 蒙层压暗后，浮层不受 dim 影响自然凸显——这就是 Spotlight 的视觉模型。
            // 不需要 NSVisualEffectView / vibrant material / 双层叠加这些花活。
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            }
            // 先裁圆角再投影，避免 ScrollView 滚动条 / 抽屉滑入时画出卡片外。
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
            // 去掉 scale 弹入：Spotlight / 命令面板典型是淡入 + 轻微位移，scale 容易显得「弹」。
            .transition(reduceMotion ? .opacity : .opacity)
        }
        .defaultCursorShield()
        .onAppear { focusSearchFieldOnAppear() }
        .sheet(item: $remoteDetailCandidate) { candidate in
            // 把 sort 模式一并传入：仅在 bestMatch 时才渲染匹配度，否则
            // score 字段对当前结果排序无解释力（按 stars / forks / updated
            // 排序时它仍是 search 端点回的同一个值，但语义已和位置脱钩）。
            SearchRemoteRepoDetailView(
                candidate: candidate,
                isCurrentSortBestMatch: viewModel.githubFilters.sort == .bestMatch,
                isStarred: candidate.displayRepo.map { isStarred($0.id) } ?? false,
                onToggleStar: {
                    guard let repo = candidate.displayRepo else {
                        return false
                    }
                    return try await onToggleStar(repo)
                },
                onOpenAI: {
                    if let repo = candidate.displayRepo { onOpenAI(repo) }
                },
                onOpenInGitHub: { onOpenURL(candidate) },
                onCopyURL: { onCopyURL(candidate) },
                onToggleLibrary: {
                    await handleLibraryToggleTapped(candidate)
                },
                isLibraryWorking: libraryOperationRepoID == candidate.displayRepo?.id
            )
            .appSheetRootEnvironment(dependencies)
        }
        .sheet(item: $viewModel.paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .onKeyPress(.upArrow) {
            viewModel.moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            viewModel.moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            let normalizedDraft = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if let candidate = viewModel.selectedCandidate,
               !viewModel.lastSubmittedQuery.isEmpty,
               normalizedDraft == viewModel.lastSubmittedQuery {
                onOpenCandidate(candidate)
            } else {
                Task { await viewModel.submit() }
            }
            return .handled
        }
        .onKeyPress(.escape) {
            viewModel.dismiss()
            return .handled
        }
        .onChange(of: viewModel.scope) { _, _ in
            if !filtersAvailable {
                isFilterDrawerPresented = false
            }
        }
        .alert(
            "library.removeUsing.confirmTitle",
            isPresented: $isConfirmingUsingLibraryRemoval
        ) {
            Button("library.removeUsing.confirmAction", role: .destructive) {
                if let candidate = pendingUsingRemovalCandidate {
                    Task {
                        await setLibraryState(
                            .outsideLibrary,
                            for: candidate,
                            downgradeUsingStatus: true
                        )
                    }
                }
            }
            Button("general.cancel", role: .cancel) {
                pendingUsingRemovalCandidate = nil
            }
        } message: {
            Text("library.removeUsing.confirmMessage")
        }
        .toast(
            message: $libraryToast,
            icon: libraryToastIcon,
            iconColor: libraryToastIconColor,
            bottomPadding: libraryToastBottomPadding
        )
    }

    /// 浮层内部的分隔线。
    /// SwiftUI 默认 `Divider()` 在浅色主题 + `.regularMaterial` 浮层底上会显得过于发亮
    /// （因为 SwiftUI 默认分隔色与浅色材质的对比度过高），换成 `NSColor.separatorColor`
    /// 这一 AppKit 系统级 separator 后，dark / light 都能自动得到合适的对比度。
    private var themedSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
    }

    /// 右侧筛选抽屉分隔线。单独定义为 vertical，避免用旋转 Divider 造成像素模糊。
    private var themedVerticalSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
    }

    private var filtersAvailable: Bool {
        viewModel.scope == .all || viewModel.scope == .github || viewModel.scope == .web
    }

    private var shouldShowFilterDrawer: Bool {
        isFilterDrawerPresented && filtersAvailable
    }

    /// 专属空态判定：.web scope + 当前 External Search Provider 不可用。
    ///
    /// 限制条件：
    /// - 只看 `.web` scope —— `.all` scope 下 AnySearch 只是可选聚合项之一，
    ///   用「未启用」提示会掩盖真正的失败原因（GitHub / 本地 FTS）。
    /// - 直接读 `AppSettings.shared` 而不是绕到 ViewModel：SearchCenterViewModel
    ///   没有暴露「当前是否启用 AnySearch」的状态，且本判定属于 UI 分流决策，
    ///   不属于业务状态——VM 不应承载。SearchCenterView 在 MainActor 读取安全。
    /// - 不需要再判 `candidates.isEmpty`：调用方已经走过那条分支作为前置条件。
    private var isExternalSearchUnavailableEmpty: Bool {
        guard viewModel.scope == .web else { return false }
        return !isExternalSearchProviderUsable(viewModel.webSearchProvider)
    }

    /// 默认保持 Spotlight 紧凑 760pt；展开 Filters 后给右侧抽屉增加 250pt。
    /// 980pt 仍明显小于 Starcat 主窗口 1440pt 下限，不会压迫背景内容。
    private var searchPanelWidth: CGFloat {
        shouldShowFilterDrawer ? 980 : 760
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("search.searchField.placeholder", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(interfaceScale.font(.iconLarge))
                .focused($isSearchFocused)
                .onSubmit { Task { await viewModel.submit() } }

            if !viewModel.query.isEmpty {
                Button { viewModel.clear() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private func focusSearchFieldOnAppear() {
        Task { @MainActor in
            // SearchCenterView 作为 overlay 淡入时，首个 onAppear 可能早于 TextField
            // 真正进入可接收 first responder 的窗口层级；让出一轮主线程后再申请焦点，
            // 避免 SwiftUI 吞掉这次 focus 赋值，保证打开全局搜索后可直接输入。
            await Task.yield()
            isSearchFocused = true
        }
    }

    private var scopePicker: some View {
        HStack(spacing: 8) {
            ForEach(SearchScope.allCases) { scope in
                Button {
                    Task { await viewModel.changeScope(scope) }
                } label: {
                    Text(scopeTitle(scope))
                        .font(interfaceScale.font(.captionStrong, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(viewModel.scope == scope ? Color.accentColor.opacity(0.24) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            Spacer()
            if filtersAvailable {
                Button {
                    isFilterDrawerPresented.toggle()
                } label: {
                    searchToolbarCapsule(
                        titleKey: "search.filters.toggle",
                        systemImage: "line.3.horizontal.decrease.circle",
                        isActive: isFilterDrawerPresented
                    )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("search.filters.toggle.help")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    /// scope 栏 Filters / 历史区 Clear all 共用的右侧胶囊样式。
    @ViewBuilder
    private func searchToolbarCapsule(
        titleKey: LocalizedStringKey,
        systemImage: String,
        isActive: Bool
    ) -> some View {
        Label(titleKey, systemImage: systemImage)
            .font(interfaceScale.font(.captionStrong, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isActive ? Color.accentColor.opacity(0.20) : Color.secondary.opacity(0.10),
                in: Capsule()
            )
    }

    /// 右侧筛选抽屉。只承载高级筛选，不再挤占结果区顶部高度。
    ///
    /// 不设独立标题行：scope 栏右侧的 Filters 胶囊已是开关（选中态 = 展开，再点即收起），
    /// 避免「Filters 按钮 + Filters 标题 + ×」三层重复。
    private var filterDrawer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.scope == .all || viewModel.scope == .github {
                    githubFilterSection
                }
                if viewModel.scope == .all || viewModel.scope == .web {
                    anySearchFilterSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollContentBackground(.hidden)
        // 滚动条贴在抽屉右缘内侧，避免与面板外缘重叠。
        .safeAreaPadding(.trailing, 4)
        .background(Color.primary.opacity(0.018))
        .onAppear { syncNumericFilterDrafts() }
    }

    private var githubFilterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("search.github.filterTitle", systemImage: "line.3.horizontal.decrease.circle")
                    .font(interfaceScale.font(.captionStrong, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: isGitHubAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                        .foregroundStyle(isGitHubAuthenticated ? .green : .secondary)
                    Text(isGitHubAuthenticated ? "search.github.signedIn" : "search.github.anonymous")
                        .foregroundStyle(.secondary)
                }
                .font(interfaceScale.font(.caption))
            }

            if let summary = viewModel.githubResultSummary {
                Text(summary)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            githubLanguagePicker(width: 222)
            githubTextFilter(
                titleKey: "search.github.filter.topic",
                placeholderKey: "search.github.filter.topic.placeholder",
                text: optionalBinding(\.topic)
            )
            VStack(alignment: .leading, spacing: 5) {
                SearchFilterNumericField(
                    titleKey: "search.github.filter.minStars",
                    placeholder: String.l10n("search.github.filter.minStars.placeholder"),
                    hintKey: "search.github.filter.minStars.hint",
                    draft: $minStarsDraft,
                    minimum: 1,
                    maximum: nil,
                    maxDigitCount: 12,
                    allowsEmpty: true
                )
            }

            HStack(alignment: .bottom, spacing: 10) {
                githubSortPicker(width: 132)
                githubOrderPicker(width: 80)
            }

            githubDateFilter(titleKey: "search.github.filter.createdAfter", keyPath: \.createdAfter)
            githubDateFilter(titleKey: "search.github.filter.pushedAfter", keyPath: \.pushedAfter)

            HStack(spacing: 8) {
                Button("search.github.filter.apply") {
                    guard commitMinStarsDraft() else { return }
                    Task { await viewModel.applyGitHubFilters() }
                }
                .buttonStyle(.borderedProminent)

                Button("search.github.filter.clearDates") {
                    viewModel.githubFilters.createdAfter = nil
                    viewModel.githubFilters.pushedAfter = nil
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Web / AnySearch 筛选抽屉 section。保持原有筛选值与 apply 行为，只改变布局容器。
    private var anySearchFilterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("search.web.filterTitle", systemImage: "globe")
                    .font(interfaceScale.font(.captionStrong, weight: .semibold))
                Spacer()
            }

            providerPicker

            Text(anySearchFiltersSummary)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            SearchFilterNumericField(
                titleKey: "search.web.maxResults",
                placeholder: "10",
                hintKey: "search.anysearch.maxResults.hint",
                draft: $maxResultsDraft,
                minimum: 1,
                maximum: 100,
                maxDigitCount: 3,
                allowsEmpty: false
            )
            externalSearchFreshnessPicker(width: 222)
            externalSearchDomainListField(
                titleKey: "search.web.includeDomains",
                placeholder: "docs.example.com, github.com",
                text: $includeDomainsDraft
            )
            externalSearchDomainListField(
                titleKey: "search.web.excludeDomains",
                placeholder: "example.com",
                text: $excludeDomainsDraft
            )

            if viewModel.webSearchProvider == .anySearch {
                anySearchDomainPicker(width: 222)
                HStack(alignment: .bottom, spacing: 10) {
                    anySearchContentTypesField(width: 106)
                    anySearchZonePicker(width: 106)
                }
            }

            Button("search.github.filter.apply") {
                guard commitExternalSearchDrafts() else { return }
                Task { await viewModel.applyAnySearchFilters() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var providerPicker: some View {
        HStack(spacing: 6) {
            ForEach(ExternalSearchProviderID.allCases) { provider in
                Button {
                    Task { await viewModel.changeWebSearchProvider(provider) }
                } label: {
                    ExternalSearchProviderIcon(provider: provider, size: 15)
                        .frame(width: 34, height: 26)
                        .background(
                            viewModel.webSearchProvider == provider
                                ? Color.accentColor.opacity(0.22)
                                : Color.secondary.opacity(0.10),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(Text(verbatim: provider.displayName))
                .help(isExternalSearchProviderUsable(provider)
                    ? Text(String(format: String.l10n("search.web.provider.useFormat"), provider.displayName))
                    : Text(String(format: String.l10n("search.web.provider.requiresConfigurationFormat"), provider.displayName)))
            }
        }
    }

    private func isExternalSearchProviderUsable(_ provider: ExternalSearchProviderID) -> Bool {
        let providerSettings = AppSettings.shared.externalSearchSettings(for: provider)
        guard providerSettings.isEnabled else { return false }
        if provider == .anySearch, providerSettings.anonymousMode { return true }
        return providerSettings.hasVerifiedCredential && AppSettings.shared.externalSearchAPIKey(for: provider)?.isEmpty == false
    }

    @ViewBuilder
    private var resultContent: some View {
        if viewModel.lastSubmittedQuery.isEmpty {
            historyContent
        } else if viewModel.candidates.isEmpty, viewModel.isSearching {
            // 注意:ProgressView 这里不能直接传 LocalizedStringKey,
            // 因为 "search.searching" 的 value 是 "搜索：%@",需要把当前查询代进去。
            // 直接走 LocalizedStringKey 不会做 printf 格式化,会原样显示 %@。
            // 与 RepoListView 标题栏的写法保持一致,统一用 String(format:) 注入 query。
            ProgressView {
                Text(String(format: String.l10n("search.searching"), viewModel.lastSubmittedQuery))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isExternalSearchUnavailableEmpty {
            // 专属空态：.web scope + AnySearch 未启用。
            // 通用 "search.empty.title" 走的 errorMessages 拼接会带 "web:" 前缀
            // ("web: AnySearch 未启用"),且不可点击。这里走专属文案 + Button 一键启用，
            // 启用后自动重跑当前 query，避免用户还要再敲回车。
            // 只在 .web scope 触发：.all scope 下 AnySearch 仅是可选聚合项之一，
            // 用这条提示会误导（空态可能源自 GitHub/本地失败）。
            ContentUnavailableView {
                Text(String(format: String.l10n("search.web.provider.requiresConfigurationFormat"), viewModel.webSearchProvider.displayName))
            } description: {
                Text("search.web.provider.requiresConfigurationDescription")
            } actions: {
                if viewModel.webSearchProvider == .anySearch,
                   AppSettings.shared.externalSearchSettings(for: .anySearch).anonymousMode {
                    Button("search.empty.anySearchDisabled.action") {
                        var providerSettings = AppSettings.shared.externalSearchSettings(for: .anySearch)
                        providerSettings.isEnabled = true
                        AppSettings.shared.setExternalSearchSettings(providerSettings, for: .anySearch)
                        Task { await viewModel.submit() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.candidates.isEmpty {
            // 必须撑满剩余空间，否则 ContentUnavailableView 只占自身 intrinsic 高度,
            // 浮层 VStack 是固定 620pt 高度,子视图总高小于 frame 时 SwiftUI 会把
            // 整列内容垂直居中,造成搜索框、tabs、filter bar 全部下沉,与有结果时
            // 的"顶部贴边"布局不一致。给空状态一个 maxHeight: .infinity 即可保持
            // 上方 chrome（搜索框 / scope picker / GitHub 筛选栏）位置不变,
            // 仅在结果区域内展示空状态提示。
            ContentUnavailableView(
                "search.empty.title",
                systemImage: "magnifyingglass",
                description: Text(viewModel.errorMessages.first ?? String.l10n("search.empty.description"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(Array(viewModel.candidates.enumerated()), id: \.element.id) { index, candidate in
                    // 这里不再用 Button:macOS SwiftUI 在 List 内的 Button + onHover
                    // 对「最末行紧贴 List 边界」存在 hit-test 缩水 bug,导致最底部一行 hover
                    // 不触发(safeAreaInset / contentShape 调整都修不彻底)。改成整行
                    // .contentShape(Rectangle()) + .onTapGesture/.onHover 后,hover 命中区域
                    // 由我们显式定义,不再受 List 内 Button 容器边界影响,所有行表现一致。
                    // 牺牲点:丢掉 Button 自带的 keyboard 触发(空格/回车)和 VoiceOver 的
                    // .isButton trait,所以下面用 .accessibilityAddTraits(.isButton) 补回语义,
                    // 而 Return 键打开仍由 body 顶层 .onKeyPress(.return) 处理,不受影响。
                    candidateRow(
                        candidate,
                        isSelected: index == viewModel.selectedIndex
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        activate(candidate)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { activate(candidate) }
                    .contextMenu {
                        if case .repository(let repository) = candidate {
                            Button("search.contextMenu.openInGitHub") { onOpenURL(repository) }
                            Button("search.contextMenu.copyURL") { onCopyURL(repository) }
                            if let repo = repository.displayRepo {
                                Divider()
                                Button("search.contextMenu.aiSummary") { onOpenAI(repo) }
                                if isStarred(repo.id) {
                                    Button("search.contextMenu.unstar") { toggleStarFromContextMenu(repo) }
                                } else {
                                    Button("search.contextMenu.star") { toggleStarFromContextMenu(repo) }
                                }
                            }
                        } else if case .reference(let reference) = candidate {
                            Button("search.contextMenu.openInBrowser") { NSWorkspace.shared.open(reference.originalURL) }
                            Button("search.contextMenu.copyURL") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(reference.originalURL.absoluteString, forType: .string)
                            }
                        }
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }

                if shouldShowGitHubLoadMoreRow {
                    githubLoadMoreListRow
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }

                if shouldShowWebLoadMoreRow {
                    webLoadMoreListRow
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            }
            .listStyle(.inset)
            // List 在亮色主题默认绘制不透明白底，导致结果区与搜索浮层顶部的
            // regularMaterial 明显断层。只隐藏 scroll content 背景，行选中态继续保留。
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            // 给最底部留 8pt 透明缓冲：SwiftUI 在 `.listStyle(.inset)` 下，最后一行
            // 紧贴 List 边界时 hover hit-test 会被边界裁掉，造成最末项 hover 不触发。
            // 留出这段缓冲后，最末项有完整命中区域，hover 与其它行表现一致。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 8)
            }
            .overlay(alignment: .bottomLeading) {
                if let message = viewModel.errorMessages.first {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(interfaceScale.font(.caption))
                        .foregroundStyle(.orange)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding()
                }
            }
        }
    }

    /// 历史区域：标签流式布局 + 顶部"最近搜索 / 清空全部"。
    /// 设计要点：
    /// - 不再用 List 一行一项，避免浅色主题下 List 默认 row separator 过亮
    /// - 用 FlowLayout 让标签自动换行，每个标签底色按文本哈希从 TagColorPalette
    ///   里取一个固定色（同一关键词每次进入颜色稳定，不抖动）
    /// - 浅色 / 深色主题用不同透明度，保证两套主题下都能看见
    private var historyContent: some View {
        Group {
            if viewModel.history.isEmpty {
                // 同 resultContent 的"没有找到结果"分支,空历史也要撑满,
                // 否则首次打开浮层时搜索框会被居中下沉。
                ContentUnavailableView(
                    "search.history.empty.title",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("search.history.empty.description")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    historyHeader
                    ScrollView {
                        SearchHistoryFlowLayout(spacing: 8) {
                            ForEach(viewModel.history, id: \.id) { entry in
                                HistoryChip(
                                    entry: entry,
                                    onUse: { Task { await viewModel.useHistory(entry) } },
                                    onRemove: { Task { await viewModel.removeHistory(entry) } }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
        }
        .alert(
            "search.history.clearConfirm.title",
            isPresented: $showingClearHistoryAlert
        ) {
            Button("search.history.clearAll", role: .destructive) {
                Task { await viewModel.clearHistory() }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("search.history.clearConfirm.message")
        }
    }

    /// "最近搜索" 标题 + 右侧 "清空全部" 触发按钮。
    /// 单独抽出来避免 ScrollView 把标题也卷进去；这样在历史项很多时标题保持悬停在顶部。
    ///
    /// Clear all 始终留在左侧结果区：抽屉展开时贴在结果区右缘（面板左侧），
    /// 不 offset 进 Filters 抽屉，避免与 GitHub filters 内容重叠。
    private var historyHeader: some View {
        HStack(spacing: 0) {
            Text("search.history.recent")
                .font(interfaceScale.font(.captionStrong, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                showingClearHistoryAlert = true
            } label: {
                Label("search.history.clearAll", systemImage: "trash")
                    .font(interfaceScale.font(.captionSmall, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("search.history.clearAll.help")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func candidateRow(
        _ candidate: SearchCandidate,
        isSelected: Bool
    ) -> some View {
        Group {
            switch candidate {
            case .repository(let repo):
                let source = repositorySourceIndicator(for: repo)
                rowWithSourceIndicator(
                    source: source
                ) {
                    UnifiedRepoRow(
                        card: repo.card,
                        isSelected: isSelected,
                        showStarredCheckmark: true,
                        trailingReservedWidth: sourceIndicatorTrailingReserve(for: source)
                    )
                }
            case .reference(let reference):
                let source = reference.providerID.map(SearchResultSourceIndicator.externalProvider) ?? .web
                // 复用 RepoRowSurface 三态透明度（default / hover / selected）+
                // 圆角 + 左侧 accent bar，让网页卡片与 UnifiedRepoRow 视觉骨架对等。
                // accentColor: .blue 是"Web 类目色"，与 WebSourceBadge / RemoteFavicon
                // 背景蓝同源；hover 反馈不再单独叠加，全部走 RepoRowSurface 内置逻辑。
                rowWithSourceIndicator(source: source) {
                    RepoRowSurface(isSelected: isSelected, accentColor: .blue) {
                        HStack(alignment: .top, spacing: 12) {
                            // 左侧 32pt 容器 + 内嵌 18pt favicon。
                            // 容器 cornerRadius 6 / favicon cornerRadius 4 与 UnifiedRepoRow
                            // 头像（圆形）形成"圆形=Repo / 圆角矩形=Web"的形状区分。
                            ZStack {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.blue.opacity(0.10))
                                    .frame(width: 32, height: 32)
                                RemoteFavicon(host: reference.domain, size: 18)
                            }

                            VStack(alignment: .leading, spacing: 5) {
                                // 标题独占一行：原"网页"chip 删除（dong4j 2026-06-13 反馈：
                                // 每个网页卡片都挂同一个 chip，信息密度 0；scope 切到 .web
                                // 时所有卡片都是网页，更冗余）。需要"类目"信号时由左侧 favicon
                                // + 左侧蓝色 accent bar 自然传达。
                                Text(reference.title)
                                    .font(interfaceScale.font(.body, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let snippet = reference.snippet, !snippet.isEmpty {
                                    // dong4j 2026-06-13 反馈：浅色主题下 .secondary 在
                                    // `.regularMaterial` 浮层背景上对比度严重不足；改用
                                    // .primary.opacity(0.85)，明暗主题下都能保持"主文字仅次于标题"
                                    // 的视觉层级（不直接用 Color.black 是为了暗色主题自动适配）。
                                    Text(snippet)
                                        .font(interfaceScale.font(.caption))
                                        .foregroundStyle(.primary.opacity(0.85))
                                        .lineLimit(2)
                                }
                                // 第三行：domain · path 首段（如 "github.com · zeka-stack"），
                                // 让用户在不展开 URL 的情况下就能看出"是哪个 owner / org / 路径"。
                                // 首段为空（裸域名结果）时仅显示 domain，不显示分隔符。
                                //
                                // dong4j 2026-06-13 反馈：原 .tertiary 在浅色 material 上
                                // 几乎不可见；改用 .secondary 上提一档对比度。仍比 snippet 弱，
                                // 维持"标题 > snippet > 元信息"三档视觉权重。
                                HStack(spacing: 5) {
                                    Text(reference.domain)
                                        .font(interfaceScale.font(.captionSmall))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    if let firstPath = Self.firstPathSegment(of: reference.originalURL) {
                                        Text("·")
                                            .font(interfaceScale.font(.captionSmall))
                                            .foregroundStyle(.secondary)
                                        Text(firstPath)
                                            .font(interfaceScale.font(.captionSmall))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .padding(.trailing, sourceIndicatorTrailingReserve(for: source))
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        // hit-test 用 Rectangle 而不是 RoundedRectangle：圆角四个角会成为 onHover 死区,
        // 鼠标在角附近移入时无法触发 hover；改用矩形让整行的命中区域与可视区域一致。
        .contentShape(Rectangle())
    }

    /// 「全部」Tab 用右侧来源图标区分本地/GitHub/Web；Web Tab 也显示具体
    /// External Search Provider，避免用户看不出当前结果来自哪个服务。
    @ViewBuilder
    private func rowWithSourceIndicator<Content: View>(
        source: SearchResultSourceIndicator?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if shouldShowSourceIndicator(source), let source {
            content()
                .overlay(alignment: .trailing) {
                    SearchResultSourceIcon(source: source)
                        .padding(.trailing, 12)
                }
        } else {
            content()
        }
    }

    private func sourceIndicatorTrailingReserve(for source: SearchResultSourceIndicator?) -> CGFloat {
        shouldShowSourceIndicator(source) ? 34 : 0
    }

    private func shouldShowSourceIndicator(_ source: SearchResultSourceIndicator?) -> Bool {
        guard let source else { return false }
        if viewModel.scope == .all { return true }
        if viewModel.scope == .web {
            switch source {
            case .web, .externalProvider(_):
                return true
            case .local, .github:
                return false
            }
        }
        return false
    }

    /// 同一 repo 可能同时命中本地与 GitHub。优先显示「本地」，因为它已经是用户库内对象；
    /// 纯远端候选才显示 GitHub，避免单卡出现多来源图标造成噪音。
    private func repositorySourceIndicator(for candidate: RepositoryCandidate) -> SearchResultSourceIndicator? {
        if candidate.sources.contains(.localKeyword) || candidate.sources.contains(.localSemantic) {
            return .local
        }
        if candidate.sources.contains(.github) {
            return .github
        }
        return nil
    }

    /// URL 路径的首段（不含前导 `/`），用于 reference 卡片第三行展示。
    /// 裸域名（无 path 或 path == "/"）返回 nil。
    private static func firstPathSegment(of url: URL) -> String? {
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        return segments.first
    }

    private enum SearchResultSourceIndicator {
        case local
        case github
        case web
        case externalProvider(ExternalSearchProviderID)
    }

    private struct SearchResultSourceIcon: View {
        let source: SearchResultSourceIndicator

        var body: some View {
            icon
                .foregroundStyle(tint)
                .frame(width: 12, height: 12)
                .padding(4)
                .background(tint.opacity(0.10), in: Circle())
                .overlay {
                    Circle()
                        .stroke(tint.opacity(0.18), lineWidth: 0.5)
                }
                .help(helpText)
                .accessibilityLabel(helpText)
        }

        @ViewBuilder
        private var icon: some View {
            switch source {
            case .local:
                Image(systemName: "internaldrive")
                    .font(.system(size: 11, weight: .semibold))
            case .github:
                Image("github")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            case .web:
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
            case .externalProvider(let provider):
                ExternalSearchProviderIcon(provider: provider, size: 12)
            }
        }

        private var tint: Color {
            switch source {
            case .local: return .secondary
            case .github: return .primary
            case .web: return .blue
            case .externalProvider(let provider):
                return ExternalSearchProviderIcon.tint(for: provider)
            }
        }

        private var helpText: Text {
            switch source {
            case .local: return Text("search.scope.local")
            case .github: return Text(verbatim: "GitHub")
            case .web: return Text("search.scope.web")
            case .externalProvider(let provider):
                return Text(verbatim: provider.displayName)
            }
        }
    }

    private struct ExternalSearchProviderIcon: View {
        let provider: ExternalSearchProviderID
        let size: CGFloat

        var body: some View {
            icon
                .foregroundStyle(Self.tint(for: provider))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }

        @ViewBuilder
        private var icon: some View {
            switch provider {
            case .anySearch:
                Image(systemName: "asterisk")
                    .font(.system(size: size, weight: .bold))
            case .tavily:
                Image(systemName: "bolt.fill")
                    .font(.system(size: size, weight: .semibold))
            case .exa:
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: size, weight: .semibold))
            case .braveLLMContext:
                Image(systemName: "shield.fill")
                    .font(.system(size: size, weight: .semibold))
            }
        }

        static func tint(for provider: ExternalSearchProviderID) -> Color {
            switch provider {
            case .anySearch:
                return .orange
            case .tavily:
                return .pink
            case .exa:
                return .purple
            case .braveLLMContext:
                return .orange
            }
        }
    }

    // MARK: - 搜索底部 footer（GitHub pagination + web metadata）

    /// GitHub scope 的分页入口必须作为列表最后一行，而不是固定在面板底部。
    /// 这样用户滚到当前页末尾时才会看到“查看更多”，追加下一页后入口自然跟到新末尾。
    private var shouldShowGitHubLoadMoreRow: Bool {
        viewModel.scope == .github
            && !viewModel.lastSubmittedQuery.isEmpty
            && !viewModel.candidates.isEmpty
            && (viewModel.canLoadMoreGitHub || viewModel.isLoadingGitHub)
    }

    private var shouldShowWebLoadMoreRow: Bool {
        viewModel.scope == .web
            && !viewModel.lastSubmittedQuery.isEmpty
            && !viewModel.candidates.isEmpty
            && (viewModel.canLoadMoreWeb || viewModel.isLoadingWeb)
    }

    private var githubLoadMoreListRow: some View {
        loadMoreListRow(isLoading: viewModel.isLoadingGitHub) {
            Task { await viewModel.loadMoreGitHub() }
        }
    }

    private var webLoadMoreListRow: some View {
        loadMoreListRow(isLoading: viewModel.isLoadingWeb) {
            Task {
                await viewModel.loadMoreWeb()
                maxResultsDraft = String(viewModel.externalSearchFilters.maxResults)
            }
        }
    }

    private func loadMoreListRow(
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Spacer()
            Button {
                action()
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                    }
                    Text("search.github.loadMore")
                        .font(interfaceScale.font(.captionStrong, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(isLoading)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// 浮层底部 footer。按 scope 分支渲染：
    ///
    /// - **`.web`**（仅网页）：左侧"X 条 · Y.Ys"汇总 chip + 右侧 rate limit chip
    /// - **`.all`**（聚合）：左侧多段 chip"本地 N · GitHub M · 网页 K"（按 provider
    ///   命中数依次展示）+ 右侧 rate limit chip（仅当 web 参与且已加载）
    /// - **`.local` / `.github`**：不渲染 footer
    ///
    /// 关键约束（不要回退）：
    /// - footer 渲染条件 = "至少有一个 chip 可显示"：
    ///   - 至少一个 provider 已加载（resultCounts 非空），或
    ///   - rate limit chip 可显示（webMetadata.rateLimit 非 nil）
    /// - rate limit 三字段缺一不全 → 右侧 chip 不显示（左侧 metadata 仍渲染）
    /// - remaining ≤ 0 时右侧 chip 切换到"额度用尽 · HH:mm 重置"
    @ViewBuilder
    private var webResultFooter: some View {
        let counts = viewModel.resultCounts
        let rateLimit = viewModel.webMetadata?.rateLimit
        if !counts.isEmpty || rateLimit != nil {
            HStack(spacing: 8) {
                leadingSummaryContent(counts: counts)
                Spacer(minLength: 8)
                if let rateLimit {
                    rateLimitChip(rateLimit)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.025))
        }
    }

    /// 左侧汇总区。根据当前 scope 选择渲染策略：
    /// - `.web` scope + 只有 web：用 `searchSummaryChip` 显示"X 条·Y.Ys"（含用时）
    /// - 其他场景（聚合 / 单 source 但不是 .web）：用多段 sourceChip 串接，
    ///   不显示用时（"用时"概念只有 web 上可靠，本地 / GitHub 没记录）
    @ViewBuilder
    private func leadingSummaryContent(counts: [ResultSourceCount]) -> some View {
        if viewModel.scope == .web,
           let webMetadata = viewModel.webMetadata,
           let total = webMetadata.totalResults,
           let ms = webMetadata.searchTimeMs {
            // .web scope 走"含用时"的紧凑形态（保留 v1 体验）
            webOnlySummaryChip(totalResults: total, timeMs: ms)
        } else {
            // 聚合形态：每个 source 一个 chip，按 viewModel.resultCounts 顺序排
            HStack(spacing: 6) {
                ForEach(counts) { entry in
                    sourceCountChip(entry)
                }
            }
        }
    }

    /// `.web` scope 专用 chip：放大镜 + "X 条结果 · Y.Ys"（含用时）。
    /// 用时只有 web 来源可靠取到，本地 / GitHub 没记录，所以仅在 .web 单源场景渲染。
    private func webOnlySummaryChip(totalResults: Int, timeMs: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
            Text(String(
                format: String.l10n("search.web.summaryFormat"),
                totalResults,
                Double(timeMs) / 1000.0
            ))
            .font(interfaceScale.font(.captionSmall, weight: .medium))
            .lineLimit(1)
        }
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.08), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 聚合 footer 的单段 chip：source 标签 + 数字。
    /// 例如 "本地 3" / "GitHub 10" / "网页 20"。
    /// 视觉规格与 webOnlySummaryChip 完全一致，让 .all 与 .web scope 切换时不抖动。
    private func sourceCountChip(_ entry: ResultSourceCount) -> some View {
        HStack(spacing: 4) {
            Text(String(
                format: String.l10n("search.footer.summaryFormat"),
                String.l10n(entry.labelKey),
                entry.count
            ))
            .font(interfaceScale.font(.captionSmall, weight: .medium).monospacedDigit())
            .lineLimit(1)
        }
        .foregroundStyle(.primary.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.primary.opacity(0.08), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 右侧 rate limit chip：未用尽走"已用 N/M"形态，用尽走"额度用尽 · 重置时间"。
    ///
    /// **语义重要变更（dong4j 2026-06-14）**：`sessionUsed` 来自本地计数（每次搜索 +1），
    /// 不是 API 返回的 remaining（恒定假值）。详见 `WebRateLimit` 注释。
    @ViewBuilder
    private func rateLimitChip(_ rateLimit: WebRateLimit) -> some View {
        if rateLimit.isExhausted {
            exhaustedRateLimitChip(rateLimit)
        } else {
            normalRateLimitChip(rateLimit)
        }
    }

    /// 未用尽 chip：圆点 + "已用 N/M"，颜色按 fractionRemaining 三档（>50% 绿 / 20-50% 橙 / ≤20% 红）。
    /// 颜色反映「还能用多少」的紧迫感，与文案「已用」相反但语义互补。
    ///
    /// 视觉规格（dong4j 2026-06-13）：背景 22% + 描边 35% + size 11 .semibold，
    /// 明暗主题都清晰可读。
    private func normalRateLimitChip(_ rateLimit: WebRateLimit) -> some View {
        let color = Self.rateLimitColor(fraction: rateLimit.fractionRemaining)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(String(
                format: String.l10n("search.web.rate.usedFormat"),
                rateLimit.sessionUsed,
                rateLimit.limit
            ))
            .font(interfaceScale.font(.captionSmall, weight: .semibold).monospacedDigit())
            .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.22), in: Capsule())
        .overlay { Capsule().stroke(color.opacity(0.35), lineWidth: 0.8) }
        .fixedSize(horizontal: true, vertical: false)
        .help(rateLimitTooltip(rateLimit))
    }

    /// 用尽 chip：红色 + "额度用尽 · HH:mm 重置"，传达"短时间内不可继续搜"。
    /// 同步加强对比度（背景 22% + 描边 + .semibold），与 normalRateLimitChip 统一。
    private func exhaustedRateLimitChip(_ rateLimit: WebRateLimit) -> some View {
        let resetText = Self.shortResetText(from: rateLimit.resetAt)
        let title = String(format: String.l10n("search.web.rate.exhaustedFormat"), resetText)
        return HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Text(title)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.red.opacity(0.22), in: Capsule())
        .overlay { Capsule().stroke(Color.red.opacity(0.35), lineWidth: 0.8) }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// hover tooltip："本次会话已用 N/M · HH:mm 后 API 端窗口重置"。
    /// 重点向用户解释：N 是本地会话计数（重启归零），M 是 API 真实上限，
    /// 重置时间来自 API（指 API 端的窗口重置，不是本地 counter）。
    private func rateLimitTooltip(_ rateLimit: WebRateLimit) -> String {
        let resetText = Self.shortResetText(from: rateLimit.resetAt)
        return String(
            format: String.l10n("search.web.rate.tooltipFormat"),
            rateLimit.sessionUsed,
            rateLimit.limit,
            resetText
        )
    }

    /// 三档染色阈值（>50% 绿 / >20% 橙 / ≤20% 红）。
    /// 与 GitHub / 大多 API 仪表盘的视觉惯例一致，给用户"还能用 / 该悠着点 / 快没了"
    /// 三级视觉信号；阈值确认（dong4j 2026-06-13）。
    static func rateLimitColor(fraction: Double) -> Color {
        if fraction > 0.5 { return .green }
        if fraction > 0.2 { return .orange }
        return .red
    }

    /// 把 reset 时间格式化为本地短时（如 "02:30"）。
    /// 用 `DateFormatter` 而不是 `Date.formatted(date:time:)`：后者在某些 locale 会
    /// 多出 "AM/PM" 后缀（en_US），跟 zh-Hans 的 24h 视觉不一致；强制 .short timeStyle
    /// + .none dateStyle 保证两种语言下都是纯时间。
    static func shortResetText(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// 候选项的"激活"动作（点击 / 回车 / VoiceOver 主操作）。
    /// 远端仓库（仅 GitHub 搜出、未 star、未入本地库）走会话级详情 sheet；
    /// 其余（本地、reference、已 star）由宿主决定打开方式，统一走 onOpenCandidate。
    ///
    /// SEARCH-RICH 2026-06-14：sheet 改成接收整张 `RepositoryCandidate`
    /// （`remoteExtras` 由 GitHub Provider 填充，弹窗用来渲染状态徽章与匹配度），
    /// 不再只传 `Repo`。判断"是否走 remote sheet"的条件保持不变：
    /// `localRepo == nil && remoteRepo != nil` —— 即仅 GitHub 搜到、本地未入库。
    private func activate(_ candidate: SearchCandidate) {
        if case .repository(let repository) = candidate,
           repository.localRepo == nil,
           repository.remoteRepo != nil {
            remoteDetailCandidate = repository
        } else {
            onOpenCandidate(candidate)
        }
    }

    private func toggleStarFromContextMenu(_ repo: Repo) {
        Task {
            do {
                _ = try await onToggleStar(repo)
            } catch {
                AppLog.network.error("Search context menu star toggle failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var libraryToastIcon: String {
        libraryToast == "library.action.failed" ? "exclamationmark.triangle.fill" : "heart.fill"
    }

    private var libraryToastIconColor: Color? {
        libraryToast == "library.action.added" ? .red : nil
    }

    /// Search Center 也可能展示 README 底部状态栏，知识库 toast 统一上浮，
    /// 保持与详情页的反馈位置一致。
    private var libraryToastBottomPadding: CGFloat {
        30
    }

    private func handleLibraryToggleTapped(_ candidate: RepositoryCandidate) async -> Bool? {
        guard dependencies.authSession.state.isAuthenticated else {
            dependencies.authSession.requestLoginSheet()
            return nil
        }
        guard libraryOperationRepoID == nil else { return nil }
        guard let repo = candidate.displayRepo, repo.id > 0 else {
            libraryToast = "library.action.failed"
            return nil
        }

        libraryOperationRepoID = repo.id
        defer { libraryOperationRepoID = nil }

        let currentState = (try? await dependencies.repoNoteRepository.fetchLibraryState(repoId: repo.id))
            ?? (candidate.card.isInLibrary ? .inLibrary : .outsideLibrary)
        if currentState == .inLibrary {
            let status = (try? await dependencies.repoNoteRepository.find(repoId: repo.id))
                .map { RepoStatus.parse($0.status) } ?? homeViewModel.readStatus(for: repo.id)
            guard status != .using else {
                viewModel.updateRepositoryLibraryState(
                    identity: candidate.identity,
                    state: currentState,
                    persistedRepo: candidate.localRepo
                )
                pendingUsingRemovalCandidate = candidate
                isConfirmingUsingLibraryRemoval = true
                return true
            }
            return await setLibraryState(.outsideLibrary, for: candidate, downgradeUsingStatus: false)
        } else {
            return await setLibraryState(.inLibrary, for: candidate, downgradeUsingStatus: false)
        }
    }

    private func setLibraryState(
        _ targetState: LibraryState,
        for candidate: RepositoryCandidate,
        downgradeUsingStatus: Bool
    ) async -> Bool? {
        guard dependencies.authSession.state.isAuthenticated else {
            dependencies.authSession.requestLoginSheet()
            return nil
        }
        guard let repo = candidate.displayRepo, repo.id > 0 else {
            libraryToast = "library.action.failed"
            return nil
        }

        libraryOperationRepoID = repo.id
        defer {
            libraryOperationRepoID = nil
            pendingUsingRemovalCandidate = nil
        }

        do {
            let persistedRepo: Repo?
            if targetState == .inLibrary {
                persistedRepo = try await dependencies.repoRepository.upsertRepoMetadataForLibrary(
                    repo: repo,
                    syncedAt: Date()
                )
            } else {
                persistedRepo = candidate.localRepo
            }
            try await dependencies.repoNoteRepository.updateLibraryState(repoId: repo.id, state: targetState)
            if downgradeUsingStatus {
                try await dependencies.repoNoteRepository.updateStatus(repoId: repo.id, status: .read)
            }

            viewModel.updateRepositoryLibraryState(
                identity: candidate.identity,
                state: targetState,
                persistedRepo: persistedRepo
            )
            homeViewModel.applyLibraryStateChange(repoId: repo.id, state: targetState)
            await homeViewModel.refreshSidebar()
            await homeViewModel.reloadItems(forceRefresh: true)
            libraryToast = targetState == .inLibrary ? "library.action.added" : "library.action.removed"
            return targetState == .inLibrary
        } catch {
            AppLog.database.error("Search Center library toggle failed repo=\(repo.fullName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            libraryToast = "library.action.failed"
            return nil
        }
    }

    private func scopeTitle(_ scope: SearchScope) -> String {
        switch scope {
        case .all: return String.l10n("search.scope.all")
        case .local: return String.l10n("search.scope.local")
        case .github: return "GitHub"
        case .web: return String.l10n("search.scope.web")
        }
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<GitHubSearchFilters, String?>) -> Binding<String> {
        Binding(
            get: { viewModel.githubFilters[keyPath: keyPath] ?? "" },
            set: { value in
                viewModel.githubFilters[keyPath: keyPath] = value.isEmpty ? nil : value
            }
        )
    }

    private func githubTextFilter(titleKey: LocalizedStringKey, placeholderKey: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            filterFieldLabel(titleKey)
            TextField(placeholderKey, text: text)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }

    /// “全部语言”对应 nil，不生成 GitHub `language:` qualifier；其余选项直接来自
    /// Starcat 本地 Star 列表的 languageStats，与 Sidebar 的语言口径保持一致。
    private func githubLanguagePicker(width: CGFloat = 128) -> some View {
        githubPicker(titleKey: "search.github.filter.language", width: width) {
            Picker("search.github.filter.language", selection: optionalLanguageBinding) {
                Text("search.github.filter.language.all").tag("")
                ForEach(languages) { stat in
                    Text(stat.displayName).tag(stat.language)
                }
            }
        }
    }

    private var optionalLanguageBinding: Binding<String> {
        Binding(
            get: { viewModel.githubFilters.language ?? "" },
            set: { viewModel.githubFilters.language = $0.isEmpty ? nil : $0 }
        )
    }

    private func githubSortPicker(width: CGFloat) -> some View {
        githubPicker(titleKey: "search.github.filter.sortBy", width: width) {
            Picker("search.github.filter.sortBy", selection: $viewModel.githubFilters.sort) {
                Text("search.github.sort.bestMatch").tag(GitHubSearchSort.bestMatch)
                Text("Stars").tag(GitHubSearchSort.stars)
                Text("Forks").tag(GitHubSearchSort.forks)
                Text("search.github.sort.updated").tag(GitHubSearchSort.updated)
            }
        }
    }

    private func githubOrderPicker(width: CGFloat) -> some View {
        githubPicker(titleKey: "search.github.filter.order", width: width) {
            Picker("search.github.filter.order", selection: $viewModel.githubFilters.order) {
                Text("search.github.order.descending").tag(SearchOrder.descending)
                Text("search.github.order.ascending").tag(SearchOrder.ascending)
            }
        }
    }

    private func filterFieldLabel(_ titleKey: LocalizedStringKey) -> some View {
        Text(titleKey)
            .font(interfaceScale.font(.caption, weight: .medium))
            .foregroundStyle(.secondary)
    }

    /// Picker 的标题放到控件上方，避免 macOS 自动把 label 挤在选择框左侧，造成
    /// “排序 Best m…”这类横向截断。调用方仍传原生 Picker，交互行为不变。
    private func githubPicker<Content: View>(
        titleKey: LocalizedStringKey,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            filterFieldLabel(titleKey)
            content()
                .labelsHidden()
        }
        .frame(width: width, alignment: .leading)
    }

    /// 日期筛选字段（SEARCH-FILTER 2026-06-14 改造）。
    ///
    /// 老实现：`DatePicker(...).datePickerStyle(.compact)` —— 文档承诺渲染成
    /// 「按钮 + popover」，但 macOS 26 (Tahoe) 实测下退化到 stepper field（数字
    /// 字段 + 上下箭头），dong4j 截图反馈不希望出现上下箭头操作日期。
    ///
    /// 新实现：用 `GitHubDateFilterField`（同文件下方）—— 显式 Button + popover
    /// + `.graphical` DatePicker，绕开 `.compact` 在新版 macOS 上的样式 fallback，
    /// 同时把"点击 → 弹出可视化月历选择"的交互固化下来。
    private func githubDateFilter(
        titleKey: LocalizedStringKey,
        keyPath: WritableKeyPath<GitHubSearchFilters, Date?>
    ) -> some View {
        GitHubDateFilterField(
            titleKey: titleKey,
            date: Binding(
                get: { viewModel.githubFilters[keyPath: keyPath] },
                set: { viewModel.githubFilters[keyPath: keyPath] = $0 }
            )
        )
    }

    // MARK: - AnySearch 筛选条 helpers（PR-3，dong4j 2026-06-14）

    /// AnySearch domain 下拉。
    ///
    /// 首项「自动」对应 nil（不传 `domain` 给 API，网关按 query 自动路由），其余
    /// 22 项来自官方 enum（hard-code 在 `Self.allAnySearchDomains`）。domain 是 API
    /// 关键字，**不本地化**；中文用户可通过括号注释快速辨识（如 `code（代码）`）。
    private func anySearchDomainPicker(width: CGFloat = 158) -> some View {
        githubPicker(titleKey: "search.anysearch.domain", width: width) {
            Picker("Domain", selection: anySearchDomainBinding) {
                Text("search.anysearch.domain.auto").tag("")
                ForEach(Self.allAnySearchDomains, id: \.0) { pair in
                    Text(LocalizedStringKey(pair.1)).tag(pair.0)
                }
            }
        }
    }

    private var anySearchDomainBinding: Binding<String> {
        Binding(
            get: { viewModel.anySearchFilters.domain ?? "" },
            set: { viewModel.anySearchFilters.domain = $0.isEmpty ? nil : $0 }
        )
    }

    /// content_types 多选：macOS 原生 `Picker` 不支持 Set 多选（会退化为单选），
    /// 故用 Popover + Toggle。触发器视觉对齐 `GitHubDateFilterField` / 同行 Picker。
    private func anySearchContentTypesField(width: CGFloat = 140) -> some View {
        AnySearchContentTypesField(
            contentTypes: Binding(
                get: { viewModel.anySearchFilters.contentTypes },
                set: { viewModel.anySearchFilters.contentTypes = $0 }
            ),
            options: Self.allAnySearchContentTypes,
            width: width
        )
    }

    /// AnySearch zone 下拉。首项「自动」对应 nil，跟随网关自动路由。
    private func anySearchZonePicker(width: CGFloat = 100) -> some View {
        githubPicker(titleKey: "search.anysearch.zone", width: width) {
            Picker("Zone", selection: anySearchZoneBinding) {
                Text("search.anysearch.zone.auto").tag("")
                Text("search.anysearch.zone.cn").tag(AnySearchZone.cn.rawValue)
                Text("search.anysearch.zone.intl").tag(AnySearchZone.intl.rawValue)
            }
        }
    }

    private var anySearchZoneBinding: Binding<String> {
        Binding(
            get: { viewModel.anySearchFilters.zone?.rawValue ?? "" },
            set: { newValue in
                viewModel.anySearchFilters.zone = newValue.isEmpty
                    ? nil
                    : AnySearchZone(rawValue: newValue)
            }
        )
    }

    /// 折叠态摘要：把当前生效的非默认筛选拼成「code · web,doc · 全球 · 10 条」。
    /// 全默认时显示「自动（按 query 路由）」，让用户即便不展开也能确认状态。
    private var anySearchFiltersSummary: String {
        let f = viewModel.anySearchFilters
        let external = viewModel.externalSearchFilters
        var parts: [String] = []
        if external.maxResults != 10 {
            parts.append(String(format: String.l10n("search.anysearch.summary.count"), external.maxResults))
        }
        if external.freshness != .any {
            parts.append(external.freshness.rawValue)
        }
        if !external.includeDomains.isEmpty {
            parts.append("include:\(external.includeDomains.sorted().joined(separator: ","))")
        }
        if !external.excludeDomains.isEmpty {
            parts.append("exclude:\(external.excludeDomains.sorted().joined(separator: ","))")
        }
        if let domain = f.domain { parts.append(domain) }
        if !f.contentTypes.isEmpty {
            let ordered = Self.allAnySearchContentTypes
                .compactMap { f.contentTypes.contains($0.0) ? $0.0 : nil }
            parts.append(ordered.joined(separator: ","))
        }
        if let zone = f.zone {
            parts.append(zone == .cn
                ? String.l10n("search.anysearch.zone.cn")
                : String.l10n("search.anysearch.zone.intl"))
        }
        return parts.isEmpty
            ? String.l10n("search.anysearch.summary.auto")
            : parts.joined(separator: " · ")
    }

    /// AnySearch 22 个 domain 显示对照表。
    ///
    /// 元组 `(rawValue, i18nKey)`：rawValue 直接传给 API（不本地化），
    /// i18nKey 通过 `String.l10n` / `Text(LocalizedStringKey(...))` 渲染本地化文案。
    /// 完整顺序照搬官方文档：
    /// https://www.anysearch.com/docs → Enum Reference → Domains (22 values)
    ///
    /// 维护提示：API 端新增 domain 时同步追加；保持与官方枚举顺序一致便于查阅。
    private static let allAnySearchDomains: [(String, String)] = [
        ("general", "search.anysearch.domain.general"),
        ("code", "search.anysearch.domain.code"),
        ("tech", "search.anysearch.domain.tech"),
        ("fashion", "search.anysearch.domain.fashion"),
        ("travel", "search.anysearch.domain.travel"),
        ("home", "search.anysearch.domain.home"),
        ("ecommerce", "search.anysearch.domain.ecommerce"),
        ("gaming", "search.anysearch.domain.gaming"),
        ("film", "search.anysearch.domain.film"),
        ("music", "search.anysearch.domain.music"),
        ("finance", "search.anysearch.domain.finance"),
        ("academic", "search.anysearch.domain.academic"),
        ("legal", "search.anysearch.domain.legal"),
        ("business", "search.anysearch.domain.business"),
        ("ip", "search.anysearch.domain.ip"),
        ("security", "search.anysearch.domain.security"),
        ("education", "search.anysearch.domain.education"),
        ("health", "search.anysearch.domain.health"),
        ("religion", "search.anysearch.domain.religion"),
        ("geo", "search.anysearch.domain.geo"),
        ("environment", "search.anysearch.domain.environment"),
        ("energy", "search.anysearch.domain.energy")
    ]

    /// content_types 预设选项。官方文档未给完整枚举，先开 3 个最常见的；
    /// 用户反馈需要其他类型（如 image / video）时再扩展。
    /// 元组 `(rawValue, i18nKey)`：i18nKey 渲染时走本地化查找。
    private static let allAnySearchContentTypes: [(String, String)] = [
        ("web", "search.anysearch.contentType.web"),
        ("news", "search.anysearch.contentType.news"),
        ("doc", "search.anysearch.contentType.doc")
    ]

    /// 筛选抽屉打开时把已生效的数值筛选复制到输入草稿。
    ///
    /// 数值输入不直接绑定 ViewModel：用户可能只是在编辑草稿，只有点「应用筛选」
    /// 才代表要触发远端搜索。这样不会出现输入到一半就发请求或把非法值写进筛选条件。
    private func syncNumericFilterDrafts() {
        minStarsDraft = viewModel.githubFilters.minimumStars.map(String.init) ?? ""
        maxResultsDraft = String(viewModel.externalSearchFilters.maxResults)
        includeDomainsDraft = viewModel.externalSearchFilters.includeDomains.sorted().joined(separator: ", ")
        excludeDomainsDraft = viewModel.externalSearchFilters.excludeDomains.sorted().joined(separator: ", ")
    }

    /// 提交 GitHub 最低 Stars。空值表示“不限制”；非空必须是正整数。
    private func commitMinStarsDraft() -> Bool {
        let validation = SearchFilterNumericField.validate(
            minStarsDraft,
            minimum: 1,
            maximum: nil,
            allowsEmpty: true
        )
        switch validation {
        case .empty:
            viewModel.githubFilters.minimumStars = nil
            return true
        case .ok:
            viewModel.githubFilters.minimumStars = Int(minStarsDraft)
            return true
        case .emptyRequired, .nonNumericAttempt, .belowMinimum, .aboveMaximum:
            return false
        }
    }

    /// 提交 Web 公共筛选。Provider API 上限不完全一致，Starcat 先统一钳制到 1...100。
    private func commitExternalSearchDrafts() -> Bool {
        let validation = SearchFilterNumericField.validate(
            maxResultsDraft,
            minimum: 1,
            maximum: 100,
            allowsEmpty: false
        )
        guard case .ok = validation, let value = Int(maxResultsDraft) else {
            return false
        }
        viewModel.externalSearchFilters.maxResults = value
        viewModel.externalSearchFilters.includeDomains = Self.parseDomainList(includeDomainsDraft)
        viewModel.externalSearchFilters.excludeDomains = Self.parseDomainList(excludeDomainsDraft)
        return true
    }

    private func externalSearchFreshnessPicker(width: CGFloat) -> some View {
        githubPicker(titleKey: "search.web.freshness", width: width) {
            Picker("search.web.freshness", selection: externalSearchFreshnessBinding) {
                Text("search.web.freshness.any").tag(ExternalSearchFilters.Freshness.any)
                Text("search.web.freshness.day").tag(ExternalSearchFilters.Freshness.day)
                Text("search.web.freshness.week").tag(ExternalSearchFilters.Freshness.week)
                Text("search.web.freshness.month").tag(ExternalSearchFilters.Freshness.month)
                Text("search.web.freshness.year").tag(ExternalSearchFilters.Freshness.year)
            }
        }
    }

    private var externalSearchFreshnessBinding: Binding<ExternalSearchFilters.Freshness> {
        Binding(
            get: { viewModel.externalSearchFilters.freshness },
            set: { viewModel.externalSearchFilters.freshness = $0 }
        )
    }

    private func externalSearchDomainListField(
        titleKey: LocalizedStringKey,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(titleKey)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(interfaceScale.font(.caption))
        }
    }

    private static func parseDomainList(_ raw: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: ",， \n\t")
        let values = raw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        return Set(values)
    }
}

// MARK: - Search Filter Numeric Field

/// 搜索筛选抽屉里的正整数输入框。
///
/// SwiftUI `TextField(value:format:)` 在 macOS 上对空值、粘贴字母、局部非法输入的反馈
/// 不够稳定；这里改用 `String` 草稿，只保留数字字符，并在提交前按字段自己的范围校验。
private struct SearchFilterNumericField: View {
    let titleKey: LocalizedStringKey
    let placeholder: String
    let hintKey: String
    @Binding var draft: String
    let minimum: Int
    let maximum: Int?
    let maxDigitCount: Int
    let allowsEmpty: Bool

    @State private var validation: SearchFilterNumericValidation = .empty
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(titleKey)
                .font(interfaceScale.font(.caption, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(interfaceScale.font(.caption, design: .monospaced))
                .multilineTextAlignment(.leading)
                .lineLimit(1)
                .onChange(of: draft) { _, newValue in
                    let hadInvalidChars = newValue.contains { !$0.isNumber }
                    let filtered = String(newValue.filter(\.isNumber).prefix(maxDigitCount))
                    if filtered != newValue {
                        draft = filtered
                    }
                    validation = Self.validate(
                        filtered,
                        minimum: minimum,
                        maximum: maximum,
                        allowsEmpty: allowsEmpty,
                        hadInvalidChars: hadInvalidChars
                    )
                }

            Text(verbatim: validation.hintText(defaultKey: hintKey, minimum: minimum, maximum: maximum))
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(validation.isError ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            validation = Self.validate(draft, minimum: minimum, maximum: maximum, allowsEmpty: allowsEmpty)
        }
    }

    static func validate(
        _ draft: String,
        minimum: Int,
        maximum: Int?,
        allowsEmpty: Bool,
        hadInvalidChars: Bool = false
    ) -> SearchFilterNumericValidation {
        if hadInvalidChars { return .nonNumericAttempt }
        if draft.isEmpty { return allowsEmpty ? .empty : .emptyRequired }
        guard let value = Int(draft) else { return .nonNumericAttempt }
        if value < minimum { return .belowMinimum }
        if let maximum, value > maximum { return .aboveMaximum }
        return .ok
    }
}

private enum SearchFilterNumericValidation: Equatable {
    case empty
    case emptyRequired
    case ok
    case nonNumericAttempt
    case belowMinimum
    case aboveMaximum

    var isError: Bool {
        switch self {
        case .empty, .ok: return false
        case .emptyRequired, .nonNumericAttempt, .belowMinimum, .aboveMaximum: return true
        }
    }

    func hintText(defaultKey: String, minimum: Int, maximum: Int?) -> String {
        switch self {
        case .empty, .ok:
            return String.l10n(defaultKey)
        case .emptyRequired:
            return String.l10n("search.filter.numeric.error.required")
        case .nonNumericAttempt:
            return String.l10n("search.filter.numeric.error.digitsOnly")
        case .belowMinimum:
            return String(format: String.l10n("search.filter.numeric.error.tooLowFormat"), minimum)
        case .aboveMaximum:
            return String(format: String.l10n("search.filter.numeric.error.tooHighFormat"), maximum ?? minimum)
        }
    }
}

// MARK: - AnySearch Content Types Field

/// Web 筛选「内容类型」多选字段。
///
/// macOS SwiftUI 的 `Picker(selection: Set)` 实测无法多选（会当作单选），
/// `Menu + Toggle` 又因 `.menuStyle(.borderlessButton)` 与自绘 label 冲突而变形。
/// 本组件用 **Popover + Toggle** 保证多选可用，触发器沿用 `GitHubDateFilterField`
/// 的圆角描边样式，与同行 Picker / TextField 等高对齐。
private struct AnySearchContentTypesField: View {
    @Binding var contentTypes: Set<String>
    let options: [(String, String)]
    let width: CGFloat

    @State private var isPresented = false
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("search.anysearch.contentTypes")
                .font(interfaceScale.font(.caption, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                isPresented.toggle()
            } label: {
                fieldLabel
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                selectionPopover
                    .appLocaleEnvironment()
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// 触发器：仿 `.roundedBorder` / 原生 PopUpButton，右侧 chevron 与 zone Picker 一致。
    private var fieldLabel: some View {
        HStack(spacing: 6) {
            Text(displayText)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(contentTypes.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    /// Popover 内 Toggle 可多选；勾选即时写回 binding，点击外部或 Esc 关闭即可。
    private var selectionPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(options, id: \.0) { pair in
                Toggle(LocalizedStringKey(pair.1), isOn: toggleBinding(for: pair.0))
            }
        }
        .padding(14)
        .fixedSize()
    }

    private func toggleBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { contentTypes.contains(key) },
            set: { isOn in
                if isOn {
                    contentTypes.insert(key)
                } else {
                    contentTypes.remove(key)
                }
            }
        )
    }

    /// 空集显示「自动」；非空按 `options` 定义序拼接本地化名称。
    private var displayText: String {
        if contentTypes.isEmpty { return String.l10n("search.anysearch.zone.auto") }
        return options
            .compactMap { contentTypes.contains($0.0) ? String.l10n($0.1) : nil }
            .joined(separator: ", ")
    }
}

// MARK: - GitHub Date Filter Field

/// GitHub 筛选条件中的日期选择字段（搜索弹窗专用）。
///
/// ## 为什么自绘 Button + popover，而不是直接用 `DatePicker(.compact)`
///
/// macOS 上 `DatePicker(...).datePickerStyle(.compact)` 历史承诺是「按钮 + 弹出
/// 月历 popover」样式，但在 macOS 15 / 26 (Tahoe) 的 SwiftUI build 上实测会退化
/// 到 stepper field（数字字段 + 上下箭头）。dong4j 2026-06-14 截图反馈明确不想
/// 看到上下箭头操作日期。
///
/// 另外，图形日历比上下箭头更适合「最近 N 天 / 某个月之后」这类 GitHub 筛选
/// 语义：鼠标点选某一天比按箭头逐日翻找快得多。
///
/// ## 交互模型
///
/// - 主体：圆角矩形按钮，左侧 📅 图标，中间日期文本（未选择时显示「选择日期」
///   + secondary 颜色），右侧 ⌄ 图标。视觉与 TextField / Picker 等高一致，
///   能无缝混在筛选行 HStack 里
/// - 点击：弹出 popover（`arrowEdge: .bottom`，让箭头指向触发按钮），内嵌
///   `.graphical` DatePicker 完整月历
/// - 选日：DatePicker setter 即时回写 binding（`@Binding var date: Date?`），
///   用户能在 popover 仍打开时切换月份继续探索
/// - 关闭：底部右侧「完成」按钮 / 点击 popover 外部区域 / esc
///
/// ## 不在 popover 内放「清除」按钮的原因
///
/// 调用方（`SearchCenterView.githubFilterSection`）已经在 section 底部提供「清除日期」
/// 按钮，会同时把创建时间和推送时间复位。如果 popover 内再放一个单字段「清除」，
/// 用户会困惑「该用哪个」。所以这里保持单一职责：popover 只负责选日期，清除
/// 由筛选 section 统一处理。
private struct GitHubDateFilterField: View {
    let titleKey: LocalizedStringKey
    /// 真实数据源。nil 表示「用户未指定该筛选条件」，写筛选时不生成 qualifier；
    /// popover 内只要用户点过任一日期就写入真实值，binding setter 立刻把 nil
    /// 升级为具体 Date。
    @Binding var date: Date?

    @State private var isPresented = false
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    /// 显示宽度与原 `.compact` DatePicker 持平（150pt），保证旧布局横向对齐
    /// 不发生跳变。两个并排的日期字段加起来 ~316pt，落在筛选行剩余空间内。
    private static let fieldWidth: CGFloat = 150

    /// 主体显示用日期格式：`yyyy/MM/dd`。与截图中 dong4j 习惯的中式日期格式一致，
    /// 也跟 `.compact` 旧样式默认输出对齐，避免用户切换布局后认不出。
    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(titleKey)
                .font(interfaceScale.font(.caption, weight: .medium))
                .foregroundStyle(.secondary)

            Button {
                isPresented.toggle()
            } label: {
                fieldLabel
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                calendarPopover
                    .appLocaleEnvironment()
            }
        }
        .frame(width: Self.fieldWidth, alignment: .leading)
    }

    /// 按钮主体视觉。整体仿照 `.roundedBorder` TextField 的描边 + 实底配色，
    /// 让它和同行的 Topic / 最低 Stars 等输入框观感一致。
    /// `textBackgroundColor` / `separatorColor` 是 AppKit 系统级动态色，
    /// 自动适配 dark / light 主题，无需各自再写两套颜色。
    private var fieldLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
            Text(displayText)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(date == nil ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down")
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }

    /// Popover 内容：`.graphical` 完整月历 + 底部「完成」按钮。
    ///
    /// **为什么用 `.fixedSize()` 而不是 `.frame(width:)`**：
    /// macOS 上 `.graphical` DatePicker 有固定的 intrinsic content size（约 220pt
    /// 宽，由 SwiftUI 内部按 7 列周历 + 年月切换条算出来），强行用更大宽度的
    /// frame 包它，月历不会被拉伸 —— 只会让自身居中、两侧出现明显空白
    /// （dong4j 2026-06-14 截图反馈）。改用 `.fixedSize()` 让外层 VStack 跟随
    /// 月历的 intrinsic size，popover 就紧贴内容收缩，视觉上零浪费。
    ///
    /// DatePicker 用 `Binding(get/set)` 把 `Date?` 拍平成 `Date` 给月历：
    /// - get：nil 时 fallback 到「今天」，让月历有个默认聚焦月份
    /// - set：用户任一点击都会立刻把 nil 升级为具体日期写回 `@Binding`
    ///   → 筛选状态即时同步，无需用户点「完成」才生效；「完成」纯粹是关闭
    ///   popover 的便捷出口
    private var calendarPopover: some View {
        VStack(spacing: 10) {
            DatePicker(
                "",
                selection: Binding(
                    get: { date ?? Date() },
                    set: { date = $0 }
                ),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()

            // 用 `.frame(maxWidth: .infinity, alignment: .trailing)` 让「完成」
            // 按钮始终贴右；不能用 HStack { Spacer(); Button } —— 后者会让 HStack
            // 占据父 VStack 全宽，与 .fixedSize() 行为冲突（VStack 取最大子宽时
            // 会陷入循环假设，月历再次被拉伸出空白）。
            Button("search.github.dateField.done") {
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .fixedSize()
    }

    private var displayText: String {
        guard let date else { return String.l10n("search.github.dateField.placeholder") }
        return Self.displayFormatter.string(from: date)
    }
}

// MARK: - History Chip

/// 单条历史记录的胶囊标签。
///
/// **视觉对齐 `UnifiedRepoRow.RepoCardInlineMetadataBadge`**：
/// 整个项目的 metadata pill（Stars / Forks / Language / sceneBadge）统一走
/// `Color.secondary.opacity(0.10)` 浅灰胶囊 + `.foregroundStyle(.secondary)`
/// 的克制风格；搜索历史 chip 也按这一套设计语言走，避免引入第二种 chip
/// 视觉规则。早期方案曾给每个 chip 用 `TagColorPalette` 调出彩色底，但视觉
/// 上跟 repo 卡片冲突，dong4j 直接 reject —— 改回单色灰底。
///
/// 交互要点：
/// - 点击 chip 主体 → 触发该关键词的搜索（整个胶囊都是命中区）
/// - hover 时右侧浮出 `x` 删除按钮（独立 hitbox，避免被父 Button 吞掉 click），
///   不 hover 时也预留出 14pt 空位避免 chip 宽度跳变
/// - hover 同时把胶囊底色从 0.10 加深到 0.18，提供"被聚焦"的反馈
private struct HistoryChip: View {
    let entry: SearchHistory
    let onUse: () -> Void
    let onRemove: () -> Void

    @State private var isHovered: Bool = false

    /// 2026-06-15:hover scale + 删除按钮入场动画在「关闭应用内动画」时跳过。
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    /// 显示 useCount 角标的最低门槛。`< 3` 视为"偶尔搜过"，无需占据视觉注意力。
    /// 这是 dong4j 拍板的阈值，需要调整时改这一个常量即可。
    private static let useCountBadgeMinimum = 3

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onUse) {
                HStack(spacing: 4) {
                    Text(entry.query)
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if entry.useCount >= Self.useCountBadgeMinimum {
                        // 用 verbatim: 显式跳过 SwiftUI 的 LocalizedStringKey 本地化查找
                        // —— "·\(Int)" 这种"单符号 + 单参数"组合曾在 i18n fallback 边界
                        // 上出现过显示异常；改 verbatim 直出原文最稳。
                        // 颜色 secondary 而非 tertiary：dong4j 实测 tertiary 在
                        // `Capsule.opacity(0.10)` 灰底 + light mode 下几乎不可见；
                        // 提升一档对比度，仍靠字号差（11 vs query 12）区分主次。
                        Text(verbatim: "·\(entry.useCount)")
                            .font(interfaceScale.font(.captionSmall, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(isHovered ? 0.18 : 0.10))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(chipTooltip)

            if isHovered {
                Button(action: onRemove) {
                    // xmark.circle.fill 用"危险红 + 半透明"传达 destructive 语义。
                    //
                    // 颜色选型：
                    // - `.red` 是 SwiftUI 动态色，会跟随 dark/light 主题调整明度
                    // - `.opacity(0.7)` 把饱和度压下来，避免在浅色 chip 上过分刺眼
                    // - 跟 contextMenu "删除这条历史" 的 `role: .destructive` 语义对齐
                    //
                    // 外裹 `Circle().fill(.controlBackgroundColor)` 实底圆背景：
                    // 让 xmark 即使盖在下方 ·N 末尾也能一眼识别为独立按钮，不跟文字融合。
                    // controlBackgroundColor 是系统级控件背景，自动适配深浅主题。
                    Image(systemName: "xmark.circle.fill")
                        .font(interfaceScale.font(.iconSmall))
                        .foregroundStyle(Color.red.opacity(0.7))
                        .background(
                            Circle()
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .padding(.trailing, 4)
                .help("search.history.removeOne.help")
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button("search.history.menu.useThis") { onUse() }
            Divider()
            Button("search.history.menu.removeOne", role: .destructive) { onRemove() }
        }
    }

    /// 系统 tooltip 内容：useCount > 1 时附带次数信息便于用户知道分数怎么来的。
    private var chipTooltip: String {
        guard entry.useCount > 1 else { return entry.query }
        return String(format: String.l10n("search.history.tooltip.useCountFormat"), entry.query, entry.useCount)
    }
}

// MARK: - FlowLayout

/// 搜索历史专用的自动换行布局。
///
/// 跟项目里 `RepoTagsSection` / `TagWallView` / `ActivityDetailView` 里同名的
/// private FlowLayout 行为一致；按"Surgical Changes"原则不做跨文件抽公共
/// 类型（private 不可跨文件共享）的范围外重构，单独再实现一份。
///
/// 如果后续需要把 4 处 FlowLayout 抽到 Shared 复用，记到技术债 D-? 再统一处理。
private struct SearchHistoryFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Remote Repo Detail

// 注：原 `private enum SearchDetailSemanticColor` 已抽到
// `Starcat/Shared/Components/DetailStats/StatSemanticColor.swift`(2026-06-29),
// 详情页 stat(Forks / Watchers)和 SearchCenter 共享同一份语义色。

/// 搜索详情卡底部操作 chip：图标 + 短标签 + capsule 底。
/// 主操作（Star / Ask AI / GitHub）走 `semanticColor` 着色底；折叠菜单等中性操作保持灰底。
private struct SearchDetailActionChip: View {
    let systemImage: String
    /// GitHub 这类品牌图标不属于 SF Symbols；仅在需要品牌图形时传 asset 名称。
    var assetImageName: String?
    /// 为 `nil` 时仅渲染图标（如 ··· 折叠菜单）。
    var titleKey: LocalizedStringKey?
    let helpKey: LocalizedStringKey
    /// 语义色；有值时图标 / 文字 / 底色同族着色。
    var semanticColor: StatSemanticColor? = nil
    var isWorking = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Button(action: action) {
            Group {
                if let titleKey {
                    HStack(spacing: 5) {
                        chipIcon
                        Text(titleKey)
                            .font(interfaceScale.font(.captionSmall, weight: .medium))
                            .lineLimit(1)
                    }
                } else {
                    chipIcon
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, titleKey == nil ? 8 : 10)
            .padding(.vertical, 5)
            .background(chipBackground, in: Capsule())
            .contentShape(Capsule())
        }
        .disabled(isWorking)
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(helpKey)
        .onHover { hovering in
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var chipIcon: some View {
        Group {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 11, height: 11)
            } else {
                if let assetImageName {
                    Image(assetImageName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: systemImage)
                        .font(interfaceScale.font(.captionSmall, weight: .semibold))
                }
            }
        }
    }

    private var foregroundColor: Color {
        if let semanticColor {
            return semanticColor.resolved(colorScheme: colorScheme)
        }
        return Color.secondary
    }

    private var chipBackground: Color {
        if let semanticColor {
            return semanticColor.background(colorScheme: colorScheme, hovered: isHovered)
        }
        return Color.secondary.opacity(isHovered ? 0.16 : 0.10)
    }
}

/// GitHub 搜索结果的会话级详情卡（SEARCH-RICH 2026-06-14 重构）。
///
/// 设计目标：在不打额外 GitHub API 调用、不入库的前提下，把搜索接口已经返回
/// 的字段尽量暴露出来，帮用户在 Star 之前完成「这个 repo 值不值得收藏」决策。
///
/// **不入库约束**：本视图仅消化 `RepositoryCandidate.remoteRepo`（搜索页 ephemeral
/// 转换得到，未进数据库）+ `remoteRepo.remoteExtras`（disabled / isTemplate /
/// score 三类瞬时态字段，旁挂在 candidate 上）。用户点击 Star 后才通过
/// `StarActionService` 走正式入库流程；本视图自身不写任何持久化层。
///
/// **匹配度可见性**：`score` 字段对 best-match 排序才有意义，其他排序模式
/// （stars / forks / updated）下 score 仍是 search 端点回传的同一个值，但语义
/// 与当前列表位置已脱钩 → 弹窗只在 `isCurrentSortBestMatch == true` 时显示。
///
/// **未填字段降级策略**：
/// - `remoteRepo == nil`：理论上 activate 函数已守卫，进入本视图前 remoteRepo 必非空；
///   若仍为 nil（防御性），整个 view 显示空态卡片避免崩溃
/// - description / topics / homepage / language 等 Optional 字段缺失时，对应行/区段
///   整体隐藏，不渲染"未知"占位（避免视觉噪音）
private struct SearchRemoteRepoDetailView: View {

    let candidate: RepositoryCandidate
    let isCurrentSortBestMatch: Bool
    let isStarred: Bool
    let onToggleStar: () async throws -> Bool
    let onOpenAI: () -> Void
    let onOpenInGitHub: () -> Void
    /// 复制仓库 HTML URL（走宿主回调，宿主可叠加 toast / 日志）。
    let onCopyURL: () -> Void
    let onToggleLibrary: () async -> Bool?
    let isLibraryWorking: Bool

    @Environment(\.dismiss) private var dismiss
    /// SEARCH-RICH 2026-06-14：Wiki 集成需要 `dependencies.wikiAPI`。
    /// `AppDependencies` 已在 `StarcatApp` 主 scene 注入 environment，sheet
    /// 默认继承 environment，所以这里直接 `@Environment` 拿到。
    @Environment(AppDependencies.self) private var dependencies

    /// 2026-06-16:跟随 LocaleStore 的 effective locale,用于 `RelativeDateTimeFormatter`
    /// 的 locale 注入(否则 formatter 默认走系统 locale,英文 App 仍会输出"3 小时前")。
    /// 父级 `.sheet { }` 闭包已挂 `appLocaleEnvironment()`,这里 `\.locale` 自动拿到正确值。
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    /// 搜索详情里的 CodeFlow sheet 也需要点击级 identity，避免 sheet-over-sheet
    /// 复用 presentation host 时沿用上一次 repo 的 `@State` ViewModel。
    private struct CodeFlowSheetItem: Identifiable {
        let id = UUID()
        let repo: Repo
    }

    /// 已确认 indexed 的外部 wiki 链接（DeepWiki / ZRead / CodeWiki）。
    /// `.task(id: candidate.identity)` 触发 fetch，未收录 / 失败时保持空数组
    /// → 整行隐藏（与 `RepoWikiMenu` 的"未收录不占 UI"语义一致）。
    @State private var wikiLinks: [WikiLink] = []
    /// 搜索详情不是本地 Repo 详情页，打开 sheet 时拿到的 `isStarred` 是一次性快照。
    /// Star/Unstar 成功后用本地覆盖值驱动按钮状态，避免用户需要关掉弹窗再打开才看到变化。
    @State private var starredOverride: Bool?
    /// 详情卡的 `starsCount` 同样来自搜索结果快照；Star/Unstar API 成功后本地 ±1，
    /// 让元数据行立刻反映「我刚贡献/撤销的那一颗星」，不必关卡重开或再打 GitHub。
    /// 下限钳到 0，避免 unstar 时出现负数（搜索快照本身可能已滞后于真实计数）。
    @State private var starsCountOverride: Int?
    /// Search Center 的候选卡同样是一次性快照；知识库状态写入成功后用本地覆盖值
    /// 驱动 ❤️ 空心/实心，避免必须关闭再打开详情卡才能看到变化。
    @State private var libraryOverride: Bool?
    /// 防止连续点击 Star chip 叠加两次 GitHub 写操作。
    @State private var isStarToggleInFlight = false

    /// 折叠菜单 popover 显隐。点 ··· 触发；菜单项点击后置 false 关闭。
    @State private var isOverflowPresented = false

    /// CodeFlow 子 sheet 用 Identifiable item 驱动，**不要**回退到
    /// `.sheet(isPresented: Bool)`。
    ///
    /// 历史坑（dong4j 2026-06-14 验收反馈，toolbar `ExternalLinksMenu` 同款问题）：
    /// `.sheet(isPresented:)` 在父视图频繁重建（toolbar trailing 闭包 / 搜索弹窗
    /// 内嵌 sheet）的场景下，sheet 关闭瞬间内部 state 与外部 Bool binding 的
    /// 更新存在 1 帧时序差，会让 sheet "关闭 → 闪现 → 再关闭"。改用
    /// `.sheet(item:)` 用 item 存在性驱动，关闭即 `item = nil`，更稳。
    /// 搜索弹窗本身已是 sheet，这里是 sheet over sheet (macOS 15+ 稳定），
    /// 嵌套层级更深时 item 模式的优势更明显。
    ///
    /// 触发流程仍保留"先关 popover → DispatchQueue.main.async 后再赋值 item"
    /// 的时序，避免 popover 与 sheet 同帧 presentation 竞争。
    @State private var codeFlowSheetItem: CodeFlowSheetItem?
    @State private var paywallContext: ProPaywallContext?

    /// 卡片宽度。480pt 足以容纳 owner / repo 双行 + 头像 + 顶栏徽章；再窄
    /// 顶栏会挤压 license / score 徽章；再宽就显得空旷不像「快速决策卡」。
    private static let cardWidth: CGFloat = 480

    /// 头像直径。与 `RepoMetadataHeaderView` 的 hero 头像保持一致视觉档次。
    private static let avatarSize: CGFloat = 44

    private var effectiveIsStarred: Bool {
        starredOverride ?? isStarred
    }

    /// stats 行星标数：优先用 Star/Unstar 成功后的本地覆盖值。
    private func effectiveStarsCount(for repo: Repo) -> Int {
        starsCountOverride ?? repo.starsCount
    }

    private var effectiveIsInLibrary: Bool {
        libraryOverride ?? candidate.card.isInLibrary
    }

    var body: some View {
        Group {
            if let repo = candidate.displayRepo {
                content(repo: repo)
            } else {
                emptyState
            }
        }
        .frame(width: Self.cardWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func content(repo: Repo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(repo: repo)
            if let description = repo.description, !description.isEmpty {
                // description 是用户内容，必须 verbatim。
                Text(verbatim: description)
                    .font(interfaceScale.font(.body))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("search.detail.empty.description")
                    .font(interfaceScale.font(.body))
                    .foregroundStyle(.secondary)
                    .italic()
            }

            if shouldShowStateBadgeRow(repo: repo) {
                stateBadgeRow(repo: repo)
            }

            statsRow(repo: repo)
            timestampRow(repo: repo)

            if !repo.topicsArray.isEmpty {
                topicsRow(topics: repo.topicsArray)
            }

            // Wiki 集成（SEARCH-RICH 2026-06-14）：未收录 / 失败时整行隐藏；
            // 与 topics 行同样位于"内容补充区",共享紧凑卡的"信号优先"原则。
            if !wikiLinks.isEmpty {
                wikiLinksRow(links: wikiLinks)
            }

            Divider()

            actionRow(repo: repo)
        }
        .padding(20)
        // `.task` 必须挂在 `content(repo:)` 内层 VStack 上(它永远存在,与 RepoWikiMenu
        // v1.2 修订里"EmptyView 不调度 task"是同款坑的反向避雷)。`id` 用 candidate
        // identity:repo 不变时 task 不重跑;切到下一个候选时(如果未来支持卡片间
        // 切换)task 会自动取消旧请求并对新 repo 重新发起,与 RepoWikiMenu 行为一致。
        .task(id: candidate.identity) {
            await loadWikiLinks(repo: repo)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("search.detail.empty.repoUnavailable")
                .font(interfaceScale.font(.bodyEmphasis))
                .foregroundStyle(.secondary)
            Button("search.detail.action.close") { dismiss() }
        }
        .padding(24)
    }

    // MARK: - Header

    @ViewBuilder
    private func header(repo: Repo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ownerAvatar(repo: repo)

            VStack(alignment: .leading, spacing: 2) {
                // owner / name 都是 GitHub 数据，必须 verbatim 防止 SwiftUI 误把
                // 它们当本地化 key（例如 owner 叫 "share" 之类的常见 key 会撞）。
                Text(verbatim: repo.owner)
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: repo.name)
                    .font(interfaceScale.font(.iconLarge, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isCurrentSortBestMatch, let score = candidate.remoteExtras.score {
                scoreBadge(score: score)
            }
            if let license = repo.license, !license.isEmpty {
                licenseBadge(license: license)
            }

            SheetCloseButton(
                action: { dismiss() },
                helpKey: "search.detail.action.close"
            )
        }
    }

    /// owner 头像。点击跳 owner 主页（与设计稿"点头像跳 owner"对齐）。
    /// 头像 URL 优先用 `repo.ownerAvatar`（mapper 已接通），缺失时用
    /// `https://github.com/{login}.png` 兜底（GitHub 官方提供的头像直链）。
    @ViewBuilder
    private func ownerAvatar(repo: Repo) -> some View {
        Button { openOwnerPage(login: repo.owner) } label: {
            avatarImage(repo: repo)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("search.detail.action.openOwner")
    }

    /// 头像视图。SEARCH-RICH 2026-06-14 修订（dong4j 反馈"每次打开都要重复
    /// 拉取吗"）:
    ///
    /// 老版用 SwiftUI 标准 `AsyncImage` —— 它**只走 URLSession.URLCache**(内存
    /// 4MB / 磁盘 20MB 的小池子,且每次 view 重建都会重新发 URLRequest,即便命中
    /// URLCache 也会 placeholder 闪一下);头像作为弹窗"重复打开同一 repo 也不
    /// 该再发请求"的高频静态资源,这套缓存太弱。
    ///
    /// 新版改用项目自有 `RemoteAvatar` 组件 —— 内部走 Kingfisher,带 100MB 内存
    /// + 1GB 磁盘 + TTL 1 周的双层缓存,弹窗反复打开同一 repo 命中内存 cache
    /// 直接同步出图,零网络。视觉规格(圆形 + 0.5px secondary opacity 0.18 描边)
    /// 与 sidebar / share-card / 详情页 hero 保持完全一致。
    ///
    /// owner 头像 URL 优先用 `repo.ownerAvatar`(mapper 已接通 GitHubRepoDTO 的
    /// `owner.avatar_url`),缺失时拼 GitHub 官方头像直链兜底(永远可拼出来)。
    @ViewBuilder
    private func avatarImage(repo: Repo) -> some View {
        let urlString: String = repo.ownerAvatar ?? "https://github.com/\(repo.owner).png"
        RemoteAvatar(urlString: urlString, size: Self.avatarSize)
    }

    private func scoreBadge(score: Double) -> some View {
        // 显示精度：保留两位小数足够区分 0.95 / 0.97 / 1.0；更高位无信息密度。
        let formatted = String(format: "%.2f", score)
        let label = String(format: String.l10n("search.detail.score.format"), formatted)
        return Label {
            Text(label)
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
                .monospacedDigit()
        } icon: {
            Image(systemName: "bolt.fill")
                .font(interfaceScale.font(.captionSmall, weight: .semibold))
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.12), in: Capsule())
        .help("search.detail.score.tooltip")
    }

    private func licenseBadge(license: String) -> some View {
        // license 是 GitHub 返回的 SPDX id 或 license name（例如 "MIT" / "Apache-2.0"），
        // 是数据，不是 UI 文案，必须 verbatim。
        Text(verbatim: license)
            .font(interfaceScale.font(.captionSmall, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.10), in: Capsule())
            .help("search.detail.license.tooltip")
    }

    // MARK: - State badges (archived / fork / template / disabled)

    /// 状态徽章行只在至少一条徽章命中时渲染（避免空行占空间）。
    private func shouldShowStateBadgeRow(repo: Repo) -> Bool {
        repo.isArchived
            || repo.isFork
            || candidate.remoteExtras.isTemplate == true
            || candidate.remoteExtras.disabled == true
    }

    private func stateBadgeRow(repo: Repo) -> some View {
        HStack(spacing: 6) {
            if repo.isArchived {
                stateBadge(textKey: "search.detail.badge.archived", color: .orange)
            }
            if repo.isFork {
                stateBadge(textKey: "search.detail.badge.fork", color: .gray)
            }
            if candidate.remoteExtras.isTemplate == true {
                stateBadge(textKey: "search.detail.badge.template", color: .purple)
            }
            if candidate.remoteExtras.disabled == true {
                stateBadge(textKey: "search.detail.badge.disabled", color: .red)
            }
            Spacer(minLength: 0)
        }
    }

    private func stateBadge(textKey: LocalizedStringKey, color: Color) -> some View {
        Text(textKey)
            .font(interfaceScale.font(.captionSmall, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .overlay {
                Capsule().strokeBorder(color.opacity(0.30), lineWidth: 0.5)
            }
    }

    // MARK: - Stats row

    private func statsRow(repo: Repo) -> some View {
        HStack(spacing: 14) {
            statItem(systemImage: "star", value: "\(effectiveStarsCount(for: repo))", iconColor: .star)
            statItem(systemImage: "tuningfork", value: "\(repo.forksCount)", iconColor: .fork)

            // open_issues_count 在 GitHub 设计里是 "issue + PR 合计"，tooltip 提示
            // 避免用户误读为只有 issues。值为 nil 时整个 stat 隐藏（不显示 "—"）。
            if let openIssues = repo.openIssuesCount {
                statItem(
                    systemImage: "exclamationmark.circle",
                    value: "\(openIssues)",
                    iconColor: .issues,
                    tooltipKey: "search.detail.stat.openIssues.tooltip"
                )
            }

            // default_branch 在大多数 repo 是 "main"；它的价值不在炫数据，而在
            // 让用户判断该 repo 还在用旧的 master 默认分支（往往代表久未维护）。
            if let branch = repo.defaultBranch, !branch.isEmpty {
                statItem(systemImage: "arrow.triangle.branch", value: branch, iconColor: .branch)
            }

            // language 也作为统计行的一员（沿用 UnifiedRepoRow / metadata pill 风格）；
            // 之所以放在 stats 行末尾而不是徽章区，是因为它在用户决策权重上属于
            // 「数据维度」而非「状态」。
            if let language = repo.language, !language.isEmpty {
                statItem(
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    value: language,
                    iconColor: .language
                )
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func statItem(
        systemImage: String,
        value: String,
        iconColor: StatSemanticColor,
        tooltipKey: LocalizedStringKey? = nil
    ) -> some View {
        let tint = iconColor.resolved(colorScheme: colorScheme)
        let item = Label {
            Text(verbatim: value)
                .font(interfaceScale.font(.caption, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .font(interfaceScale.font(.captionSmall, weight: .medium))
                .foregroundStyle(tint)
        }
        .labelStyle(.titleAndIcon)

        if let tooltipKey {
            item.help(tooltipKey)
        } else {
            item
        }
    }

    // MARK: - Timestamps

    /// 创建 / 推送 时间相对显示。两者都缺时整行隐藏。
    private func timestampRow(repo: Repo) -> some View {
        let createdRelative = relativeTime(iso8601: repo.createdAt)
        let pushedRelative = relativeTime(iso8601: repo.pushedAt)

        return HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)

            if let created = createdRelative {
                Text(String(format: String.l10n("search.detail.time.created.format"), created))
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }

            if createdRelative != nil && pushedRelative != nil {
                Text(verbatim: "·")
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }

            if let pushed = pushedRelative {
                Text(String(format: String.l10n("search.detail.time.updated.format"), pushed))
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .opacity(createdRelative == nil && pushedRelative == nil ? 0 : 1)
    }

    /// ISO8601 字符串 → 相对时间。
    /// - 用 `RelativeDateTimeFormatter` 跟随当前 `Locale`（en / zh-Hans 自动适配）
    /// - 解析失败返回 nil；调用方按 nil 整段隐藏，不渲染"unknown"占位
    ///
    /// **不能用 `ISO8601DateFormatter.shared`**：该共享实例的 `formatOptions`
    /// 含 `.withFractionalSeconds`，会**强制要求**字符串带毫秒（如
    /// `"2024-01-01T00:00:00.000Z"`）；但 GitHub `/search/repositories` 实际
    /// 返回 `"2024-01-01T00:00:00Z"`（不带毫秒）→ 解析全部返回 nil → 整行
    /// 透明隐藏（dong4j 2026-06-14 真机复现：弹窗看不到任何时间字段）。
    /// 复用 `RepoDetailViewData.parseISO8601` 的双 try 思路：先试带 fractional，
    /// 失败再试纯 internet date time。
    private func relativeTime(iso8601: String?) -> String? {
        guard let iso8601, !iso8601.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parsed: Date? = formatter.date(from: iso8601)
        if parsed == nil {
            formatter.formatOptions = [.withInternetDateTime]
            parsed = formatter.date(from: iso8601)
        }
        guard let date = parsed else { return nil }
        return RelativeTimeText.pastEvent(date, locale: locale, unitsStyle: .full)
    }

    // MARK: - Topics

    /// Topics chips。布局采用 `SearchHistoryFlowLayout`（同文件已定义的自动换行
    /// 布局），避免 topics 多时挤压固定宽度的卡片。
    ///
    /// 用 `Text(verbatim:)`：topic 是用户内容，绝不能被 SwiftUI 当成本地化 key
    /// 进 xcstrings 查找；前缀 `#` 也是装饰，与本地化无关。
    private func topicsRow(topics: [String]) -> some View {
        SearchHistoryFlowLayout(spacing: 6) {
            ForEach(topics.prefix(8), id: \.self) { topic in
                Text(verbatim: "#\(topic)")
                    .font(interfaceScale.font(.captionSmall, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Wiki 集成（SEARCH-RICH 2026-06-14）

    /// 行内 wiki chip 行。设计意图：用户在「快速决策要不要 Star 这个 repo」时
    /// 能一眼看到"还能在 DeepWiki / ZRead / CodeWiki 哪几家读到可读文档"，
    /// 比 ··· 折叠菜单的"藏起来"更适合搜索弹窗"信息密度卡"定位。
    ///
    /// 行布局：📖 图标 + "Wikis" 标签 + N 个 chip 按钮（每个对应一家收录站）。
    /// 调用方在外层 `if !wikiLinks.isEmpty` 守卫下渲染本行 → 全部未收录时整行
    /// 隐藏，零视觉负担（与详情页 `RepoWikiMenu` 的"未收录不占 UI"原则一致）。
    private func wikiLinksRow(links: [WikiLink]) -> some View {
        HStack(spacing: 8) {
            WikiEntryIcon(size: 11)
            Text("search.detail.wikis.label")
                .font(interfaceScale.font(.captionSmall, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(links) { link in
                wikiChip(link: link)
            }

            Spacer(minLength: 0)
        }
    }

    /// 单条 wiki chip。每家服务商用独立品牌色 capsule 底，与上方灰色 topic chip 区分。
    private func wikiChip(link: WikiLink) -> some View {
        let semantic = wikiSemanticColor(for: link.source)
        let tint = semantic.resolved(colorScheme: colorScheme)

        return Button {
            NSWorkspace.shared.open(link.url)
        } label: {
            HStack(spacing: 5) {
                wikiSourceIcon(source: link.source)
                Text(verbatim: link.title)
                    .font(interfaceScale.font(.captionSmall, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(semantic.background(colorScheme: colorScheme, hovered: false), in: Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text(verbatim: link.url.absoluteString))
    }

    private func wikiSemanticColor(for source: WikiSource) -> StatSemanticColor {
        switch source {
        case .deepWiki: return .wikiDeepWiki
        case .zread: return .wikiZread
        case .codeWiki: return .wikiCodeWiki
        case .unknown: return .wikiDeepWiki
        }
    }

    @ViewBuilder
    private func wikiSourceIcon(source: WikiSource) -> some View {
        if let name = source.assetName {
            Image(name)
                .resizable()
                .interpolation(.high)
                .frame(width: 10, height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: source.fallbackSFSymbol)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
    }

    /// 拉一次 wiki 状态。错误静默 —— wiki 是辅助信息，失败不应污染搜索弹窗
    /// 主流程；与 `RepoWikiMenu.loadLinks()` 的失败处理同款。
    private func loadWikiLinks(repo: Repo) async {
        wikiLinks = []
        do {
            let items = try await dependencies.wikiAPI.fetchStatus(
                owner: repo.owner,
                repo: repo.name
            )
            guard !Task.isCancelled else { return }
            wikiLinks = RepoWikiMenuState.make(items: items)
        } catch is CancellationError {
            // SwiftUI 切换 candidate 的正常取消（未来若支持卡片间切换时触发）
        } catch {
            AppLog.network.warning(
                "search-detail wiki: lookup failed for \(repo.fullName, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Action row

    /// 主操作行：Star / Ask AI / 在 GitHub 打开 + ··· 折叠菜单。
    /// `SearchDetailActionChip`：capsule 底 + 图标短标签，与同卡 topic/wiki chip 同族。
    private func actionRow(repo: Repo) -> some View {
        HStack(spacing: 8) {
            SearchDetailActionChip(
                systemImage: effectiveIsStarred ? "star.fill" : "star",
                titleKey: nil,
                helpKey: effectiveIsStarred ? "search.detail.action.unstar" : "search.detail.action.star",
                semanticColor: .actionStar,
                action: toggleStar
            )
            SearchDetailActionChip(
                systemImage: effectiveIsInLibrary ? "heart.fill" : "heart",
                titleKey: nil,
                helpKey: effectiveIsInLibrary ? "library.action.remove" : "library.action.add",
                semanticColor: .actionLibrary,
                isWorking: isLibraryWorking,
                action: toggleLibrary
            )
            SearchDetailActionChip(
                systemImage: "sparkles",
                titleKey: nil,
                helpKey: "search.detail.action.askAI",
                semanticColor: .actionAI,
                action: onOpenAI
            )
            SearchDetailActionChip(
                systemImage: "arrow.up.right.square",
                assetImageName: "github",
                titleKey: nil,
                helpKey: "search.detail.action.openOnGitHub",
                semanticColor: .actionGitHub,
                action: onOpenInGitHub
            )

            Spacer(minLength: 0)

            overflowMenu(repo: repo)
        }
    }

    private func toggleStar() {
        guard !isStarToggleInFlight else { return }
        isStarToggleInFlight = true
        Task { @MainActor in
            defer { isStarToggleInFlight = false }
            do {
                // API 成功才改 UI（与 StarStatChipButton「不做乐观 UI」一致）：
                // 先记下点击前状态，成功后再用 Bool 差驱动 starsCount ±1。
                let wasStarred = effectiveIsStarred
                let nowStarred = try await onToggleStar()
                starredOverride = nowStarred
                if wasStarred != nowStarred, let repo = candidate.displayRepo {
                    let base = starsCountOverride ?? repo.starsCount
                    starsCountOverride = max(0, base + (nowStarred ? 1 : -1))
                }
            } catch {
                AppLog.network.error("Search detail star toggle failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func toggleLibrary() {
        Task {
            if let next = await onToggleLibrary() {
                libraryOverride = next
            }
        }
    }

    /// 折叠菜单 popover。SEARCH-RICH 2026-06-14：从原生 Menu 升级为自绘 popover，
    /// 复用 toolbar `ExternalLinksPopover` 的视觉（CodeFlow 渐变卡片 + 行内菜单项）。
    ///
    /// 升级动机：
    /// - **CodeFlow 推广**：CodeFlow 是核心差异化能力，搜索弹窗用户在「探索是否
    ///   Star」阶段，立刻能可视化代码结构对决策非常有帮助；用渐变卡片视觉信号最强
    /// - **对齐详情页**：用户已经在 RepoListView 顶部 toolbar 见过同款卡片，搜索
    ///   弹窗保持一致避免认知割裂
    ///
    /// **CodeFlow 私有仓库策略**：搜索结果默认是公共 repo，但已 star 的私有 repo
    /// 也可能命中（用户搜自己的私有项目）→ `repo.isPrivate` 时整张卡片不渲染，与
    /// dong4j 选择的 `hidden` 模式一致（toolbar 是 `disabled`，二者权衡下搜索场景
    /// 走 hidden 更克制：列表里很少出现私有，没必要专门留个灰条提示）。
    ///
    /// **Sheet over sheet**：CodeFlow `CodeFlowPanel` 是 sheet，搜索弹窗本身也是
    /// sheet → 这里嵌套 sheet（macOS 15+ 稳定，`ShareCardSheet` 等已先例）。点击
    /// CodeFlow 时先翻 popover false → DispatchQueue.main.async 后才 isCodeFlow=true，
    /// 与 `FeaturedExternalLinksControl` 同款"避免双 presentation 同帧竞争"做法。
    @ViewBuilder
    private func overflowMenu(repo: Repo) -> some View {
        SearchDetailActionChip(
            systemImage: "ellipsis.circle",
            helpKey: "search.detail.action.more.tooltip",
            action: { isOverflowPresented.toggle() }
        )
        .popover(isPresented: $isOverflowPresented, arrowEdge: .top) {
            overflowPopoverContent(repo: repo)
                .appLocaleEnvironment()
        }
        .sheet(item: $paywallContext) { context in
            ProPaywallSheet.hosted(context: context, dependencies: dependencies)
        }
        .sheet(item: $codeFlowSheetItem) { item in
            CodeFlowPanel(repo: item.repo)
                .id(item.id)
                .appSheetRootEnvironment(dependencies)
        }
    }

    /// Popover 内容：复用 `CodeFlowFeaturedTile` + `ExternalLinkPopoverRow` 公共组件，
    /// 加上本地的 `SearchOverflowActionRow` 处理"剪贴板"这类非外链动作。
    ///
    /// 分组（用 Divider 隔开）：
    /// 1. CodeFlow 渐变卡（仅 `!repo.isPrivate` 渲染）
    /// 2. GitHub 子页面：Issues / Pull Requests / Releases
    /// 3. 用户主页 / Homepage（homepage 缺失时禁用项 disabled）
    /// 4. 本地操作：Copy URL / Copy Clone（不打开浏览器，仅写剪贴板）
    private func overflowPopoverContent(repo: Repo) -> some View {
        let homepageURL = RepoExternalLinks.homepage(raw: repo.homepage)

        return VStack(spacing: 7) {
            if !repo.isPrivate {
                CodeFlowFeaturedTile {
                    isOverflowPresented = false
                    // 关 popover 后下一帧再赋值 item 弹 sheet，避免 popover
                    // 与 sheet 同帧 presentation 竞争（参考
                    // FeaturedExternalLinksControl 同款时序）。
                    DispatchQueue.main.async { openCodeFlow(for: repo) }
                }

                Divider()
                    .padding(.horizontal, 4)
            }

            ExternalLinkPopoverRow(
                titleKey: "externalLinks.issues",
                systemImage: "exclamationmark.bubble",
                url: RepoExternalLinks.issues(owner: repo.owner, name: repo.name),
                onDismiss: { isOverflowPresented = false }
            )
            ExternalLinkPopoverRow(
                titleKey: "externalLinks.pullRequests",
                systemImage: "arrow.triangle.pull",
                url: RepoExternalLinks.pulls(owner: repo.owner, name: repo.name),
                onDismiss: { isOverflowPresented = false }
            )
            ExternalLinkPopoverRow(
                titleKey: "externalLinks.releases",
                systemImage: "tag.circle",
                url: RepoExternalLinks.releases(owner: repo.owner, name: repo.name),
                onDismiss: { isOverflowPresented = false }
            )

            Divider()
                .padding(.horizontal, 4)

            ExternalLinkPopoverRow(
                titleKey: "search.detail.action.openOwner",
                systemImage: "person.crop.circle",
                url: URL(string: "https://github.com/\(repo.owner)"),
                onDismiss: { isOverflowPresented = false }
            )

            // homepage 缺失时仍渲染但置灰：与 toolbar `ExternalLinksPopover` 的
            // "homepage 缺失整行隐藏"不同——搜索弹窗是"快速决策"场景,用户可能想
            // 知道"这 repo 有没有官网"; disabled 灰行能传递"作者没填"的信号,
            // 比直接消失信息更清晰(与原生 Menu 旧版本行为对齐)。
            SearchOverflowActionRow(
                titleKey: "search.detail.action.openHomepage",
                systemImage: "globe",
                isDisabled: homepageURL == nil
            ) {
                isOverflowPresented = false
                if let url = homepageURL { NSWorkspace.shared.open(url) }
            }

            Divider()
                .padding(.horizontal, 4)

            SearchOverflowActionRow(
                titleKey: "search.detail.action.copyURL",
                systemImage: "link"
            ) {
                isOverflowPresented = false
                onCopyURL()
            }

            SearchOverflowActionRow(
                titleKey: "search.detail.action.copyClone",
                systemImage: "terminal"
            ) {
                isOverflowPresented = false
                copyCloneURL(repo: repo)
            }
        }
        .padding(7)
        .frame(width: 238)
    }

    // MARK: - Local actions (no host callback needed)

    /// 复制 git clone URL。
    /// 优先用 `repo.cloneUrl`（HTTPS clone URL，GitHub 直接给）；缺失时退化到
    /// 「`https://github.com/{owner}/{name}.git` 拼凑」（永远可拼出来）。
    private func copyCloneURL(repo: Repo) {
        let value: String = repo.cloneUrl ?? "https://github.com/\(repo.owner)/\(repo.name).git"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// 在浏览器打开 owner 主页。被两处调用：① 顶栏头像点击；② 折叠菜单"打开
    /// Owner 主页"。不走宿主回调是因为这是纯外链，没有业务侧副作用（不像
    /// toggleStar 需要入库），与现有 reference candidate 直接 NSWorkspace 行为对齐。
    private func openOwnerPage(login: String) {
        guard let url = URL(string: "https://github.com/\(login)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openCodeFlow(for repo: Repo) {
        do {
            try dependencies.entitlementGate.requirePro(.codeFlow)
            AppLog.ui.info("Search CodeFlow sheet repo=\(repo.fullName, privacy: .public) id=\(repo.id, privacy: .public)")
            codeFlowSheetItem = CodeFlowSheetItem(repo: repo)
        } catch {
            paywallContext = ProPaywallContext(feature: .codeFlow, message: error.localizedDescription)
        }
    }
}

/// 搜索弹窗 popover 内的「本地操作」行（复制剪贴板、homepage 禁用态等）。
///
/// 视觉与 `ExternalLinkPopoverRow` 完全一致（同款 hover 反馈 / spacing / icon 宽度），
/// 区别在于：
/// - 不接 URL，接 `action: () -> Void` —— 让调用方决定具体行为（写剪贴板 / 打开
///   带空判断的 URL / 触发宿主回调），不强行把所有行为塞到"打开外链"这一套语义里
/// - 支持 `isDisabled`，用于 homepage 缺失时置灰但保留显示
struct SearchOverflowActionRow: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                Text(titleKey)
                Spacer()
            }
            .font(interfaceScale.font(.body))
            .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                (isHovering && !isDisabled) ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
    }
}
