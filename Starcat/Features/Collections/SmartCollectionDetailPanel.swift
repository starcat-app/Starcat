//
//  SmartCollectionDetailPanel.swift
//  Starcat
//
//  Smart Collections 右栏浏览面板。
//
//  设计约束：
//  - 中栏保持 Smart Collections 卡片总览；右栏承载具体集合的浏览视图。
//  - 卡片容器复用 `RepoRowSurface`，保证背景 / hover / selected 视觉与中栏 repo row 同源。
//  - 右栏自己分页增量渲染，避免大集合一次性创建大量卡片造成明显卡顿。
//  - 仓库卡片用 Masonry 瀑布流（`SmartCollectionMasonryLayout`），高度随内容伸缩。
//
//  - 右栏顶区与 Manage `manageFilterBar` 同构：`.navigationTitle` / `.navigationSubtitle` +
//    规则行 + Divider + ScrollView（卡片区），不靠黑色 safeArea 遮挡。
//  - Footer / 头图健康徽章：卡片 `onAppear` 才批量查 GRDB，避免首屏 16 条全量 health 查询。
//

import SwiftUI
import AppKit

/// 右栏卡片渲染快照：在 panel 层一次性组装，供 Equatable 卡片做 diff。
private struct SmartCollectionCardItem: Identifiable, Equatable {
    var id: Int64 { repo.id }
    let repo: Repo
    let status: RepoStatus
    let userTags: [Tag]
    let health: RepoHealthSnapshot?
    let isSelected: Bool
    /// 当前浏览的系统集合；用于「维护停滞」等集合专属的 stats 行标识。
    let collectionKind: SmartCollectionKind?
}

struct SmartCollectionDetailPanel: View {
    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppDependencies.self) private var dependencies

    @State private var healthSnapshots: [Int64: RepoHealthSnapshot] = [:]
    /// 已尝试过加载（含 DB 无记录），防止滚动反复 onAppear 打 GRDB。
    @State private var healthResolvedRepoIDs: Set<Int64> = []
    @State private var pendingHealthRepoIDs: Set<Int64> = []
    @State private var healthLoadInFlightIDs: Set<Int64> = []
    @State private var isLoadingHealth = false
    @State private var visibleCount = pageSize
    @State private var isRuleExpanded = false
    /// ScrollView 可用宽度；用 background GeometryReader 读取，避免外层 GeometryReader 包裹整棵 scroll 树。
    @State private var contentWidth: CGFloat = 720
    @State private var masonryColumns: [[SmartCollectionCardItem]] = []
    @State private var loadNextPageTask: Task<Void, Never>?
    @State private var loadHealthTask: Task<Void, Never>?

    private static let pageSize = 16
    private static let pageLoadDebounceNs: UInt64 = 300_000_000
    private static let healthLoadDebounceNs: UInt64 = 80_000_000
    private static let cardSpacing: CGFloat = 12
    private static let minCardWidth: CGFloat = 280
    private static let masonryOuterPadding: CGFloat = 16
    /// 对应 `RepoRowSurface` 的左右 10pt content padding；选中态还会额外增加 5pt leading。
    private static let cardContentHorizontalPadding: CGFloat = 20
    private static let selectedCardLeadingPadding: CGFloat = 5

    private var repos: [Repo] {
        viewModel.filteredSorted
    }

    private var visibleRepos: [Repo] {
        Array(repos.prefix(visibleCount))
    }

    private var lastVisibleRepoID: Int64? {
        visibleRepos.last?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            collectionFilterBar

            if isRuleExpanded {
                expandedRulesSection
            }

            Divider()

            ScrollView {
                collectionScrollContent
                    .padding(.horizontal, Self.masonryOuterPadding)
                    .padding(.top, 12)
                    .padding(.bottom, Self.masonryOuterPadding)
            }
            .detailScrollViewStyle()
        }
        // 与 Manage `RepoDetailScaffold` 同构：标题进 navigation chrome，避免 ScrollView 顶穿透明 toolbar。
        .navigationTitle(title)
        .navigationSubtitle(navigationSubtitleText)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { contentWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in
                        contentWidth = width
                    }
            }
        }
        .task(id: viewModel.itemsRevision) {
            visibleCount = Self.pageSize
            resetHealthCache()
            refreshMasonryLayout()
        }
        .onChange(of: contentWidth) { _, _ in
            refreshMasonryLayout()
        }
        .onChange(of: visibleCount) { _, _ in
            refreshMasonryLayout()
        }
        .onChange(of: viewModel.selectedRepoID) { _, _ in
            refreshMasonryLayout()
        }
        .onChange(of: viewModel.selection) { _, _ in
            isRuleExpanded = false
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Masonry 卡片区（仅在 ScrollView 内滚动；顶栏规则行固定于 ScrollView 外）。
    @ViewBuilder
    private var collectionScrollContent: some View {
        if viewModel.isLoading && repos.isEmpty {
            SmartCollectionCardSkeletonMasonry(
                columnCount: columnCount(for: contentWidth),
                spacing: Self.cardSpacing
            )
        } else if repos.isEmpty {
            EmptyStateView(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "smartCollections.empty.collection",
                subtitle: "smartCollections.empty.collectionSubtitle",
                spacing: 12
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            SmartCollectionMasonryStack(
                columns: masonryColumns,
                spacing: Self.cardSpacing
            ) { item in
                SmartCollectionRepoCard(
                    item: item,
                    chipAvailableWidth: chipAvailableWidth(isSelected: item.isSelected)
                )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.selectedRepoID = item.id
                    }
                    .onAppear {
                        requestHealthLoad(for: item.id)
                        if item.id == lastVisibleRepoID {
                            scheduleLoadNextPage()
                        }
                    }
            }

            if visibleCount < repos.count {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                        .onAppear(perform: scheduleLoadNextPage)
                    Spacer()
                }
                .padding(.vertical, 10)
            }
        }
    }

    /// 与中栏 `manageFilterBar` 同高的规则行；标题 / 数量走 `.navigationTitle` / `.navigationSubtitle`。
    private var collectionFilterBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    isRuleExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("smartCollections.panel.rules")
                        .font(.subheadline)
                    Image(systemName: isRuleExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()

            Spacer()

            if isLoadingHealth {
                ProgressView()
                    .controlSize(.mini)
            }

            if activeSystemCollectionKind == .library {
                Button {
                    KnowledgeRAGWorkspaceWindowController.show(
                        dependencies: dependencies,
                        homeViewModel: viewModel
                    )
                } label: {
                    Label("smartCollections.library.openRAG", systemImage: "text.book.closed")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.top, ManageListFilterBarMetrics.topPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
    }

    private var expandedRulesSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(ruleLines, id: \.self) { line in
                Text(verbatim: line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, ManageListFilterBarMetrics.horizontalPadding)
        .padding(.bottom, ManageListFilterBarMetrics.bottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var navigationSubtitleText: String {
        String(format: String.l10n("list.repoCountFormat"), repos.count)
    }

    private var title: String {
        switch viewModel.selection {
        case .smartCollection(let kind):
            return SmartCollectionRule.defaultName(for: kind)
        case .userSmartCollection(let id):
            return viewModel.userSmartCollection(id: id)?.name ?? String.l10n("smartCollections.mine.fallback")
        default:
            return String.l10n("smartCollections.title")
        }
    }

    /// 用户自定义集合返回 nil；仅系统 Smart Collection 右栏卡片需要集合专属 UI。
    private var activeSystemCollectionKind: SmartCollectionKind? {
        if case .smartCollection(let kind) = viewModel.selection {
            return kind
        }
        return nil
    }

    private var ruleLines: [String] {
        switch viewModel.selection {
        case .smartCollection(let kind):
            var lines = [String.l10n("smartCollections.\(kind.rawValue).subtitle")]
            lines.append(contentsOf: SmartCollectionSystemRuleSummary.lines(for: kind))
            return lines
        case .userSmartCollection(let id):
            let context = viewModel.smartCollectionSummaryContext()
            guard let rule = viewModel.userSmartCollection(id: id)?.rule else {
                return [String.l10n("smartCollections.panel.rulesUnavailable")]
            }
            return SmartCollectionRuleSummary.lines(rule: rule, context: context)
        default:
            return [String.l10n("smartCollections.panel.rulesUnavailable")]
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        let available = max(width - Self.masonryOuterPadding * 2, Self.minCardWidth)
        return max(1, Int((available + Self.cardSpacing) / (Self.minCardWidth + Self.cardSpacing)))
    }

    /// 从 panel 的稳定宽度单向推导卡片内容宽度，避免 lazy cell 再用 GeometryReader 反向测量。
    private func chipAvailableWidth(isSelected: Bool) -> CGFloat {
        let count = columnCount(for: contentWidth)
        let availableWidth = max(0, contentWidth - Self.masonryOuterPadding * 2)
        let totalSpacing = Self.cardSpacing * CGFloat(max(0, count - 1))
        let columnWidth = (availableWidth - totalSpacing) / CGFloat(count)
        let selectedInset = isSelected ? Self.selectedCardLeadingPadding : 0
        return max(
            0,
            columnWidth - Self.cardContentHorizontalPadding - selectedInset
        )
    }

    /// 一次性组装卡片快照 + 分列 bucket；仅在 width / 可见集 / 选中 / health 变化时调用。
    private func refreshMasonryLayout() {
        let visible = visibleRepos
        guard !visible.isEmpty else {
            masonryColumns = []
            return
        }

        let tagsByRepoID = Self.tagsByRepoID(for: visible, viewModel: viewModel)
        let selectedID = viewModel.selectedRepoID
        let collectionKind = activeSystemCollectionKind
        let items = visible.map { repo in
            SmartCollectionCardItem(
                repo: repo,
                status: viewModel.readStatus(for: repo.id),
                userTags: tagsByRepoID[repo.id] ?? [],
                health: healthSnapshots[repo.id],
                isSelected: selectedID == repo.id,
                collectionKind: collectionKind
            )
        }
        masonryColumns = SmartCollectionMasonryDistribution.distribute(
            items,
            columnCount: columnCount(for: contentWidth)
        )
    }

    /// 批量预取 tags，避免在 SwiftUI body 里对每张卡重复 filter 全量 tags 数组。
    private static func tagsByRepoID(for repos: [Repo], viewModel: HomeViewModel) -> [Int64: [Tag]] {
        Dictionary(uniqueKeysWithValues: repos.map { ($0.id, viewModel.tags(for: $0.id)) })
    }

    private func scheduleLoadNextPage() {
        guard visibleCount < repos.count else { return }
        loadNextPageTask?.cancel()
        loadNextPageTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.pageLoadDebounceNs)
            guard !Task.isCancelled else { return }
            loadNextPage()
        }
    }

    private func loadNextPage() {
        guard visibleCount < repos.count else { return }
        visibleCount = min(visibleCount + Self.pageSize, repos.count)
    }

    private func resetHealthCache() {
        healthSnapshots = [:]
        healthResolvedRepoIDs = []
        pendingHealthRepoIDs = []
        healthLoadInFlightIDs = []
        loadHealthTask?.cancel()
        loadHealthTask = nil
    }

    /// 卡片进入 LazyVStack 视口时登记 health 需求；短 debounce 合并同帧多条 onAppear。
    private func requestHealthLoad(for repoID: Int64) {
        guard healthSnapshots[repoID] == nil,
              !healthResolvedRepoIDs.contains(repoID),
              !healthLoadInFlightIDs.contains(repoID) else { return }
        pendingHealthRepoIDs.insert(repoID)
        scheduleHealthLoad()
    }

    private func scheduleHealthLoad() {
        loadHealthTask?.cancel()
        loadHealthTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.healthLoadDebounceNs)
            guard !Task.isCancelled else { return }
            await flushPendingHealthLoads()
        }
    }

    private func flushPendingHealthLoads() async {
        let ids = Array(pendingHealthRepoIDs)
        pendingHealthRepoIDs.removeAll()
        await loadHealthSnapshots(for: ids)
    }

    /// 只查询缓存中缺失且尚未尝试过的 repo id；滚动 onAppear 驱动，不随分页预取。
    private func loadHealthSnapshots(for ids: [Int64]) async {
        let missing = ids.filter {
            healthSnapshots[$0] == nil
                && !healthResolvedRepoIDs.contains($0)
                && !healthLoadInFlightIDs.contains($0)
        }
        guard !missing.isEmpty else { return }

        healthLoadInFlightIDs.formUnion(missing)
        isLoadingHealth = true
        defer {
            healthLoadInFlightIDs.subtract(missing)
            isLoadingHealth = !healthLoadInFlightIDs.isEmpty
        }

        do {
            let loaded = try await dependencies.repoHealthRepository.snapshots(for: missing)
            healthSnapshots.merge(loaded) { _, new in new }
            healthResolvedRepoIDs.formUnion(missing)
            refreshMasonryLayout()
        } catch {
            AppLog.database.warning("Smart Collection detail health load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

}

private struct SmartCollectionRepoCard: View {
    private static let sectionSpacing: CGFloat = 6
    private static let chipRowSpacing: CGFloat = 4

    let item: SmartCollectionCardItem
    /// 由 panel 按列宽一次算出；卡片不得再用 GeometryReader 反向读取自身宽度。
    let chipAvailableWidth: CGFloat

    @Environment(AppDependencies.self) private var dependencies
    @Environment(HomeViewModel.self) private var viewModel
    @Environment(\.locale) private var locale
    @State private var isAddingToLibrary = false

    private var repo: Repo { item.repo }
    private var status: RepoStatus { item.status }
    private var userTags: [Tag] { item.userTags }
    private var health: RepoHealthSnapshot? { item.health }
    private var isSelected: Bool { item.isSelected }
    private var collectionKind: SmartCollectionKind? { item.collectionKind }

    private var accentColor: Color {
        if let language = repo.language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        return .accentColor
    }

    var body: some View {
        RepoRowSurface(isSelected: isSelected, accentColor: accentColor) {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                header
                description
                topicAndTagArea
                statsRow
                footer
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            // 头像单独做 GitHub 跳转，避免与卡片选中手势嵌套 Button。
            Button {
                if let url = RepoExternalLinks.repo(repo) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                RemoteAvatar(
                    urlString: repo.ownerAvatar ?? RepoAvatarURL.from(owner: repo.owner),
                    size: 32,
                    fallbackSymbol: "shippingbox.circle.fill"
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .pressableHover()
            .help("repo.openOnGithub")

            VStack(alignment: .leading, spacing: 3) {
                Text(repo.fullName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if let language = repo.language, !language.isEmpty {
                        LanguageBadge(language: language, style: .compact)
                    }
                    stateBadge
                }
            }

            Spacer(minLength: 6)

            if let healthBadge = health?.badgeData {
                RepoHealthBadge(data: healthBadge)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(height: 36, alignment: .top)
        .clipped()
    }

    @ViewBuilder
    private var description: some View {
        if let description = repo.description, !description.isEmpty {
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("smartCollections.panel.noDescription")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var topicAndTagArea: some View {
        let tagChips = userTags.prefix(3).map { tag in
            SmartCollectionInfoChip(
                text: tag.name,
                helpText: tag.name,
                systemImage: tag.icon ?? "tag",
                tint: Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor
            )
        }

        if !repo.topicsArray.isEmpty || !tagChips.isEmpty {
            VStack(alignment: .leading, spacing: Self.chipRowSpacing) {
                if !repo.topicsArray.isEmpty {
                    SmartCollectionMeasuredChipRow(
                        chips: repo.topicsArray.map { topic in
                            SmartCollectionInfoChip(
                                text: topic,
                                helpText: topic,
                                systemImage: "number",
                                tint: .secondary
                            )
                        },
                        availableWidth: chipAvailableWidth
                    )
                }
                if !tagChips.isEmpty {
                    SmartCollectionMeasuredChipRow(
                        chips: tagChips,
                        availableWidth: chipAvailableWidth
                    )
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// 与 Manage `UnifiedRepoRow` chip 行对齐：Stars / Forks / Watchers / Issues 单行横排。
    private var statsRow: some View {
        HStack(spacing: 8) {
            StarsBadge(
                count: dependencies.starredRegistry.displayedStarsCount(
                    base: repo.starsCount,
                    ghRepoId: repo.id
                ),
                style: .full
            )
            MetaBadge(systemImage: "tuningfork", text: repo.forksCount.formattedShort, tint: .secondary)
            MetaBadge(systemImage: "eye", text: repo.watchersCount.formattedShort, tint: .secondary)
            MetaBadge(
                systemImage: "exclamationmark.circle",
                text: (repo.openIssuesCount ?? 0).formattedShort,
                tint: .secondary
            )
            if let accessIndicator {
                MetaBadge(
                    systemImage: accessIndicator.systemImage,
                    text: accessIndicator.text,
                    tint: .red
                )
            }
            if let unmaintainedIndicator {
                MetaBadge(
                    systemImage: unmaintainedIndicator.systemImage,
                    text: unmaintainedIndicator.text,
                    tint: .red
                )
            }
            Spacer(minLength: 0)
            if collectionKind == .outsideLibraryStars {
                addToLibraryButton
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var accessIndicator: (systemImage: String, text: String)? {
        guard repo.accessState == .unavailable else { return nil }
        return ("exclamationmark.octagon", String.l10n("repo.access.unavailable"))
    }

    /// 未入库 Stars 专属操作：复用详情页 ❤️ 视觉；成功写入后刷新当前集合，让卡片从列表消失。
    private var addToLibraryButton: some View {
        LibraryToggleButton(isSaved: false, isWorking: isAddingToLibrary) {
            Task { await addToLibrary() }
        }
    }

    private func addToLibrary() async {
        guard !isAddingToLibrary else { return }
        guard dependencies.authSession.state.isAuthenticated else {
            dependencies.authSession.requestLoginSheet()
            return
        }
        guard repo.id > 0 else { return }

        isAddingToLibrary = true
        defer { isAddingToLibrary = false }

        do {
            _ = try await dependencies.repoRepository.upsertRepoMetadataForLibrary(repo: repo, syncedAt: Date())
            try await dependencies.repoNoteRepository.updateLibraryState(repoId: repo.id, state: .inLibrary)
            viewModel.applyLibraryStateChange(repoId: repo.id, state: .inLibrary)
            await viewModel.refreshSidebar()
            await viewModel.reloadItems(forceRefresh: true)
        } catch {
            AppLog.database.error("Smart Collection add to library failed repo=\(repo.fullName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 「维护停滞」集合命中原因：归档走 archivebox + 已归档文案，久未更新走 clock + 集合标题。
    private var unmaintainedIndicator: (systemImage: String, text: String)? {
        guard collectionKind == .unmaintained else { return nil }
        if repo.isArchived {
            return ("archivebox", String.l10n("repo.archived"))
        }
        return ("clock.badge.exclamationmark", String.l10n("smartCollections.unmaintained.title"))
    }

    @ViewBuilder
    private var footer: some View {
        if showsFooter {
            HStack(alignment: .center, spacing: 8) {
                if let health, health.fetchStatus != .failed {
                    healthDimensionStrip(health)
                } else if repo.isArchived, collectionKind != .unmaintained {
                    // 维护停滞：归档标识已上移到 stats 行红色徽章，footer 不再重复。
                    ArchivedBadge(iconOnly: true)
                } else if repo.isFork {
                    MetaBadge(systemImage: "tuningfork", text: "Fork", tint: .secondary)
                }

                Spacer(minLength: 8)

                if let pushedAt = relativeDate(repo.pushedAt) {
                    Label(pushedAt, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var showsFooter: Bool {
        (health.map { $0.fetchStatus != .failed } == true)
            || (repo.isArchived && collectionKind != .unmaintained)
            || repo.isFork
            || relativeDate(repo.pushedAt) != nil
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch status {
        case .unread:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(Text("repo.status.unread"))
        case .using:
            // 与详情页 RepoNotesSection / 主窗口 RepoStatusChip 同源：checkmark.seal.fill
            MetaBadge(systemImage: "checkmark.seal.fill", text: String.l10n("repo.status.using"), tint: .accentColor)
        case .read:
            EmptyView()
        }
    }

    private func healthDimensionStrip(_ snapshot: RepoHealthSnapshot) -> some View {
        HStack(spacing: 4) {
            healthDot(snapshot.maintenanceScore, color: .blue)
            healthDot(snapshot.popularityScore, color: .green)
            healthDot(snapshot.qualityScore, color: .purple)
            healthDot(snapshot.securityScore, color: .orange)
        }
        .help("repoHealth.score.overall")
    }

    private func healthDot(_ score: Double, color: Color) -> some View {
        Capsule()
            .fill(color.opacity(max(0.22, min(score / 100, 1))))
            .frame(width: 18, height: 5)
    }

    private func relativeDate(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601DateFormatter.shared.date(from: iso) else { return nil }
        return RelativeTimeText.pastEvent(date, locale: locale)
    }
}

private struct SmartCollectionInfoChip: Identifiable {
    var id: String { "\(systemImage)|\(text)" }
    let text: String
    let helpText: String
    let systemImage: String
    let tint: Color
}

/// chip 行需要按真实像素宽度裁剪：字符数不能代表 chip 宽度，必须把字体、图标和 padding 一起算进去。
private struct SmartCollectionMeasuredChipRow: View {
    private static let rowHeight: CGFloat = 18
    private static let chipSpacing: CGFloat = 6
    private static let chipIconWidth: CGFloat = 8
    private static let chipTextSpacing: CGFloat = 3
    private static let chipHorizontalPadding: CGFloat = 14
    private static let overflowText = "..."

    let chips: [SmartCollectionInfoChip]
    /// 由外层 panel 单向传入，避免每个 lazy cell 都参与宽度测量并形成布局反馈环。
    let availableWidth: CGFloat

    var body: some View {
        HStack(spacing: Self.chipSpacing) {
            ForEach(visibleChips) { chip in
                SmartCollectionCompactInfoChip(
                    systemImage: chip.systemImage,
                    text: chip.text,
                    helpText: chip.helpText,
                    tint: chip.tint
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.rowHeight)
        .clipped()
    }

    /// 从左到右贪心填充 chip，并为未展示的剩余 chip 预留一个 `...` chip。
    private var visibleChips: [SmartCollectionInfoChip] {
        let decision = SmartCollectionChipLayoutPolicy.resolve(
            chipWidths: chips.map { Self.chipWidth(text: $0.text) },
            availableWidth: availableWidth,
            spacing: Self.chipSpacing,
            overflowWidth: Self.chipWidth(text: Self.overflowText)
        )
        var visible = Array(chips.prefix(decision.visibleChipCount))
        guard decision.showsOverflow else { return visible }

        let omittedText = chips
            .dropFirst(decision.visibleChipCount)
            .map(\.helpText)
            .joined(separator: ", ")
        visible.append(Self.overflowChip(helpText: omittedText))
        return visible
    }

    private static func overflowChip(helpText: String) -> SmartCollectionInfoChip {
        SmartCollectionInfoChip(text: overflowText, helpText: helpText, systemImage: "ellipsis", tint: .secondary)
    }

    private static func chipWidth(text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return chipIconWidth + chipTextSpacing + textWidth + chipHorizontalPadding
    }
}

/// 右栏集合卡片专用 chip。列宽由 Masonry 约束，过长文案在胶囊内截断，行容器 `.clipped()` 防溢出。
private struct SmartCollectionCompactInfoChip: View {
    let systemImage: String
    let text: String
    let helpText: String
    let tint: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .medium))
                .frame(width: 8)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .clipped()
        .help(helpText)
    }
}

private struct SmartCollectionCardSkeletonMasonry: View {
    let columnCount: Int
    let spacing: CGFloat

    private struct SkeletonItem: Identifiable {
        let id: Int
        let variant: Int
    }

    var body: some View {
        SkeletonAnimatedPhase { phase in
            SmartCollectionMasonryStack(
                items: (0..<8).map { SkeletonItem(id: $0, variant: $0 % 3) },
                columnCount: columnCount,
                spacing: spacing
            ) { item in
                SmartCollectionCardSkeleton(
                    phase: phase,
                    phaseOffset: Double(item.id) * 0.08,
                    variant: item.variant
                )
            }
        }
    }
}

private struct SmartCollectionCardSkeleton: View {
    let phase: Double
    let phaseOffset: Double
    /// 0/1/2 三种骨架高度，瀑布流加载时视觉更接近真实参差卡片。
    let variant: Int

    @Environment(\.colorScheme) private var colorScheme

    private var palette: SkeletonPalette {
        SkeletonPalette.forColorScheme(colorScheme)
    }

    var body: some View {
        RepoRowSurface(isSelected: false, accentColor: .accentColor) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    SkeletonBlock(width: 32, height: 32, cornerRadius: 16, phase: phase, phaseOffset: phaseOffset, palette: palette)
                    VStack(alignment: .leading, spacing: 5) {
                        SkeletonBlock(width: 150, height: 13, phase: phase, phaseOffset: phaseOffset, palette: palette)
                        SkeletonBlock(width: 92, height: 10, phase: phase, phaseOffset: phaseOffset + 0.05, palette: palette)
                    }
                    Spacer()
                    SkeletonBlock(width: 54, height: 18, cornerRadius: 9, phase: phase, phaseOffset: phaseOffset + 0.1, palette: palette)
                }

                SkeletonBlock(maxWidth: .infinity, height: 11, phase: phase, phaseOffset: phaseOffset + 0.1, palette: palette)
                if variant >= 1 {
                    SkeletonBlock(maxWidth: .infinity, height: 11, phase: phase, phaseOffset: phaseOffset + 0.14, palette: palette)
                }
                if variant >= 2 {
                    SkeletonBlock(maxWidth: .infinity, height: 11, phase: phase, phaseOffset: phaseOffset + 0.16, palette: palette)
                }

                if variant != 1 {
                    HStack(spacing: 6) {
                        SkeletonBlock(width: 54, height: 18, cornerRadius: 9, phase: phase, phaseOffset: phaseOffset + 0.2, palette: palette)
                        SkeletonBlock(width: 48, height: 18, cornerRadius: 9, phase: phase, phaseOffset: phaseOffset + 0.22, palette: palette)
                    }
                }

                HStack(spacing: 6) {
                    SkeletonBlock(width: 54, height: 18, cornerRadius: 9, phase: phase, phaseOffset: phaseOffset + 0.28, palette: palette)
                    SkeletonBlock(width: 48, height: 18, cornerRadius: 9, phase: phase, phaseOffset: phaseOffset + 0.3, palette: palette)
                    SkeletonBlock(width: 42, height: 18, cornerRadius: 9, phase: phase, phaseOffset: phaseOffset + 0.32, palette: palette)
                }

                SkeletonBlock(width: 72, height: 5, cornerRadius: 3, phase: phase, phaseOffset: phaseOffset + 0.36, palette: palette)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }
}
