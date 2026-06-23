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
//  P0 性能（2026-06-23）：
//  - 卡片 ViewModel 预计算 + Equatable 隔离，避免 HomeViewModel 任意字段变化整树重绘；
//  - Masonry 分列 bucket 预计算，避免 body 内 O(n×列数) 扫描；
//  - Health 只查缺失 id；分页 debounce，减少快速滚动时瞬时建 view。
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
}

struct SmartCollectionDetailPanel: View {
    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppDependencies.self) private var dependencies

    @State private var healthSnapshots: [Int64: RepoHealthSnapshot] = [:]
    @State private var isLoadingHealth = false
    @State private var visibleCount = pageSize
    @State private var isRuleExpanded = false
    /// ScrollView 可用宽度；用 background GeometryReader 读取，避免外层 GeometryReader 包裹整棵 scroll 树。
    @State private var contentWidth: CGFloat = 720
    @State private var masonryColumns: [[SmartCollectionCardItem]] = []
    @State private var loadNextPageTask: Task<Void, Never>?

    private static let pageSize = 16
    private static let pageLoadDebounceNs: UInt64 = 300_000_000
    private static let cardSpacing: CGFloat = 12
    private static let minCardWidth: CGFloat = 280
    /// 与中栏 `SmartCollectionsOverviewView` 集合卡片同高，避免右栏顶区错层。
    private static let overviewCardMinHeight: CGFloat = 88
    private static let overviewCardPadding: CGFloat = 12
    private static let overviewOuterPadding: CGFloat = 16
    private static let overviewSectionSpacing: CGFloat = 12

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
        ScrollView {
            VStack(alignment: .leading, spacing: Self.overviewSectionSpacing) {
                collectionHeaderCard

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
                        SmartCollectionRepoCard(item: item)
                            .equatable()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedRepoID = item.id
                            }
                            .onAppear {
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
            .padding(.horizontal, Self.overviewOuterPadding)
            .padding(.vertical, Self.overviewOuterPadding)
        }
        .scrollIndicators(.visible)
        .background {
            // 只读宽度，不参与 ScrollView 内容测量，全屏 resize 时比外层 GeometryReader 更轻。
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
            healthSnapshots = [:]
            refreshMasonryLayout()
            await loadHealthSnapshots(for: visibleRepos.map(\.id))
        }
        .onChange(of: contentWidth) { _, _ in
            refreshMasonryLayout()
        }
        .onChange(of: visibleCount) { oldCount, newCount in
            refreshMasonryLayout()
            guard newCount > oldCount else { return }
            let newIDs = Array(repos.prefix(newCount).suffix(newCount - oldCount)).map(\.id)
            Task { await loadHealthSnapshots(for: newIDs) }
        }
        .onChange(of: viewModel.selectedRepoID) { _, _ in
            refreshMasonryLayout()
        }
        .onChange(of: viewModel.selection) { _, _ in
            isRuleExpanded = false
        }
    }

    /// 与中栏集合入口卡片同构：折叠态固定 88pt 内容高，展开规则时再向下撑开。
    private var collectionHeaderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(headerTint.opacity(0.18))
                        .frame(width: 30, height: 30)
                    Image(systemName: headerIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(headerTint)
                }

                Spacer(minLength: 4)

                Text(verbatim: "\(repos.count)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(headerTint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: true, vertical: false)

                if isLoadingHealth {
                    ProgressView()
                        .controlSize(.mini)
                }

                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isRuleExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("smartCollections.panel.rules")
                            .font(.caption2)
                            .fontWeight(.semibold)
                        Image(systemName: isRuleExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }

            Text(verbatim: title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if isRuleExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(ruleLines, id: \.self) { line in
                        Text(verbatim: line)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text(verbatim: collapsedSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.overviewCardMinHeight, alignment: .topLeading)
        .padding(Self.overviewCardPadding)
        .background(headerTint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(headerTint)
                .frame(width: 3)
                .padding(.vertical, 8)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(headerTint.opacity(0.42), lineWidth: 1)
        }
    }

    /// 折叠态第三行：与中栏卡片 subtitle 对齐，避免顶区高度漂移。
    private var collapsedSubtitle: String {
        switch viewModel.selection {
        case .smartCollection(let kind):
            return String.l10n("smartCollections.\(kind.rawValue).subtitle")
        case .userSmartCollection(let id):
            guard let rule = viewModel.userSmartCollection(id: id)?.rule else {
                return String.l10n("smartCollections.mine.fallback")
            }
            let context = viewModel.smartCollectionSummaryContext()
            return SmartCollectionRuleSummary.compact(rule: rule, context: context)
        default:
            return String.l10n("smartCollections.title")
        }
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

    private var headerIcon: String {
        switch viewModel.selection {
        case .smartCollection(let kind):
            return kind.systemImage
        case .userSmartCollection(let id):
            return viewModel.userSmartCollection(id: id)?.icon ?? "line.3.horizontal.decrease.circle"
        default:
            return "line.3.horizontal.decrease.circle"
        }
    }

    private var headerTint: Color {
        switch viewModel.selection {
        case .smartCollection(let kind):
            return kind.tint
        default:
            return .accentColor
        }
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
        let available = max(width - Self.overviewOuterPadding * 2, Self.minCardWidth)
        return max(1, Int((available + Self.cardSpacing) / (Self.minCardWidth + Self.cardSpacing)))
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
        let items = visible.map { repo in
            SmartCollectionCardItem(
                repo: repo,
                status: viewModel.readStatus(for: repo.id),
                userTags: tagsByRepoID[repo.id] ?? [],
                health: healthSnapshots[repo.id],
                isSelected: selectedID == repo.id
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

    /// 只查询缓存中缺失的 repo id，分页追加时不重复打 GRDB。
    private func loadHealthSnapshots(for ids: [Int64]) async {
        let missing = ids.filter { healthSnapshots[$0] == nil }
        guard !missing.isEmpty else { return }

        isLoadingHealth = true
        defer { isLoadingHealth = false }

        do {
            let loaded = try await dependencies.repoHealthRepository.snapshots(for: missing)
            healthSnapshots.merge(loaded) { _, new in new }
            refreshMasonryLayout()
        } catch {
            AppLog.database.warning("Smart Collection detail health load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

}

private struct SmartCollectionRepoCard: View, Equatable {
    private static let sectionSpacing: CGFloat = 6
    private static let chipRowHeight: CGFloat = 18
    private static let chipRowSpacing: CGFloat = 4

    let item: SmartCollectionCardItem

    @Environment(\.locale) private var locale

    static func == (lhs: SmartCollectionRepoCard, rhs: SmartCollectionRepoCard) -> Bool {
        lhs.item == rhs.item
    }

    private var repo: Repo { item.repo }
    private var status: RepoStatus { item.status }
    private var userTags: [Tag] { item.userTags }
    private var health: RepoHealthSnapshot? { item.health }
    private var isSelected: Bool { item.isSelected }

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
        let topicChips = repo.topicsArray.prefix(3).map { topic in
            SmartCollectionInfoChip(text: topic, systemImage: "number", tint: .secondary)
        }
        let tagChips = userTags.prefix(3).map { tag in
            SmartCollectionInfoChip(
                text: tag.name,
                systemImage: tag.icon ?? "tag",
                tint: Color(hex: tag.color ?? TagColorPalette.defaultHex) ?? .accentColor
            )
        }

        if !topicChips.isEmpty || !tagChips.isEmpty {
            VStack(alignment: .leading, spacing: Self.chipRowSpacing) {
                if !topicChips.isEmpty {
                    chipRow(topicChips)
                }
                if !tagChips.isEmpty {
                    chipRow(tagChips)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// 与 Manage `UnifiedRepoRow` chip 行对齐：Stars / Forks / Watchers / Issues 单行横排。
    private var statsRow: some View {
        HStack(spacing: 8) {
            StarsBadge(count: repo.starsCount, style: .full)
            MetaBadge(systemImage: "tuningfork", text: repo.forksCount.formattedShort, tint: .secondary)
            MetaBadge(systemImage: "eye", text: repo.watchersCount.formattedShort, tint: .secondary)
            MetaBadge(
                systemImage: "exclamationmark.circle",
                text: (repo.openIssuesCount ?? 0).formattedShort,
                tint: .secondary
            )
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var footer: some View {
        if showsFooter {
            HStack(alignment: .center, spacing: 8) {
                if let health, health.fetchStatus != .failed {
                    healthDimensionStrip(health)
                } else if repo.isArchived {
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
            || repo.isArchived
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
            MetaBadge(systemImage: "bookmark.fill", text: String.l10n("repo.status.using"), tint: .accentColor)
        case .read:
            EmptyView()
        }
    }

    /// topic / 标签 chip 行：列宽由 Masonry 列约束，行末裁剪，不用 GeometryReader（避免布局死循环）。
    private func chipRow(_ chips: [SmartCollectionInfoChip]) -> some View {
        HStack(spacing: 6) {
            ForEach(chips) { chip in
                SmartCollectionCompactInfoChip(
                    systemImage: chip.systemImage,
                    text: chip.text,
                    tint: chip.tint
                )
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.chipRowHeight, alignment: .leading)
        .clipped()
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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct SmartCollectionInfoChip: Identifiable {
    var id: String { "\(systemImage)|\(text)" }
    let text: String
    let systemImage: String
    let tint: Color
}

/// 右栏集合卡片专用 chip。列宽由 Masonry 约束，过长文案在胶囊内截断，行容器 `.clipped()` 防溢出。
private struct SmartCollectionCompactInfoChip: View {
    let systemImage: String
    let text: String
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
