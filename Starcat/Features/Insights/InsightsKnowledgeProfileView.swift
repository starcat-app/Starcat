//
//  InsightsKnowledgeProfileView.swift
//  Starcat
//
//  我的洞察中的个人知识画像。卡片、趋势和明细均读取同一次查询的证据。
//

import SwiftUI

private typealias Profile = InsightsKnowledgeProfile

/// 范围由洞察顶栏控制，维度和主题只在当前账号、范围及日期窗口内保留。
struct InsightsKnowledgeProfileView: View {
    let profile: InsightsKnowledgeProfile
    let openRepository: (RepositoryDeepLink) -> Void

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var scale
    @Namespace private var themeSelection
    @State private var dimension = KnowledgeProfileFacts.Dimension.topic
    @State private var themeID = InsightsKnowledgeProfile.ThemeID.all
    @State private var drilldown: ProfileDrilldown?
    @State private var showsThemes = false

    var body: some View {
        let themes = profile.themes[dimension, default: []]
        let theme = themes.first { $0.id == themeID } ?? profile.all
        let evidence = profile.evidence(for: theme)
        VStack(alignment: .leading, spacing: ProfileColumns.spacing) {
            ProfileColumns(scale: scale.multiplier) {
                recentFocus(theme: theme, evidence: evidence)
                knowledgePanel(theme: theme, evidence: evidence)
            }
            representatives(theme: theme, evidence: evidence)
        }
        .font(scale.font(.body))
        .foregroundStyle(.primary)
        .sheet(item: $drilldown) { detail in
            ProfileEvidenceSheet(detail: detail, openRepository: openRepository)
                .appLocaleEnvironment()
        }
        .sheet(isPresented: $showsThemes) {
            ProfileThemesSheet(themes: [profile.all] + themes, selected: theme.id) { themeID = $0 }
                .appLocaleEnvironment()
        }
    }

    private var dimensionPicker: some View {
        Picker("insights.profile.dimension", selection: $dimension) {
            Text("insights.profile.githubTopics").tag(KnowledgeProfileFacts.Dimension.topic)
            Text("sidebar.tags").tag(KnowledgeProfileFacts.Dimension.userTag)
            Text("insights.profile.mainLanguage").tag(KnowledgeProfileFacts.Dimension.language)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .onChange(of: dimension) { _, _ in themeID = .all }
    }

    /// 主数字、主题图和收藏次数共用同一个期间与范围。主题切换后仍能浏览其他主题。
    private func recentFocus(theme: Profile.Theme, evidence: Profile.Evidence) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    panelHeading("insights.profile.recentFocus").fixedSize()
                    Spacer(minLength: 0)
                    dimensionPicker.fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    panelHeading("insights.profile.recentFocus")
                    dimensionPicker
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if theme.id != .all {
                    Button { themeID = .all } label: {
                        HStack(spacing: 6) {
                            theme.id.label.lineLimit(2)
                            Image(systemName: "xmark.circle.fill").accessibilityHidden(true)
                        }
                        .font(scale.font(.captionStrong))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .foregroundStyle(.primary)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint(Text("dailyRadar.allTopics"))
                    .help(Text("dailyRadar.allTopics"))
                }
                Text("insights.profile.starredProjects").font(scale.font(.bodyEmphasis))
                HStack(alignment: .bottom, spacing: 12) {
                    stat(.starredProjects(.recent), label: Profile.Period.recent.title, size: 38,
                         theme: theme, evidence: evidence)
                    Divider().frame(height: scale.scaled(38))
                    stat(.starredProjects(.previous), label: Profile.Period.previous.title, size: 26,
                         theme: theme, evidence: evidence)
                }
                periodValues(.starActions(.recent), theme: theme, evidence: evidence)
            }
            .stableDetailTransition(value: theme.id)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                themeChart(selected: theme.id)
            }
            .stableDetailTransition(value: dimension)
            ViewThatFits(in: .horizontal) {
                HStack {
                    trendCoverage
                    Spacer(minLength: 8)
                    themesButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    trendCoverage
                    themesButton
                }
            }
        }
        .profilePanel()
    }

    /// 已观察到的主题用统一的零起点与上界。未分类不进入排名，也不改变其他主题的比例。
    @ViewBuilder
    private func themeChart(selected: Profile.ThemeID) -> some View {
        let comparisons = profile.comparisons(by: dimension)
        let named = Array(comparisons.filter { $0.id != .unclassified }.prefix(3))
        let maximum = max(1, named.flatMap { [$0.recent ?? 0, $0.previous ?? 0] }.max() ?? 0)
        ViewThatFits(in: .horizontal) {
            HStack {
                chartHeading
                Spacer(minLength: 8)
                periodLegend
            }
            VStack(alignment: .leading, spacing: 6) {
                chartHeading
                periodLegend
            }
        }
        if comparisons.isEmpty {
            Text("insights.profile.noThemeActivity")
                .font(scale.font(.caption))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        }
        if !named.isEmpty {
            VStack(spacing: 2) {
                ForEach(Array(named.enumerated()), id: \.element.id) { index, item in
                    comparisonRow(item, maximum: maximum, index: index, selected: selected)
                }
                HStack {
                    Text(0, format: .number)
                    Spacer(minLength: 0)
                    Text(maximum, format: .number)
                }
                .font(scale.font(.captionSmall).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, themeColumnWidth + 18)
                .padding(.trailing, countColumnWidth + 36)
                .accessibilityHidden(true)
            }
        }
        if let unclassified = comparisons.first(where: { $0.id == .unclassified }) {
            if !named.isEmpty { Divider() }
            comparisonRow(unclassified, maximum: nil, index: 0, selected: selected)
        }
    }

    private var chartHeading: some View {
        Text("insights.profile.trend")
            .font(scale.font(.bodyEmphasis))
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(Text("insights.profile.themeComparison"))
            .help(Text("insights.profile.themeComparison"))
    }

    private var periodLegend: some View {
        HStack(spacing: 12) {
            ForEach(Profile.Period.allCases, id: \.self) { period in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(period.barColor)
                        .frame(width: 10, height: period.barHeight)
                    Text(period.title)
                }
            }
        }
        .font(scale.font(.captionSmall))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    private var themeColumnWidth: CGFloat { scale.scaled(92) }
    private var countColumnWidth: CGFloat { scale.scaled(42) }

    private func comparisonRow(_ item: Profile.ThemeComparison, maximum: Int?, index: Int,
                               selected: Profile.ThemeID) -> some View {
        Button { themeID = item.id } label: {
            HStack(spacing: 10) {
                item.id.label
                    .lineLimit(2)
                    .font(scale.font(.bodyEmphasis))
                    .frame(width: maximum == nil ? nil : themeColumnWidth, alignment: .leading)
                if let maximum {
                    VStack(spacing: 3) {
                        ForEach(Profile.Period.allCases, id: \.self) { period in
                            comparisonBar(count: item.count(in: period), maximum: maximum, period: period)
                        }
                    }
                } else {
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        ForEach(Profile.Period.allCases, id: \.self) { period in
                            HStack(spacing: 4) {
                                Text(period.title).foregroundStyle(.secondary)
                                valueText(item.count(in: period)).monospacedDigit()
                            }
                            .font(scale.font(.captionSmall))
                        }
                    }
                }
                ProfileChevron()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .listRowSurface(index: index, isSelected: selected == item.id, selectionNamespace: themeSelection)
        .accessibilityLabel(item.id.label)
        .accessibilityValue(periodDescription(.recent, count: item.recent) + Text(verbatim: " · ")
                            + periodDescription(.previous, count: item.previous))
        .accessibilityAddTraits(selected == item.id ? .isSelected : [])
        .help(item.id.label)
    }

    private func comparisonBar(count: Int?, maximum: Int, period: Profile.Period) -> some View {
        HStack(spacing: 6) {
            GeometryReader { geometry in
                if let count {
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.12))
                        if count > 0 {
                            Capsule().fill(period.barColor)
                                .frame(width: geometry.size.width * CGFloat(count) / CGFloat(maximum))
                        }
                    }
                }
            }
            .frame(height: period.barHeight)
            valueText(count)
                .font(scale.font(.captionSmall).monospacedDigit())
                .foregroundStyle(period == .recent && count != nil ? .primary : .secondary)
                .frame(width: countColumnWidth, alignment: .trailing)
        }
    }

    private var trendCoverage: some View {
        Label {
            Text(verbatim: "— ") + Text("insights.profile.missing")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(scale.font(.captionSmall))
        .foregroundStyle(.secondary)
        .help(Text(profile.request.scope == .starred ? "insights.profile.starredHistory" : "insights.profile.libraryHistory")
              + Text(verbatim: "\n") + Text("insights.profile.classification"))
    }

    private var themesButton: some View {
        Button("insights.profile.viewAllThemes") { showsThemes = true }
            .buttonStyle(.link)
            .font(scale.font(.captionStrong))
    }

    private func knowledgePanel(theme: Profile.Theme, evidence: Profile.Evidence) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeading("insights.profile.collectionAndKnowledge")
            stat(.projects, label: Profile.Metric.projects.title, size: 34, theme: theme, evidence: evidence)
            Divider()
            HStack(alignment: .top, spacing: 12) {
                stat(.inLibrary, label: Profile.Metric.inLibrary.title, size: 23, theme: theme, evidence: evidence)
                Divider().frame(height: scale.scaled(38))
                stat(.using, label: Profile.Metric.using.title, size: 23, theme: theme, evidence: evidence)
            }
            Divider()
            VStack(spacing: 2) {
                ForEach([Profile.Metric.manualNotes, .aiNotes, .summaries]) { metric in
                    metricAction(metric, theme: theme, evidence: evidence) {
                        HStack(spacing: 8) {
                            Text(metric.title)
                            Spacer(minLength: 4)
                            valueText(evidence.count(metric)).font(scale.font(.bodyEmphasis).monospacedDigit())
                            ProfileChevron()
                        }
                        .padding(.vertical, 5)
                    }
                    if metric != .summaries { Divider() }
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                periodValues(.writtenProjects(.recent), theme: theme, evidence: evidence)
                LabeledContent {
                    Text(profile.facts.localCollectionStartedAt, format: .dateTime.year().month().day().locale(locale))
                } label: {
                    Text("insights.profile.noteHistorySince")
                }
            }
            .font(scale.font(.captionSmall))
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
        }
        .profilePanel()
        .stableDetailTransition(value: theme.id)
    }

    private func stat(_ metric: Profile.Metric, label: LocalizedStringKey, size: CGFloat,
                      theme: Profile.Theme, evidence: Profile.Evidence) -> some View {
        let count = evidence.count(metric)
        return metricAction(metric, theme: theme, evidence: evidence) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    valueText(count)
                        .font(scale.font(size: size, weight: .semibold).monospacedDigit())
                        .fixedSize(horizontal: true, vertical: false)
                    if count != nil { ProfileChevron() }
                }
                Text(label)
                    .font(scale.font(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func periodValues(_ metric: Profile.Metric, theme: Profile.Theme, evidence: Profile.Evidence) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(metric.title)
                Spacer(minLength: 0)
                periodNumbers(metric, theme: theme, evidence: evidence)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.title)
                periodNumbers(metric, theme: theme, evidence: evidence)
            }
        }
        .font(scale.font(.caption))
        .foregroundStyle(.secondary)
    }

    private func periodNumbers(_ metric: Profile.Metric, theme: Profile.Theme, evidence: Profile.Evidence) -> some View {
        HStack(spacing: 10) {
            ForEach([metric, metric.previous]) { value in
                metricAction(value, theme: theme, evidence: evidence) {
                    if let period = value.period {
                        Text(period.title)
                    }
                    valueText(evidence.count(value))
                        .font(scale.font(.captionStrong).monospacedDigit())
                        .foregroundStyle(evidence.count(value) == nil ? .secondary : .primary)
                }
            }
        }
    }

    /// 未覆盖的空区间没有可枚举的零值。数字按钮与明细都从同一个证据集取值。
    @ViewBuilder
    private func metricAction<Content: View>(_ metric: Profile.Metric, theme: Profile.Theme, evidence: Profile.Evidence,
                                             @ViewBuilder content: () -> Content) -> some View {
        if let count = evidence.count(metric) {
            Button { show(metric, theme: theme, evidence: evidence) } label: {
                HStack(spacing: 4, content: content)
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(metric.accessibilityTitle)
            .accessibilityValue(valueText(count))
            .help(metric.accessibilityTitle)
        } else {
            HStack(spacing: 4, content: content)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(metric.accessibilityTitle)
                .accessibilityValue(Text("insights.profile.missing"))
        }
    }

    private func representatives(theme: Profile.Theme, evidence: Profile.Evidence) -> some View {
        let matches = evidence.rows[.representatives, default: []]
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    panelHeading("insights.profile.examples")
                    if theme.id != .all {
                        theme.id.label.font(scale.font(.caption)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if !matches.isEmpty {
                    Button("insights.drilldown.viewAll") { show(.representatives, theme: theme, evidence: evidence) }
                        .buttonStyle(.link)
                        .font(scale.font(.captionStrong))
                }
            }
            if matches.isEmpty {
                Text("insights.repo.state.noData")
                    .font(scale.font(.caption))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(evidence.representativePreview.enumerated()), id: \.element.repoID) { index, match in
                        ProfileRepositoryRow(match: match, index: index, showsDate: true, showsReason: true,
                                             openRepository: openRepository)
                    }
                }
            }
        }
        .profilePanel()
        .stableDetailTransition(value: theme.id)
    }

    private func panelHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(scale.font(.panelTitle))
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func show(_ metric: Profile.Metric, theme: Profile.Theme, evidence: Profile.Evidence) {
        drilldown = ProfileDrilldown(metric: metric, theme: theme.id, rows: evidence.rows[metric, default: []])
    }
}

/// 用相同的断点和宽度测量内容、骨架与两列高度，窄窗切换时保留主题和焦点所在视图的身份。
private struct ProfileColumns: Layout {
    static let spacing: CGFloat = 14
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let proposedWidth = proposal.width ?? .infinity
        let width = proposedWidth.isFinite ? proposedWidth : 888 * scale
        let columns = widths(for: width)
        let primary = subviews[0].sizeThatFits(ProposedViewSize(width: columns.primary, height: nil))
        let secondary = subviews[1].sizeThatFits(ProposedViewSize(width: columns.secondary, height: nil))
        let height = columns.sideBySide ? max(primary.height, secondary.height)
            : primary.height + Self.spacing + secondary.height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = widths(for: bounds.width)
        let primary = ProposedViewSize(width: columns.primary, height: columns.sideBySide ? bounds.height : nil)
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: primary)
        let origin = columns.sideBySide
            ? CGPoint(x: bounds.minX + columns.primary + Self.spacing, y: bounds.minY)
            : CGPoint(x: bounds.minX, y: bounds.minY + subviews[0].sizeThatFits(primary).height + Self.spacing)
        subviews[1].place(at: origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: columns.secondary, height: columns.sideBySide ? bounds.height : nil))
    }

    private func widths(for width: CGFloat) -> (primary: CGFloat, secondary: CGFloat, sideBySide: Bool) {
        let available = width - Self.spacing
        guard available >= 730 * scale else { return (width, width, false) }
        let secondary = max(272 * scale, available / 3)
        return (available - secondary, secondary, true)
    }
}

private extension View {
    /// 与其他洞察共用系统表面和描边，只有间距与两列对齐由画像负责。
    func profilePanel() -> some View {
        let chrome = InsightsSectionChrome.emphasized
        let shape = RoundedRectangle(cornerRadius: chrome.cornerRadius)
        return padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(chrome.fill, in: shape)
            .overlay { shape.strokeBorder(Color.secondary.opacity(chrome.strokeOpacity)) }
    }
}

/// 画像首次加载的骨架沿用两列、主题条及代表仓库的布局，并共用现成的减少动态效果策略。
struct InsightsKnowledgeProfileSkeleton: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var scale

    var body: some View {
        SkeletonAnimatedPhase { phase in
            let palette = SkeletonPalette.forColorScheme(colorScheme)
            VStack(spacing: ProfileColumns.spacing) {
                ProfileColumns(scale: scale.multiplier) {
                    VStack(alignment: .leading, spacing: 14) {
                        SkeletonBlock(width: 96, height: 17, phase: phase, palette: palette)
                        SkeletonBlock(width: 142, height: 56, phase: phase, palette: palette)
                        Divider()
                        SkeletonBlock(width: 84, height: 14, phase: phase, palette: palette)
                        ForEach(0..<3, id: \.self) { index in
                            HStack(spacing: 12) {
                                SkeletonBlock(width: 58, height: 12, phase: phase, palette: palette)
                                SkeletonBlock(maxWidth: CGFloat(280 - index * 40), height: 20, phase: phase, palette: palette)
                            }
                            .frame(height: 38)
                        }
                    }
                    .profilePanel()
                    VStack(alignment: .leading, spacing: 14) {
                        SkeletonBlock(width: 130, height: 17, phase: phase, palette: palette)
                        SkeletonBlock(width: 118, height: 42, phase: phase, palette: palette)
                        Divider()
                        SkeletonBlock(maxWidth: 176, height: 44, phase: phase, palette: palette)
                        Divider()
                        ForEach(0..<3, id: \.self) { _ in
                            SkeletonBlock(maxWidth: 192, height: 15, phase: phase, palette: palette)
                        }
                    }
                    .profilePanel()
                }
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(width: 88, height: 17, phase: phase, palette: palette)
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonBlock(maxWidth: 216, height: 16, phase: phase, palette: palette)
                            .frame(height: 28)
                    }
                }
                .profilePanel()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ProfileChevron: View {
    @Environment(\.starcatInterfaceScale) private var scale

    var body: some View {
        Image(systemName: "chevron.forward")
            .font(scale.font(.captionSmall))
            .foregroundStyle(.secondary)
            .frame(width: 12)
            .accessibilityHidden(true)
    }
}

private func valueText(_ count: Int?) -> Text {
    guard let count else { return Text(verbatim: "—") }
    return Text(count, format: .number)
}

private func periodDescription(_ period: Profile.Period, count: Int?) -> Text {
    Text(period.title) + Text(verbatim: " · ") + (count == nil ? Text("insights.profile.missing") : valueText(count))
}

/// 完整主题列表与卡片保持同一筛选语义，搜索只限制可见项，不改变主题计数。
private struct ProfileThemesSheet: View {
    let themes: [Profile.Theme]
    let selected: Profile.ThemeID
    let select: (Profile.ThemeID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var scale
    @State private var query = ""

    private var matches: [Profile.Theme] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return themes }
        return themes.filter {
            $0.id.searchName.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("dailyRadar.allTopics").font(scale.font(.panelTitle))
                Spacer()
                SheetCloseButton { dismiss() }
                    .accessibilityLabel(Text("common.close")).keyboardShortcut(.cancelAction)
            }
            .padding()
            TextField("insights.profile.searchThemes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal).padding(.bottom, 12)
            Divider()
            let visible = matches
            if visible.isEmpty {
                ContentUnavailableView("empty.noResults", systemImage: "magnifyingglass")
            } else {
                List(Array(visible.enumerated()), id: \.element.id) { index, theme in
                    Button {
                        select(theme.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            theme.id.label.lineLimit(2)
                            Spacer()
                            Text(theme.current.count, format: .number)
                                .font(scale.font(.caption).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: "checkmark")
                                .opacity(selected == theme.id ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.primary)
                        .padding(7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .listRowSurface(index: index, isSelected: selected == theme.id)
                    .accessibilityLabel(theme.id.label)
                    .accessibilityValue(Text("insights.metric.projects") + Text(verbatim: " · ") + valueText(theme.current.count))
                    .accessibilityAddTraits(selected == theme.id ? .isSelected : [])
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .font(scale.font(.body))
        .frame(minWidth: 360, idealWidth: 480, minHeight: 360, idealHeight: 460)
    }
}

/// 明细冻结点击时的集合。次数指标保留同一仓库的多行，仓库指标每个项目只有一行。
private struct ProfileDrilldown: Identifiable {
    let metric: Profile.Metric
    let theme: Profile.ThemeID
    let rows: [Profile.Match]
    var id: Profile.Metric { metric }
}

private struct ProfileEvidenceSheet: View {
    let detail: ProfileDrilldown
    let openRepository: (RepositoryDeepLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.starcatInterfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(detail.metric.title).font(scale.font(.panelTitle))
                    HStack {
                        detail.theme.label
                        if let period = detail.metric.period { Text(period.title) }
                        Text(detail.rows.count, format: .number)
                    }
                    .font(scale.font(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                SheetCloseButton { dismiss() }
                    .accessibilityLabel(Text("common.close")).keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if detail.rows.isEmpty {
                ContentUnavailableView("insights.repo.state.noData", systemImage: "folder")
            } else {
                List(detail.rows.indices, id: \.self) { index in
                    ProfileRepositoryRow(match: detail.rows[index], index: index,
                                         showsDate: detail.metric.period != nil || detail.metric == .representatives,
                                         showsReason: detail.metric == .representatives) { link in
                        dismiss()
                        openRepository(link)
                    }
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 390, idealWidth: 520, minHeight: 300, idealHeight: 460)
    }
}

/// 已清理缓存的仓库保留可验证的历史名称或 ID，只有有效的仓库目标才显示导航按钮。
private struct ProfileRepositoryRow: View {
    let match: Profile.Match
    let index: Int
    let showsDate: Bool
    let showsReason: Bool
    let openRepository: (RepositoryDeepLink) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var scale

    var body: some View {
        Group {
            if let link = match.repositoryLink {
                Button { openRepository(link) } label: { row }
                    .buttonStyle(.borderless)
            } else {
                row
            }
        }
        .listRowSurface(index: index)
    }

    private var row: some View {
        HStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(scale.font(.iconMedium))
                .foregroundStyle(.secondary)
                .frame(width: scale.scaled(20))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: match.fullName ?? "#\(match.repoID)")
                    .font(scale.font(.rowTitle))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if showsReason, let reason = match.representativeReason {
                    Text(reason.title)
                        .font(scale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if showsDate, let date = match.date {
                Text(date, format: .dateTime.month().day().locale(locale))
                    .font(scale.font(.caption))
                    .foregroundStyle(.secondary)
            }
            if match.repositoryLink != nil { ProfileChevron() }
        }
        .padding(8).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private extension Profile.ThemeID {
    var label: Text {
        switch self {
        case .all: Text("dailyRadar.allTopics")
        case .named(let name): Text(verbatim: name)
        case .unclassified: Text("trending.language.uncategorized")
        }
    }

    var searchName: String {
        switch self {
        case .all: String.l10n("dailyRadar.allTopics")
        case .named(let name): name
        case .unclassified: String.l10n("trending.language.uncategorized")
        }
    }
}

private extension Profile.Period {
    var title: LocalizedStringKey { self == .recent ? "widget.collectionTrend.last30Days" : "insights.profile.previous" }
    var barColor: Color { self == .recent ? .accentColor : .secondary.opacity(0.58) }
    var barHeight: CGFloat { self == .recent ? 9 : 5 }
}

private extension Profile.Match.RepresentativeReason {
    var title: LocalizedStringKey {
        switch self {
        case .manualNote: "insights.profile.manualNotes"
        case .using: "insights.metric.using"
        case .recentlyRecorded: "insights.profile.recentlyRecorded"
        }
    }
}

private extension Profile.Metric {
    var title: LocalizedStringKey {
        switch self {
        case .projects: "insights.metric.projects"
        case .inLibrary: "insights.knowledgeCoverage.library"
        case .using: "insights.metric.using"
        case .manualNotes: "insights.profile.manualNotes"
        case .aiNotes: "rag.workspace.inspector.metadata.help.artifacts.field.aiGeneratedNotes"
        case .summaries: "rag.workspace.inspector.metadata.help.artifacts.field.aiSummaries"
        case .representatives: "insights.profile.examples"
        case .starActions: "insights.profile.starActions"
        case .starredProjects: "insights.profile.starredProjects"
        case .writtenProjects: "insights.profile.writingProjects"
        }
    }

    var period: Profile.Period? {
        switch self {
        case .starActions(let period), .starredProjects(let period), .writtenProjects(let period): period
        default: nil
        }
    }

    var accessibilityTitle: Text {
        guard let period else { return Text(title) }
        return Text(title) + Text(verbatim: " · ") + Text(period.title)
    }

    var previous: Self {
        switch self {
        case .starActions: .starActions(.previous)
        case .starredProjects: .starredProjects(.previous)
        case .writtenProjects: .writtenProjects(.previous)
        default: self
        }
    }
}
