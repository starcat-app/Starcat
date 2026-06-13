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
    let onToggleStar: (Repo) -> Void
    let isStarred: (Int64) -> Bool
    let isGitHubAuthenticated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @State private var remoteDetailRepo: Repo?
    /// 鼠标 hover 是浮层视图的瞬时状态，不写入 selectedIndex，避免鼠标经过后改变
    /// 用户的键盘导航位置。候选 ID 同时覆盖 GitHub repo 与 AnySearch reference。
    ///
    /// 注意：搜索结果出来时 selectedIndex 为 nil（"未选中任何一项"），此时
    /// 视图只剩 hover 一种高亮来源 —— 鼠标 hover 哪项哪项亮、移走全灭；只有
    /// 用户首次按 ↑/↓ 后 selectedIndex 才会被设为 0，开始走键盘选中逻辑。
    @State private var hoveredCandidateID: String?
    /// 清空全部历史的二次确认对话框可见性。
    /// 放在视图层是因为"是否要二次确认"是 UI 决策而非业务状态；ViewModel 的
    /// `clearHistory()` 仍保持单纯执行删除，不被弹窗逻辑污染。
    @State private var showingClearHistoryAlert = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { viewModel.dismiss() }

            VStack(spacing: 0) {
                searchHeader
                themedSeparator
                scopePicker
                if viewModel.scope == .all || viewModel.scope == .github {
                    githubFilterBar
                }
                themedSeparator
                resultContent
            }
            .frame(width: 760, height: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.35), radius: 32, y: 14)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.97).combined(with: .opacity))
        }
        .onAppear { isSearchFocused = true }
        .sheet(item: $remoteDetailRepo) { repo in
            SearchRemoteRepoDetailView(
                repo: repo,
                isStarred: isStarred(repo.id),
                onToggleStar: { onToggleStar(repo) },
                onOpenAI: { onOpenAI(repo) }
            )
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

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索本地 Stars、GitHub 与网页", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
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

    private var scopePicker: some View {
        HStack(spacing: 8) {
            ForEach(SearchScope.allCases) { scope in
                Button {
                    Task { await viewModel.changeScope(scope) }
                } label: {
                    Text(scopeTitle(scope))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(viewModel.scope == scope ? Color.accentColor.opacity(0.24) : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            Spacer()
            if viewModel.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private var githubFilterBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    viewModel.isGitHubFiltersExpanded.toggle()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text("GitHub 筛选")
                            .fontWeight(.semibold)
                        Image(systemName: viewModel.isGitHubFiltersExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                Spacer()
                Label(
                    isGitHubAuthenticated ? "已登录" : "匿名搜索",
                    systemImage: isGitHubAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let summary = viewModel.githubResultSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if viewModel.canLoadMoreGitHub {
                    Button("加载更多") { Task { await viewModel.loadMoreGitHub() } }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                }
            }

            if viewModel.isGitHubFiltersExpanded {
                VStack(spacing: 12) {
                    HStack(alignment: .bottom, spacing: 12) {
                        githubLanguagePicker
                        githubTextFilter(
                            title: "Topic",
                            placeholder: "例如 macOS",
                            text: optionalBinding(\.topic)
                        )
                        VStack(alignment: .leading, spacing: 5) {
                            filterFieldLabel("最低 Stars")
                            TextField("不限", value: $viewModel.githubFilters.minimumStars, format: .number)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(width: 112)
                        githubPicker(title: "排序方式", width: 130) {
                            Picker("排序方式", selection: $viewModel.githubFilters.sort) {
                                Text("最佳匹配").tag(GitHubSearchSort.bestMatch)
                                Text("Stars").tag(GitHubSearchSort.stars)
                                Text("Forks").tag(GitHubSearchSort.forks)
                                Text("最近更新").tag(GitHubSearchSort.updated)
                            }
                        }
                        githubPicker(title: "顺序", width: 90) {
                            Picker("顺序", selection: $viewModel.githubFilters.order) {
                                Text("降序").tag(SearchOrder.descending)
                                Text("升序").tag(SearchOrder.ascending)
                            }
                        }
                        Spacer(minLength: 0)

                        Button("应用筛选") {
                            Task { await viewModel.applyGitHubFilters() }
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    HStack(alignment: .bottom, spacing: 16) {
                        githubDateFilter(title: "创建时间晚于", keyPath: \.createdAfter)
                        githubDateFilter(title: "推送时间晚于", keyPath: \.pushedAfter)
                        Button("清除日期") {
                            viewModel.githubFilters.createdAfter = nil
                            viewModel.githubFilters.pushedAfter = nil
                        }
                        .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var resultContent: some View {
        if viewModel.lastSubmittedQuery.isEmpty {
            historyContent
        } else if viewModel.candidates.isEmpty, viewModel.isSearching {
            ProgressView("正在搜索…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.candidates.isEmpty {
            ContentUnavailableView(
                "没有找到结果",
                systemImage: "magnifyingglass",
                description: Text(viewModel.errorMessages.first ?? "尝试更换关键词或搜索范围")
            )
        } else {
            List(Array(viewModel.candidates.enumerated()), id: \.element.id) { index, candidate in
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
                    isSelected: index == viewModel.selectedIndex,
                    isHovered: hoveredCandidateID == candidate.id
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.14)) {
                        hoveredCandidateID = hovering ? candidate.id : nil
                    }
                }
                .onTapGesture {
                    activate(candidate)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { activate(candidate) }
                .contextMenu {
                    if case .repository(let repository) = candidate {
                        Button("在 GitHub 打开") { onOpenURL(repository) }
                        Button("复制 URL") { onCopyURL(repository) }
                        if let repo = repository.displayRepo {
                            Divider()
                            Button("Ask / AI 摘要") { onOpenAI(repo) }
                            Button(isStarred(repo.id) ? "取消 Star" : "Star") { onToggleStar(repo) }
                        }
                    } else if case .reference(let reference) = candidate {
                        Button("在浏览器打开") { NSWorkspace.shared.open(reference.originalURL) }
                        Button("复制 URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(reference.originalURL.absoluteString, forType: .string)
                        }
                    }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
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
                        .font(.caption)
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
                ContentUnavailableView(
                    "搜索 Starcat",
                    systemImage: "sparkle.magnifyingglass",
                    description: Text("输入关键词后按 Return")
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    historyHeader
                    ScrollView {
                        SearchHistoryFlowLayout(spacing: 8) {
                            ForEach(viewModel.history, id: \.self) { entry in
                                HistoryChip(
                                    entry: entry,
                                    onUse: { Task { await viewModel.useHistory(entry) } },
                                    onRemove: { viewModel.removeHistory(entry) }
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
        .confirmationDialog(
            "确定要清空全部搜索历史吗?",
            isPresented: $showingClearHistoryAlert,
            titleVisibility: .visible
        ) {
            Button("清空全部", role: .destructive) {
                viewModel.clearHistory()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可恢复。")
        }
    }

    /// "最近搜索" 标题 + 右侧 "清空全部" 触发按钮。
    /// 单独抽出来避免 ScrollView 把标题也卷进去；这样在历史项很多时标题保持悬停在顶部。
    private var historyHeader: some View {
        HStack {
            Text("最近搜索")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showingClearHistoryAlert = true
            } label: {
                Label("清空全部", systemImage: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("清空全部搜索历史")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func candidateRow(
        _ candidate: SearchCandidate,
        isSelected: Bool,
        isHovered: Bool
    ) -> some View {
        Group {
            switch candidate {
            case .repository(let repo):
                UnifiedRepoRow(
                    card: repo.card,
                    isSelected: isSelected,
                    showStarredCheckmark: true
                )
            case .reference(let reference):
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .frame(width: 34, height: 34)
                        .background(Color.blue.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(reference.title).font(.headline).lineLimit(1)
                        Text(reference.snippet ?? reference.originalURL.absoluteString)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(reference.domain).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(10)
                .background(isSelected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        // Search Center 在 UnifiedRepoRow 外再加一层统一 hover，确保 GitHub 与
        // AnySearch 都有同等清晰的指针反馈；选中态优先，不叠加 hover 色。
        .background(
            isHovered && !isSelected ? Color.accentColor.opacity(0.11) : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isHovered && !isSelected ? Color.accentColor.opacity(0.26) : .clear,
                    lineWidth: 1
                )
        }
        // hit-test 用 Rectangle 而不是 RoundedRectangle：圆角四个角会成为 onHover 死区,
        // 鼠标在角附近移入时无法触发 hover；改用矩形让整行的命中区域与可视区域一致。
        .contentShape(Rectangle())
    }

    /// 候选项的"激活"动作（点击 / 回车 / VoiceOver 主操作）。
    /// 远端仓库（仅 GitHub 搜出、未 star、未入本地库）走会话级详情 sheet；
    /// 其余（本地、reference、已 star）由宿主决定打开方式，统一走 onOpenCandidate。
    private func activate(_ candidate: SearchCandidate) {
        if case .repository(let repository) = candidate,
           repository.localRepo == nil,
           let remoteRepo = repository.remoteRepo {
            remoteDetailRepo = remoteRepo
        } else {
            onOpenCandidate(candidate)
        }
    }

    private func scopeTitle(_ scope: SearchScope) -> String {
        switch scope {
        case .all: return "全部"
        case .local: return "本地"
        case .github: return "GitHub"
        case .web: return "网页"
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

    private func githubTextFilter(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            filterFieldLabel(title)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity)
    }

    /// “全部语言”对应 nil，不生成 GitHub `language:` qualifier；其余选项直接来自
    /// Starcat 本地 Star 列表的 languageStats，与 Sidebar 的语言口径保持一致。
    private var githubLanguagePicker: some View {
        githubPicker(title: "语言", width: 128) {
            Picker("语言", selection: optionalLanguageBinding) {
                Text("全部语言").tag("")
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

    private func filterFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
    }

    /// Picker 的标题放到控件上方，避免 macOS 自动把 label 挤在选择框左侧，造成
    /// “排序 Best m…”这类横向截断。调用方仍传原生 Picker，交互行为不变。
    private func githubPicker<Content: View>(
        title: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            filterFieldLabel(title)
            content()
                .labelsHidden()
        }
        .frame(width: width, alignment: .leading)
    }

    /// 使用 macOS 原生紧凑 DatePicker。筛选值初始仍为 nil，只有用户实际修改
    /// DatePicker 后 binding setter 才写入日期；点击“清除日期”恢复 nil，不传 qualifier。
    private func githubDateFilter(
        title: String,
        keyPath: WritableKeyPath<GitHubSearchFilters, Date?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            filterFieldLabel(title)
            DatePicker(
                title,
                selection: optionalDateBinding(keyPath),
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
        }
        .frame(width: 150, alignment: .leading)
    }

    private func optionalDateBinding(_ keyPath: WritableKeyPath<GitHubSearchFilters, Date?>) -> Binding<Date> {
        Binding(
            get: { viewModel.githubFilters[keyPath: keyPath] ?? Date() },
            set: { viewModel.githubFilters[keyPath: keyPath] = $0 }
        )
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
    let entry: String
    let onUse: () -> Void
    let onRemove: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onUse) {
                HStack(spacing: 0) {
                    Text(entry)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // 始终预留删除按钮的位置（14pt 按钮 + 6pt 间距 ≈ 14pt 占位），
                    // 避免 hover 时 chip 宽度跳变带动后续 chip 重排。
                    Color.clear.frame(width: 14, height: 14)
                        .padding(.leading, 6)
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
            .help(entry)

            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .padding(.trailing, 6)
                .help("删除这条历史")
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .contextMenu {
            Button("使用此关键词") { onUse() }
            Divider()
            Button("删除这条历史", role: .destructive) { onRemove() }
        }
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

/// GitHub 搜索结果的会话级详情，不写数据库；只有用户执行 Star 后才通过
/// StarActionService 进入本地事实源。
private struct SearchRemoteRepoDetailView: View {
    let repo: Repo
    let isStarred: Bool
    let onToggleStar: () -> Void
    let onOpenAI: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(repo.fullName).font(.title2.bold())
                    Text(repo.description ?? "暂无描述").foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
            }
            HStack(spacing: 18) {
                Label(repo.language ?? "Unknown", systemImage: "chevron.left.forwardslash.chevron.right")
                Label("\(repo.starsCount)", systemImage: "star")
                Label("\(repo.forksCount)", systemImage: "tuningfork")
                if let license = repo.license { Label(license, systemImage: "doc.text") }
            }
            .foregroundStyle(.secondary)
            HStack {
                Button(isStarred ? "取消 Star" : "Star") { onToggleStar() }
                    .buttonStyle(.borderedProminent)
                Button("Ask / AI 摘要") { onOpenAI() }
                Button("在 GitHub 打开") {
                    if let url = URL(string: repo.htmlUrl) { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(24)
        .frame(width: 620, height: 260)
    }
}
