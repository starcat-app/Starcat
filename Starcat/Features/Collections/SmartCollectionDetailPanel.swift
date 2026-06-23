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
//

import SwiftUI
import AppKit

struct SmartCollectionDetailPanel: View {
    @Environment(HomeViewModel.self) private var viewModel
    @Environment(AppDependencies.self) private var dependencies

    @State private var healthSnapshots: [Int64: RepoHealthSnapshot] = [:]
    @State private var isLoadingHealth = false
    @State private var visibleCount = pageSize
    @State private var isRuleExpanded = false

    private static let pageSize = 24
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

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Self.overviewSectionSpacing) {
                    collectionHeaderCard

                    if viewModel.isLoading && repos.isEmpty {
                        SmartCollectionCardSkeletonGrid(
                            columns: columns(for: proxy.size.width),
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
                        LazyVGrid(
                            columns: columns(for: proxy.size.width),
                            alignment: .leading,
                            spacing: Self.cardSpacing
                        ) {
                            ForEach(visibleRepos) { repo in
                                SmartCollectionRepoCard(
                                    repo: repo,
                                    status: viewModel.readStatus(for: repo.id),
                                    userTags: viewModel.tags(for: repo.id),
                                    health: healthSnapshots[repo.id],
                                    isSelected: viewModel.selectedRepoID == repo.id,
                                    onSelect: {
                                        viewModel.selectedRepoID = repo.id
                                    }
                                )
                                .onAppear {
                                    loadNextPageIfNeeded(repo)
                                }
                            }
                        }

                        if visibleCount < repos.count {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                                    .onAppear(perform: loadNextPage)
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
        }
        .task(id: viewModel.itemsRevision) {
            visibleCount = Self.pageSize
            await loadHealthSnapshots()
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

    private func columns(for width: CGFloat) -> [GridItem] {
        let available = max(width - Self.overviewOuterPadding * 2, Self.minCardWidth)
        let count = max(1, Int((available + Self.cardSpacing) / (Self.minCardWidth + Self.cardSpacing)))
        return Array(
            repeating: GridItem(.flexible(minimum: Self.minCardWidth), spacing: Self.cardSpacing, alignment: .top),
            count: count
        )
    }

    private func loadNextPageIfNeeded(_ repo: Repo) {
        guard repo.id == visibleRepos.last?.id else { return }
        loadNextPage()
    }

    private func loadNextPage() {
        guard visibleCount < repos.count else { return }
        visibleCount = min(visibleCount + Self.pageSize, repos.count)
    }

    private func loadHealthSnapshots() async {
        let ids = repos.map(\.id)
        guard !ids.isEmpty else {
            healthSnapshots = [:]
            return
        }

        isLoadingHealth = true
        defer { isLoadingHealth = false }

        do {
            healthSnapshots = try await dependencies.repoHealthRepository.snapshots(for: ids)
        } catch {
            AppLog.database.warning("Smart Collection detail health load failed: \(error.localizedDescription, privacy: .public)")
            healthSnapshots = [:]
        }
    }

}

private struct SmartCollectionRepoCard: View {
    private static let sectionSpacing: CGFloat = 6
    private static let chipRowHeight: CGFloat = 18
    private static let chipRowSpacing: CGFloat = 4
    /// topics + 用户标签两行固定占位，保证 Grid 内卡片等高（无 topics 时也保留空行）。
    private static let tagAreaHeight: CGFloat = chipRowHeight * 2 + chipRowSpacing

    let repo: Repo
    let status: RepoStatus
    let userTags: [Tag]
    let health: RepoHealthSnapshot?
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.locale) private var locale

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
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
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
                    urlString: repo.ownerAvatar,
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

    private var description: some View {
        Group {
            if let description = repo.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("smartCollections.panel.noDescription")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(height: 32, alignment: .topLeading)
        .clipped()
    }

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

        return VStack(alignment: .leading, spacing: Self.chipRowSpacing) {
            chipRowSlot(topicChips)
            chipRowSlot(tagChips)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: Self.tagAreaHeight, maxHeight: Self.tagAreaHeight, alignment: .topLeading)
        .clipped()
    }

    /// 固定 18pt 行高：有 chip 则渲染，无 chip 则透明占位。
    @ViewBuilder
    private func chipRowSlot(_ chips: [SmartCollectionInfoChip]) -> some View {
        if chips.isEmpty {
            Color.clear
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: Self.chipRowHeight, maxHeight: Self.chipRowHeight)
        } else {
            chipRow(chips)
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
        .frame(height: 22, alignment: .leading)
        .clipped()
    }

    private var footer: some View {
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
        .frame(height: 18, alignment: .center)
        .clipped()
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

    /// topic / 标签 chip 行：短 topic 保持自然宽度；总宽超出卡片时在最后一个 chip 内截断，其余隐藏。
    private func chipRow(_ chips: [SmartCollectionInfoChip]) -> some View {
        GeometryReader { proxy in
            SmartCollectionFittingChipRow(
                chips: chips,
                availableWidth: max(0, proxy.size.width)
            )
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: Self.chipRowHeight, maxHeight: Self.chipRowHeight)
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

/// 单行 topic / 标签布局：按可用宽度贪心排布，绝不向 LazyVGrid 上报超宽 ideal size。
private struct SmartCollectionFittingChipRow: View {
    let chips: [SmartCollectionInfoChip]
    let availableWidth: CGFloat

    private static let spacing: CGFloat = 6
    private static let minChipWidth: CGFloat = 40

    var body: some View {
        let layoutItems = Self.layoutItems(chips: chips, availableWidth: availableWidth)

        HStack(spacing: Self.spacing) {
            ForEach(layoutItems) { item in
                SmartCollectionCompactInfoChip(
                    systemImage: item.chip.systemImage,
                    text: item.chip.text,
                    tint: item.chip.tint,
                    maxWidth: item.maxWidth
                )
            }
        }
        .frame(width: availableWidth, height: 18, alignment: .leading)
        .clipped()
    }

    private struct LayoutItem: Identifiable {
        let id: String
        let chip: SmartCollectionInfoChip
        /// nil = 自然宽度；非 nil = 限制最大宽并在胶囊内截断文案。
        let maxWidth: CGFloat?
    }

    /// 贪心：能完整放下就完整放；最后一个放不下的 chip 用剩余宽度截断；再后面的直接丢弃。
    private static func layoutItems(
        chips: [SmartCollectionInfoChip],
        availableWidth: CGFloat
    ) -> [LayoutItem] {
        guard availableWidth > 0, !chips.isEmpty else { return [] }

        var result: [LayoutItem] = []
        var usedWidth: CGFloat = 0

        for chip in chips {
            let gap = result.isEmpty ? 0 : spacing
            let remaining = availableWidth - usedWidth - gap
            guard remaining >= minChipWidth else { break }

            let naturalWidth = estimatedChipWidth(text: chip.text)
            if naturalWidth <= remaining {
                result.append(LayoutItem(id: chip.id, chip: chip, maxWidth: nil))
                usedWidth += gap + naturalWidth
            } else {
                result.append(LayoutItem(id: chip.id, chip: chip, maxWidth: remaining))
                break
            }
        }

        return result
    }

    /// 用 NSFont 估算 chip 自然宽，避免 SwiftUI ideal size 把 HStack 撑破 Grid 列。
    private static func estimatedChipWidth(text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        // icon(8) + icon/text spacing(3) + horizontal padding(14)
        return ceil(textWidth) + 25
    }
}

/// 右栏集合卡片专用 chip。
///
/// GitHub topics / 用户标签名都不是受控文案；短 topic 保持紧凑，长 topic 在胶囊内截断。
/// 行容器由 `SmartCollectionFittingChipRow` 按卡片实际宽度裁剪，禁止向 Grid 上报超宽 ideal size。
private struct SmartCollectionCompactInfoChip: View {
    let systemImage: String
    let text: String
    let tint: Color
    var maxWidth: CGFloat?

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
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: maxWidth == nil, vertical: false)
        .clipped()
    }
}

private struct SmartCollectionCardSkeletonGrid: View {
    let columns: [GridItem]
    let spacing: CGFloat

    var body: some View {
        SkeletonAnimatedPhase { phase in
            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                ForEach(0..<8, id: \.self) { index in
                    SmartCollectionCardSkeleton(phase: phase, phaseOffset: Double(index) * 0.08)
                }
            }
        }
    }
}

private struct SmartCollectionCardSkeleton: View {
    let phase: Double
    let phaseOffset: Double

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
                SkeletonBlock(maxWidth: .infinity, height: 11, phase: phase, phaseOffset: phaseOffset + 0.14, palette: palette)

                HStack(spacing: 6) {
                    SkeletonBlock(width: 54, height: 18, cornerRadius: 9, phase: phase, phaseOffset: phaseOffset + 0.2, palette: palette)
                    SkeletonBlock(width: 48, height: 18, cornerRadius: 9, phase: phase, phaseOffset: phaseOffset + 0.22, palette: palette)
                    SkeletonBlock(width: 42, height: 18, cornerRadius: 9, phase: phase, phaseOffset: phaseOffset + 0.24, palette: palette)
                }
                .frame(height: 40, alignment: .topLeading)

                SkeletonBlock(width: 72, height: 5, cornerRadius: 3, phase: phase, phaseOffset: phaseOffset + 0.36, palette: palette)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }
}
