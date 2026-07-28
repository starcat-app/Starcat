//
//  RepositoryInsightsView.swift
//  Starcat
//
//  仓库详情内的洞察页面。
//
//  Star 趋势使用独立 ViewModel 与范围，避免活动指标的 range、刷新和失败状态污染
//  长期历史；其余区块继续消费各自的本地或远端状态机。
//

import AppKit
import Charts
import SwiftUI

struct RepositoryInsightsView: View {
    private struct TimelineDisplayItem: Identifiable {
        let id: String
        let title: String
        let detail: String
        let occurredAt: Date
        let systemImage: String
        let tintName: String
        /// 有值时可跳 GitHub（PR / Issue / Release）；提交汇总行保持 nil。
        let destinationURL: URL?
    }

    let repo: Repo
    let viewModel: RepositoryInsightsViewModel
    let starHistoryViewModel: StarHistoryViewModel
    let onScrollReport: (RepoDetailScrollReport) -> Void

    @State private var selectedStarDate: Date?
    /// Commit 柱图悬停选中的周序号（分类轴 index），与柱一一对应。
    @State private var selectedCommitWeekIndex: Int?
    /// 时间线悬停行，用于光标聚焦高亮。
    @State private var hoveredTimelineItemID: String?
    /// Community / Security 信号行悬停，交互与时间线一致。
    @State private var hoveredLocalSignalID: String?
    /// 贡献者卡片悬停。
    @State private var hoveredContributorID: String?
    /// 时间线默认只展示最近几条，避免整页被事件列表撑满。
    @State private var isTimelineExpanded = false
    /// 贡献者默认截断；点击 +N /「查看全部」再展开。
    @State private var isContributorsExpanded = false

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(AuthSession.self) private var authSession

    private static let visibleContributorLimit = 6
    private static let collapsedTimelineLimit = 5

    init(
        repo: Repo,
        viewModel: RepositoryInsightsViewModel,
        starHistoryViewModel: StarHistoryViewModel,
        onScrollReport: @escaping (RepoDetailScrollReport) -> Void
    ) {
        self.repo = repo
        self.viewModel = viewModel
        self.starHistoryViewModel = starHistoryViewModel
        self.onScrollReport = onScrollReport
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // 洞察页区块含 Charts；LazyVStack 会反复估算高度并与滚动回写形成反馈。
                // 改为 VStack，并用「概览 / 深潜」两段节奏降低同权卡片疲劳。
                VStack(alignment: .leading, spacing: 16) {
                    // 上半：一眼能扫完的本地事实 + 活动 KPI
                    localOverviewSection
                    activitySection

                    Divider()
                        .opacity(0.35)
                        .padding(.vertical, 2)

                    // 下半：需要盯图的深潜区块；分区 Sync 保留，底栏另有全局刷新。
                    starHistorySection
                    commitSection
                    contributorSection
                    healthSection
                    localSignalsSection
                    timelineSection
                }
                // 外层 Scaffold 在 Hero 折叠后会扩大正文视口；内容栈必须坚持使用卡片的
                // 固有高度，否则 VStack 会接受扩大的纵向 proposal，在最后一张卡片后留下
                // 一段可滚动但不可见的空白。这里只固定纵向，横向仍随详情栏宽度铺满。
                .fixedSize(horizontal: false, vertical: true)
                .padding(18)
            }
            .detailScrollViewStyle()
            .onScrollGeometryChange(for: RepoDetailScrollReport.self) { geometry in
                RepoDetailScrollReport(
                    offsetY: max(0, geometry.contentOffset.y),
                    scrollOverflow: max(0, geometry.contentSize.height - geometry.containerSize.height)
                )
            } action: { previous, report in
                guard report.differsMeaningfully(from: previous) else { return }
                onScrollReport(report)
            }

            // 对齐 README cacheFooter：底栏只挂全局 Sync；左侧不放「缓存于」。
            insightsGlobalFooter
        }
        .accessibilityLabel(Text("insights.repo.mode.insights"))
    }

    /// README 底栏同款 `.bar`；右侧全局刷新，分区 Sync 全部保留。
    private var insightsGlobalFooter: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            SyncIconButton(
                isRefreshing: isGlobalRefreshing,
                disabled: isGlobalRefreshing,
                font: .caption2,
                frameSize: 18,
                tooltip: String.l10n("insights.repo.refreshAll"),
                action: {
                    Task {
                        await refreshAllInsights()
                    }
                }
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .foregroundStyle(.secondary)
        .background(.bar)
    }

    private var isGlobalRefreshing: Bool {
        viewModel.isRefreshingAll || starHistoryViewModel.isRefreshing
    }

    private func refreshAllInsights() async {
        let authenticated = authSession.state.isAuthenticated
        async let insightsLoad: Void = viewModel.refreshAll(
            repo: repo,
            isAuthenticated: authenticated
        )
        async let starLoad: Void = starHistoryViewModel.refresh(repo: repo)
        _ = await (insightsLoad, starLoad)
    }

    private var localOverviewSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.local",
            subtitle: "insights.repo.section.local.subtitle",
            systemImage: "internaldrive.fill"
        ) {
            // 与活动概览同款：四卡一行、标题行彩色图标、数值居中加大。
            HStack(alignment: .top, spacing: 10) {
                localFact(
                    title: "insights.repo.local.release",
                    systemImage: "tag.fill",
                    tintName: "blue",
                    value: releaseValue
                )
                localFact(
                    title: "insights.repo.local.license",
                    systemImage: "checkmark.seal.fill",
                    tintName: "green",
                    value: repo.license ?? String.l10n("insights.repo.state.noData")
                )
                localFact(
                    title: "insights.repo.local.health",
                    systemImage: "heart.text.square.fill",
                    tintName: "orange",
                    value: healthValue
                )
                localFact(
                    title: "insights.repo.local.openssf",
                    systemImage: "shield.checkered",
                    tintName: "purple",
                    value: openSSFValue
                )
            }
        }
    }

    private func localFact(
        title: LocalizedStringKey,
        systemImage: String,
        tintName: String,
        value: String?
    ) -> some View {
        let tint = InsightsColor.resolve(tintName)
        let displayValue = value ?? "—"
        let isPlaceholder = value == nil
            || value == String.l10n("insights.repo.state.noData")
            || value == String.l10n("error.loadFailed")

        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(interfaceScale.font(.caption))

            Text(verbatim: displayValue)
                .font(interfaceScale.font(size: 22, weight: .semibold))
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.55),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: displayValue))
    }

    private var releaseValue: String? {
        switch viewModel.releaseState {
        case .loading, .idle:
            return nil
        case .content(let release):
            return release.tagName
        case .empty, .unavailable:
            return String.l10n("insights.repo.state.noData")
        case .failed:
            return String.l10n("error.loadFailed")
        }
    }

    private var healthValue: String? {
        switch viewModel.healthState {
        case .loading, .idle:
            return nil
        case .content(let health):
            return "\(health.overallScore) · \(health.grade)"
        case .empty, .unavailable:
            return String.l10n("insights.repo.state.noData")
        case .failed:
            return String.l10n("error.loadFailed")
        }
    }

    private var openSSFValue: String? {
        switch viewModel.openSSFState {
        case .loading, .idle:
            return nil
        case .content(let openSSF):
            return String(format: "%.1f / 10", locale: locale, openSSF.score)
        case .empty, .unavailable:
            return String.l10n("insights.repo.state.noData")
        case .failed:
            return String.l10n("error.loadFailed")
        }
    }

    private var activitySection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.activity",
            subtitle: "insights.repo.section.activity.subtitle",
            systemImage: "waveform.path.ecg"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // 标题与四卡之间单独一行：时间切换靠右，绝不挤进指标行或掉到卡片底。
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    activityControls
                }

                ZStack(alignment: .topLeading) {
                    activityBody
                        .id(viewModel.activityRange)
                        .detailContentTransition()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.35),
                    value: viewModel.activityRange
                )
            }
        }
    }

    private var activityControls: some View {
                // 活动范围只在这里控制；提交图有独立 range，避免双控件抢同一状态。
                HStack(spacing: 8) {
                    // 活动范围只在这里控制一次；提交图有独立 binding。
                    activityRangePicker
                    activityRefreshButton
                }
    }

    @ViewBuilder
    private var activityBody: some View {
        if let counts = displayedActivityCounts {
            // 有缓存就只展示指标；刷新态由 SyncIconButton 表达，不再塞状态文案行。
            HStack(alignment: .top, spacing: 10) {
                ForEach(activityMetrics(from: counts)) { metric in
                    activityMetric(metric)
                }
            }
        } else {
            switch viewModel.activityState {
            case .idle, .loading:
                sectionLoadingPlaceholder
            case .generating:
                compactEmptyState(
                    "insights.repo.state.generating",
                    systemImage: "clock.arrow.circlepath"
                )
            case .unavailable:
                compactEmptyState(
                    authSession.state.isAuthenticated
                        ? "insights.repo.state.noData"
                        : "insights.repo.state.loginRequired",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            case .failed:
                compactEmptyState(
                    "error.loadFailed",
                    systemImage: "exclamationmark.triangle"
                )
            case .content, .stale:
                EmptyView()
            }
        }
    }

    private var activityRangePicker: some View {
        PillSegmentedControl(
            items: Array(RepositoryActivityRange.allCases),
            selection: activityRangeBinding,
            title: { LocalizedStringKey($0.titleKey) },
            size: .compact
        )
        .accessibilityLabel(Text("insights.repo.activity.range.label"))
    }

    private var activityRefreshButton: some View {
        SyncIconButton(
            isRefreshing: viewModel.isRefreshingActivity,
            disabled: viewModel.isRefreshingActivity,
            tooltip: String.l10n("insights.repo.activity.refresh")
        ) {
            Task {
                await viewModel.refreshActivity(
                    repo: repo,
                    isAuthenticated: authSession.state.isAuthenticated
                )
            }
        }
    }

    private var activityRangeBinding: Binding<RepositoryActivityRange> {
        Binding(
            get: { viewModel.activityRange },
            set: { range in
                Task {
                    await viewModel.selectActivityRange(
                        range,
                        repo: repo,
                        isAuthenticated: authSession.state.isAuthenticated
                    )
                }
            }
        )
    }

    private var commitActivityRangeBinding: Binding<RepositoryActivityRange> {
        Binding(
            get: { viewModel.commitActivityRange },
            set: { range in
                selectedCommitWeekIndex = nil
                viewModel.selectCommitActivityRange(range)
            }
        )
    }

    private var displayedActivityCounts: RepositoryActivityCounts? {
        switch viewModel.activityState {
        case .content(let value), .stale(let value):
            return value
        case .loading(let cached),
             .generating(let cached),
             .unavailable(let cached),
             .failed(let cached):
            return cached
        case .idle:
            return nil
        }
    }

    private func activityMetrics(
        from counts: RepositoryActivityCounts
    ) -> [RepositoryActivityMetric] {
        [
            RepositoryActivityMetric(
                id: "createdPullRequests",
                titleKey: "insights.repo.activity.createdPullRequests",
                value: counts.createdPullRequests,
                delta: nil,
                systemImage: "arrow.triangle.pull",
                tintName: "purple"
            ),
            RepositoryActivityMetric(
                id: "mergedPullRequests",
                titleKey: "insights.repo.activity.mergedPullRequests",
                value: counts.mergedPullRequests,
                delta: nil,
                systemImage: "arrow.triangle.merge",
                tintName: "green"
            ),
            RepositoryActivityMetric(
                id: "createdIssues",
                titleKey: "insights.repo.activity.createdIssues",
                value: counts.createdIssues,
                delta: nil,
                systemImage: "record.circle",
                tintName: "orange"
            ),
            RepositoryActivityMetric(
                id: "closedIssues",
                titleKey: "insights.repo.activity.closedIssues",
                value: counts.closedIssues,
                delta: nil,
                systemImage: "checkmark.circle",
                tintName: "blue"
            )
        ]
    }

    private func activityMetric(_ metric: RepositoryActivityMetric) -> some View {
        let tint = InsightsColor.resolve(metric.tintName)
        // 布局/字号/底色与 localFact 保持同一套，避免两块「看起来像两套组件」。
        return VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: metric.systemImage)
                    .foregroundStyle(tint)
                Text(LocalizedStringKey(metric.titleKey))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .font(interfaceScale.font(.caption))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.value.formatted(.number.locale(locale)))
                    .font(interfaceScale.font(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let delta = metric.delta {
                    Text(verbatim: delta >= 0 ? "+\(delta)%" : "\(delta)%")
                        .font(interfaceScale.font(.captionSmall, weight: .medium))
                        .foregroundStyle(delta >= 0 ? .green : .red)
                        .monospacedDigit()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.55),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(metric.titleKey)))
        .accessibilityValue(Text(verbatim: activityMetricAccessibilityValue(metric)))
    }

    private func activityMetricAccessibilityValue(_ metric: RepositoryActivityMetric) -> String {
        let value = metric.value.formatted(.number.locale(locale))
        let delta = metric.delta.map { $0 >= 0 ? "+\($0)%" : "\($0)%" }
        return [
            value,
            delta,
            String.l10n(viewModel.activityRange.titleKey)
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    private var starHistorySection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.stars",
            subtitle: "insights.repo.section.stars.subtitle",
            systemImage: "star.fill",
            headerTrailing: { starDataSourceBadge }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        starMetrics
                        Spacer(minLength: 8)
                        starControls
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        starMetrics
                        starControls
                    }
                }

                if !displayedStarPoints.isEmpty {
                    // 图表单独做范围过渡；只用淡入淡出，不用上下位移（会顶布局抖页面）。
                    VStack(alignment: .leading, spacing: 10) {
                        ZStack(alignment: .topLeading) {
                            starChart
                                .id(starHistoryViewModel.range)
                                .transition(.opacity)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.2),
                            value: starHistoryViewModel.range
                        )

                        starFooter
                    }
                } else if !isStarHistoryWaitingForFirstPaint {
                    chartEmptyState(
                        "insights.repo.star.state.unavailable",
                        systemImage: "star.slash"
                    )
                }
            }
        }
    }

    /// 首次拉取尚未落点时，不额外画空态，避免和标题栏刷新转圈叠两套反馈。
    private var isStarHistoryWaitingForFirstPaint: Bool {
        switch starHistoryViewModel.phase {
        case .idle, .loading, .building:
            return displayedStarPoints.isEmpty
        default:
            return false
        }
    }

    private var starCoverageFooter: some View {
        HStack(spacing: 5) {
            Text("insights.repo.star.coverage")
            if let coverageStart = starHistoryViewModel.coverageStart {
                Text(coverageStart, format: .dateTime.year().month().day())
            } else {
                Text("insights.repo.state.noData")
            }
            Text("·")
            Text("insights.repo.star.updated")
            if let updatedAt = starHistoryViewModel.updatedAt {
                Text(updatedAt, format: .dateTime.year().month().day().hour().minute())
            } else {
                Text("insights.repo.state.noData")
            }
        }
        .font(interfaceScale.font(.captionSmall))
        .foregroundStyle(.secondary)
    }

    /// 图例、读数、覆盖区间合成一条脚注，避免图表下叠三层说明块。
    private var starFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            starSources
            if let point = readableStarPoint {
                let value = String(
                    format: String.l10n("insights.repo.star.reading.valueFormat"),
                    locale: locale,
                    shortDate(point.date),
                    point.count.formatted(.number.locale(locale)),
                    change(for: point).map(signed)
                        ?? String.l10n("insights.repo.star.change.baseline"),
                    starSourceName(point.source),
                    starPrecisionName(point.precision)
                )
                Text(verbatim: value)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("insights.repo.star.reading.label"))
                    .accessibilityValue(Text(verbatim: value))
            }
            starCoverageFooter
        }
        .padding(.horizontal, 2)
    }

    private func starMetric(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(verbatim: value)
                .font(interfaceScale.font(size: 20, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.55),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value))
    }

    private var starMetrics: some View {
        // 三个指标固定一行：自适应网格会把「1 年增长」挤到下一行。
        HStack(alignment: .top, spacing: 8) {
            starMetric(
                value: starHistoryViewModel.currentStars?.formatted(.number.locale(locale))
                    ?? String.l10n("insights.repo.state.noData"),
                label: "insights.repo.star.current"
            )
            starMetric(
                value: signed(starHistoryViewModel.growth30Days),
                label: "insights.repo.star.growth30Days"
            )
            starMetric(
                value: signed(starHistoryViewModel.growthOneYear),
                label: "insights.repo.star.growthOneYear"
            )
        }
    }

    private var starControls: some View {
        HStack(spacing: 8) {
            PillSegmentedControl(
                items: Array(StarHistoryRange.allCases),
                selection: starRangeBinding,
                title: starRangeTitle,
                size: .compact
            )
            .accessibilityLabel(Text("insights.repo.star.range.label"))

            starRefreshButton
        }
    }

    private var starRefreshButton: some View {
        SyncIconButton(
            isRefreshing: starHistoryViewModel.isRefreshing,
            disabled: starHistoryViewModel.isRefreshing,
            tooltip: String.l10n("insights.repo.star.refresh")
        ) {
            Task {
                await starHistoryViewModel.refresh(repo: repo)
            }
        }
    }

    private var starSources: some View {
        // HStack + 单行文案：避免 LazyVGrid 把 chip 压窄后「precise snapshots」折行。
        HStack(spacing: 6) {
            if displayedStarPoints.contains(where: { $0.precision == .estimated }) {
                starSourceChip(
                    title: "insights.repo.star.source.estimated",
                    systemImage: "waveform.path.ecg",
                    dashed: true
                )
            }
            if displayedStarPoints.contains(where: { $0.precision == .snapshot }) {
                starSourceChip(
                    title: "insights.repo.star.source.snapshot",
                    systemImage: "internaldrive.fill",
                    dashed: false
                )
            }
            Spacer(minLength: 0)
        }
    }

    private func starSourceChip(
        title: LocalizedStringKey,
        systemImage: String,
        dashed: Bool
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Rectangle()
                .fill(Color.blue.opacity(dashed ? 0.65 : 1))
                .frame(width: 18, height: dashed ? 1 : 2)
        }
        .font(interfaceScale.font(.captionSmall, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: Capsule())
    }

    private func starSelectionAnnotation(_ point: StarHistoryPoint) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: fullDate(point.date))
            Text("·")
            Text(point.count.formatted(.number.locale(locale)))
                .monospacedDigit()
        }
        .font(interfaceScale.font(.captionSmall, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
    }

    private var displayedStarPoints: [StarHistoryPoint] {
        starHistoryViewModel.points
    }

    private var estimatedStarPoints: [StarHistoryPoint] {
        displayedStarPoints.filter { $0.precision == .estimated }
    }

    private var preciseStarPoints: [StarHistoryPoint] {
        displayedStarPoints.filter { $0.precision == .snapshot }
    }

    private var selectedStarPoint: StarHistoryPoint? {
        guard let selectedStarDate else { return nil }
        return displayedStarPoints.min {
            abs($0.date.timeIntervalSince(selectedStarDate)) < abs($1.date.timeIntervalSince(selectedStarDate))
        }
    }

    private var readableStarPoint: StarHistoryPoint? {
        selectedStarPoint ?? displayedStarPoints.last
    }

    private func change(for point: StarHistoryPoint) -> Int? {
        guard let index = displayedStarPoints.firstIndex(where: { $0.id == point.id }),
              index > displayedStarPoints.startIndex
        else {
            return nil
        }
        return point.count - displayedStarPoints[displayedStarPoints.index(before: index)].count
    }

    private func signed(_ value: Int?) -> String {
        guard let value else {
            return String.l10n("insights.repo.state.noData")
        }
        let formatted = value.formatted(.number.locale(locale))
        return value >= 0 ? "+\(formatted)" : formatted
    }

    /// 图表读数必须显式使用应用内 Locale；否则用户切换 Starcat 语言后，
    /// 日期仍可能跟随 macOS 系统 Locale，形成同屏混排。
    private func fullDate(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle()
                .year()
                .month()
                .day()
                .locale(locale)
        )
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .locale(locale)
        )
    }

    private var starRangeBinding: Binding<StarHistoryRange> {
        Binding(
            get: { starHistoryViewModel.range },
            set: { newRange in
                selectedStarDate = nil
                Task {
                    await starHistoryViewModel.selectRange(newRange, repo: repo)
                }
            }
        )
    }

    private func starRangeTitle(_ range: StarHistoryRange) -> LocalizedStringKey {
        switch range {
        case .threeMonths: return "insights.repo.star.range.threeMonths"
        case .oneYear: return "insights.repo.star.range.oneYear"
        case .all: return "insights.repo.star.range.all"
        }
    }

    /// 标题行右侧数据来源徽章：只留图标，文案走 help / VoiceOver，避免图表下再塞一行提示。
    @ViewBuilder
    private var starDataSourceBadge: some View {
        if let badge = starDataSourceBadgeInfo {
            Image(systemName: badge.systemImage)
                .font(interfaceScale.font(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .help(Text(badge.helpKey))
                .accessibilityLabel(Text(badge.helpKey))
        }
    }

    private var starDataSourceBadgeInfo: (systemImage: String, helpKey: LocalizedStringKey)? {
        switch starHistoryViewModel.phase {
        case .building:
            return ("clock.arrow.circlepath", "insights.repo.star.state.building")
        case .stale:
            // 远端刷新失败、当前本地缓存。
            return ("icloud.slash", "insights.repo.star.state.stale")
        case .privateOnly:
            return ("lock.fill", "insights.repo.star.state.private")
        case .failed where displayedStarPoints.isEmpty:
            return ("exclamationmark.triangle", "error.loadFailed")
        case .unavailable where displayedStarPoints.isEmpty:
            return ("star.slash", "insights.repo.star.state.unavailable")
        default:
            // 正常有点：有估算历史视为远端可用，否则本机快照。
            guard !displayedStarPoints.isEmpty else { return nil }
            if displayedStarPoints.contains(where: { $0.precision == .estimated }) {
                return ("icloud", "insights.repo.star.source.estimated")
            }
            return ("internaldrive.fill", "insights.repo.star.source.snapshot")
        }
    }

    private var starChart: some View {
        let yUpper = starYAxisUpperBound
        return Chart {
            ForEach(displayedStarPoints) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    y: .value("Stars", point.count)
                )
                .foregroundStyle(Color.blue.opacity(0.08))
                .interpolationMethod(.catmullRom)
            }

            ForEach(estimatedStarPoints) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Stars", point.count),
                    series: .value("Source", "Estimated")
                )
                .foregroundStyle(Color.blue.opacity(0.72))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                .interpolationMethod(.catmullRom)
            }

            ForEach(preciseStarPoints) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Stars", point.count),
                    series: .value("Source", "Snapshot")
                )
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .interpolationMethod(.catmullRom)
                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Stars", point.count)
                )
                .foregroundStyle(Color.blue)
                .symbolSize(20)
            }

            if displayedStarPoints.count == 1, let point = displayedStarPoints.first {
                PointMark(
                    x: .value("Date", point.date),
                    y: .value("Stars", point.count)
                )
                .foregroundStyle(Color.blue)
                .symbolSize(34)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(verbatim: starAxisLabel(date))
                            .font(interfaceScale.font(.captionSmall))
                    }
                }
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.08))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel()
                    .font(interfaceScale.font(.captionSmall))
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
            }
        }
        // 锁 Y 域：悬停浮层不进 marks，避免图内 RuleMark/annotation 挤占绘图区把曲线「截断」。
        .chartYScale(domain: 0...yUpper)
        .chartXSelection(value: $selectedStarDate)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let point = selectedStarPoint,
                   let plotAnchor = proxy.plotFrame {
                    let plot = geometry[plotAnchor]
                    if let xInPlot = proxy.position(forX: point.date) {
                        let lineX = plot.origin.x + xInPlot
                        Path { path in
                            path.move(to: CGPoint(x: lineX, y: plot.minY))
                            path.addLine(to: CGPoint(x: lineX, y: plot.maxY))
                        }
                        .stroke(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                        let tooltipWidth: CGFloat = 160
                        let clampedX = min(
                            max(lineX, plot.minX + tooltipWidth / 2),
                            plot.maxX - tooltipWidth / 2
                        )
                        starSelectionAnnotation(point)
                            .position(x: clampedX, y: plot.minY + 16)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: Self.chartPlotHeight)
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("insights.repo.section.stars"))
        .accessibilityValue(Text(starChartAccessibilityValue))
    }

    /// 跨度不到两个月时带上「日」，避免横轴刷出一排相同的「2026年7月」。
    private func starAxisLabel(_ date: Date) -> String {
        let points = displayedStarPoints
        guard let first = points.first, let last = points.last else {
            return fullDate(date)
        }
        let span = last.date.timeIntervalSince(first.date)
        let twoMonths: TimeInterval = 60 * 24 * 3600
        if span < twoMonths {
            return date.formatted(
                Date.FormatStyle()
                    .month(.abbreviated)
                    .day()
                    .locale(locale)
            )
        }
        return date.formatted(
            Date.FormatStyle()
                .year()
                .month(.abbreviated)
                .locale(locale)
        )
    }

    private var starYAxisUpperBound: Double {
        let maxCount = displayedStarPoints.map(\.count).max() ?? 0
        guard maxCount > 0 else { return 1 }
        return Double(maxCount) * 1.12
    }

    private var starChartAccessibilityValue: String {
        guard let first = displayedStarPoints.first,
              let latest = displayedStarPoints.last
        else {
            return String.l10n("insights.repo.star.state.unavailable")
        }
        return String(
            format: String.l10n("insights.repo.star.chart.summaryFormat"),
            locale: locale,
            shortDate(first.date),
            shortDate(latest.date),
            latest.count.formatted(.number.locale(locale)),
            signed(starHistoryViewModel.growthOneYear)
        )
    }

    private func starSourceName(_ source: StarHistorySource) -> String {
        switch source {
        case .ghArchive:
            return String.l10n("insights.repo.star.source.name.ghArchive")
        case .discoverySnapshot:
            return String.l10n("insights.repo.star.source.name.discovery")
        case .localSnapshot:
            return String.l10n("insights.repo.star.source.name.local")
        }
    }

    private func starPrecisionName(_ precision: StarHistoryPrecision) -> String {
        switch precision {
        case .estimated:
            return String.l10n("insights.repo.star.precision.estimated")
        case .snapshot:
            return String.l10n("insights.repo.star.precision.snapshot")
        }
    }

    private var commitSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.commits",
            subtitle: "insights.repo.section.commits.subtitle",
            systemImage: "chart.bar.fill"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // 与活动概览同款控件；范围独立，不再跟 activityRange 联动。
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        PillSegmentedControl(
                            items: Array(RepositoryActivityRange.allCases),
                            selection: commitActivityRangeBinding,
                            title: { LocalizedStringKey($0.titleKey) },
                            size: .compact
                        )
                        .accessibilityLabel(Text("insights.repo.activity.range.label"))

                        SyncIconButton(
                            isRefreshing: viewModel.isRefreshingCommitActivity,
                            disabled: viewModel.isRefreshingCommitActivity,
                            tooltip: String.l10n("insights.repo.commit.refresh")
                        ) {
                            Task {
                                await viewModel.refreshCommitActivity(
                                    repo: repo,
                                    isAuthenticated: authSession.state.isAuthenticated
                                )
                            }
                        }
                    }
                }

                ZStack(alignment: .topLeading) {
                    commitBody
                        .id(viewModel.commitActivityRange)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.2),
                    value: viewModel.commitActivityRange
                )
            }
        }
    }

    @ViewBuilder
    private var commitBody: some View {
        if let activity = displayedCommitActivity {
            let points = activity.points(in: viewModel.commitActivityRange)
            if points.isEmpty {
                chartEmptyState(
                    commitEmptyStateKey,
                    systemImage: commitEmptyStateSystemImage
                )
            } else {
                commitChart(points: points)
            }
        } else {
            switch viewModel.commitActivityState {
            case .idle, .loading:
                chartEmptyState(
                    "insights.repo.state.generating",
                    systemImage: "clock.arrow.circlepath"
                )
            case .generating:
                chartEmptyState(
                    "insights.repo.state.generating",
                    systemImage: "clock.arrow.circlepath"
                )
            case .unavailable:
                chartEmptyState(
                    authSession.state.isAuthenticated
                        ? "insights.repo.state.noData"
                        : "insights.repo.state.loginRequired",
                    systemImage: authSession.state.isAuthenticated
                        ? "chart.bar.xaxis"
                        : "person.crop.circle.badge.exclamationmark"
                )
            case .failed:
                chartEmptyState("error.loadFailed", systemImage: "exclamationmark.triangle")
            case .content, .stale:
                EmptyView()
            }
        }
    }

    private func commitChart(points: [RepositoryCommitActivityPoint]) -> some View {
        let categories = points.indices.map(commitWeekCategory)
        let labelCategories = commitAxisLabelCategories(count: points.count)
        // 锁死 Y 域：悬停浮层不进 Chart marks，坐标轴不会因标注重算而抖。
        let yUpper = commitYAxisUpperBound(for: points)
        return Chart {
            ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                let isHighlighted = selectedCommitWeekIndex == index
                // 必须用分类轴（String）：连续 Int 域下 BarMark 默认带宽≈0，柱会「消失」。
                BarMark(
                    x: .value("Week", commitWeekCategory(index)),
                    y: .value("Commits", point.commits),
                    width: .ratio(0.72)
                )
                .foregroundStyle(commitBarFill(isHighlighted: isHighlighted))
                .cornerRadius(5)
            }
        }
        .chartXAxis {
            AxisMarks(values: labelCategories) { value in
                AxisValueLabel(centered: true) {
                    if let category = value.as(String.self),
                       let index = commitWeekIndex(fromCategory: category),
                       points.indices.contains(index) {
                        Text(
                            points[index].weekStart,
                            format: Date.FormatStyle()
                                .month(.abbreviated)
                                .day()
                                .locale(locale)
                        )
                        .font(interfaceScale.font(.captionSmall))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisValueLabel()
                    .font(interfaceScale.font(.captionSmall))
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
            }
        }
        .chartXScale(domain: categories)
        .chartYScale(domain: 0...yUpper)
        // 详情浮在绘图区上方；命中用 hover 坐标反查分类，离开清空，避免粘滞选中。
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = proxy.plotFrame.map { geometry[$0] }

                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            // location 在 overlay GeometryReader 坐标系；value(atX:) /
                            // position(forX:) 用的是 plot 原点相对坐标，必须先减掉 Y 轴占位。
                            guard let plot, plot.contains(location) else {
                                clearCommitHoverSelection()
                                return
                            }
                            let xInPlot = location.x - plot.origin.x
                            guard let index = commitWeekIndex(
                                nearestToX: xInPlot,
                                proxy: proxy,
                                pointCount: points.count
                            ) else {
                                clearCommitHoverSelection()
                                return
                            }
                            // 柱间切换：无动画瞬切，避免 snappy / ease 拖出「延迟感」。
                            // 从无选中 → 首次命中：只给浮层一次极短淡入。
                            guard selectedCommitWeekIndex != index else { return }
                            if selectedCommitWeekIndex == nil, !reduceMotion {
                                withAnimation(.easeOut(duration: 0.08)) {
                                    selectedCommitWeekIndex = index
                                }
                            } else {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    selectedCommitWeekIndex = index
                                }
                            }
                        case .ended:
                            clearCommitHoverSelection()
                        }
                    }

                if let index = selectedCommitWeekIndex,
                   points.indices.contains(index),
                   let plot,
                   let xInPlot = proxy.position(forX: commitWeekCategory(index)) {
                    let point = points[index]
                    let tooltipWidth: CGFloat = 168
                    let rawX = plot.origin.x + xInPlot
                    let clampedX = min(
                        max(rawX, plot.minX + tooltipWidth / 2),
                        plot.maxX - tooltipWidth / 2
                    )
                    commitHoverTooltip(point)
                        .position(x: clampedX, y: plot.minY + 16)
                        // 柱间移动不插值位移（那会又慢又生硬）；仅首次出现淡入。
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: Self.chartPlotHeight)
        .padding(10)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityLabel(Text("insights.repo.section.commits"))
        .accessibilityValue(
            Text(verbatim: commitChartAccessibilityValue(points: points))
        )
    }

    /// 分类轴稳定 key；避免用 Date 连续轴导致选中吸错柱。
    private func commitWeekCategory(_ index: Int) -> String {
        String(format: "%03d", index)
    }

    private func commitWeekIndex(fromCategory category: String) -> Int? {
        Int(category)
    }

    /// 在 plot 相对 X 上按柱中心找最近周。分类轴离散，比 `value(atX:)` 更贴光标。
    private func commitWeekIndex(
        nearestToX xInPlot: CGFloat,
        proxy: ChartProxy,
        pointCount: Int
    ) -> Int? {
        guard pointCount > 0 else { return nil }
        var bestIndex: Int?
        var bestDistance = CGFloat.infinity
        for index in 0..<pointCount {
            guard let barX = proxy.position(forX: commitWeekCategory(index)) else { continue }
            let distance = abs(barX - xInPlot)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// 点少时每柱一个刻度；点多时抽稀，避免 X 轴挤成一团。
    private func commitAxisLabelCategories(count: Int) -> [String] {
        commitAxisLabelIndices(count: count).map(commitWeekCategory)
    }

    private func commitAxisLabelIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        if count <= 8 {
            return Array(0..<count)
        }
        let step = max(1, count / 6)
        var indices = Array(stride(from: 0, to: count, by: step))
        if indices.last != count - 1 {
            indices.append(count - 1)
        }
        return indices
    }

    private func commitYAxisUpperBound(for points: [RepositoryCommitActivityPoint]) -> Double {
        let maxCommits = points.map(\.commits).max() ?? 0
        guard maxCommits > 0 else { return 1 }
        // 略留头顶空间给浮层，刻度仍由 Charts 取整显示。
        return Double(maxCommits) * 1.18
    }

    /// 悬停只「加亮当前柱」，不压暗其它柱——Charts 对 gradient 插值差，压暗会像硬切。
    private func commitBarFill(isHighlighted: Bool) -> LinearGradient {
        let topOpacity: Double = isHighlighted ? 1.0 : 0.88
        let bottomOpacity: Double = isHighlighted ? 0.82 : 0.52
        return LinearGradient(
            colors: [
                Color.accentColor.opacity(topOpacity),
                Color.accentColor.opacity(bottomOpacity)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 离开绘图区时清选中；短淡出浮层，柱色仍瞬切。
    private func clearCommitHoverSelection() {
        guard selectedCommitWeekIndex != nil else { return }
        if reduceMotion {
            selectedCommitWeekIndex = nil
        } else {
            withAnimation(.easeOut(duration: 0.06)) {
                selectedCommitWeekIndex = nil
            }
        }
    }

    private var selectedCommitPoint: RepositoryCommitActivityPoint? {
        guard let selectedCommitWeekIndex,
              let activity = displayedCommitActivity
        else { return nil }
        let points = activity.points(in: viewModel.commitActivityRange)
        guard points.indices.contains(selectedCommitWeekIndex) else { return nil }
        return points[selectedCommitWeekIndex]
    }

    private func commitHoverTooltip(_ point: RepositoryCommitActivityPoint) -> some View {
        Text(
            verbatim: "\(fullDate(point.weekStart)) · \(String(format: String.l10n("insights.repo.contributor.commitsFormat"), locale: locale, point.commits))"
        )
        .font(interfaceScale.font(.captionSmall, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .fixedSize()
    }

    private func commitChartAccessibilityValue(
        points: [RepositoryCommitActivityPoint]
    ) -> String {
        if let point = selectedCommitPoint {
            return "\(fullDate(point.weekStart)), \(point.commits)"
        }
        return String(
            format: String.l10n("insights.repo.commit.totalFormat"),
            locale: locale,
            points.reduce(0) { $0 + $1.commits }
        )
    }

    private var commitEmptyStateKey: LocalizedStringKey {
        switch viewModel.commitActivityState {
        case .generating:
            return "insights.repo.state.generating"
        case .failed:
            return "error.loadFailed"
        case .unavailable:
            return authSession.state.isAuthenticated
                ? "insights.repo.state.noData"
                : "insights.repo.state.loginRequired"
        default:
            return "insights.repo.state.noData"
        }
    }

    private var commitEmptyStateSystemImage: String {
        switch viewModel.commitActivityState {
        case .generating:
            return "clock.arrow.circlepath"
        case .failed:
            return "exclamationmark.triangle"
        case .unavailable:
            return authSession.state.isAuthenticated
                ? "chart.bar.xaxis"
                : "person.crop.circle.badge.exclamationmark"
        default:
            return "chart.bar.xaxis"
        }
    }

    private var displayedCommitActivity: RepositoryCommitActivity? {
        switch viewModel.commitActivityState {
        case .content(let value), .stale(let value):
            return value
        case .loading(let cached),
             .generating(let cached),
             .unavailable(let cached),
             .failed(let cached):
            return cached
        case .idle:
            return nil
        }
    }

    private var contributorSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.contributors",
            subtitle: "insights.repo.section.contributors.subtitle",
            systemImage: "person.3.fill"
        ) {
            // 刷新入口收敛到活动 / Star / Commit；本块只读展示，避免一屏多个 Sync。
            VStack(alignment: .leading, spacing: 10) {
                if let insight = displayedContributors {
                    if insight.contributors.isEmpty {
                        compactEmptyState(
                            "insights.repo.state.noData",
                            systemImage: "person.3.sequence"
                        )
                    } else {
                        let visible = isContributorsExpanded
                            ? insight.contributors
                            : Array(insight.contributors.prefix(Self.visibleContributorLimit))
                        let hiddenCount = max(
                            0,
                            insight.contributors.count - Self.visibleContributorLimit
                        )
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 142), spacing: 10)],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(visible) { contributor in
                                contributorItem(contributor)
                            }
                            if !isContributorsExpanded, hiddenCount > 0 {
                                Button {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                                        isContributorsExpanded = true
                                    }
                                } label: {
                                    Text(verbatim: "+\(hiddenCount)")
                                        .font(interfaceScale.font(.caption, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focusEffectDisabled()
                                .accessibilityLabel(Text("insights.drilldown.viewAll"))
                                .accessibilityValue(Text(verbatim: "+\(hiddenCount)"))
                            }
                        }

                        if insight.contributors.count > Self.visibleContributorLimit {
                            Button {
                                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                                    isContributorsExpanded.toggle()
                                }
                            } label: {
                                Text(
                                    isContributorsExpanded
                                        ? "rag.workspace.citations.collapse"
                                        : "insights.drilldown.viewAll"
                                )
                                .font(interfaceScale.font(.caption, weight: .medium))
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .focusEffectDisabled()
                        }
                    }
                } else {
                    switch viewModel.contributorsState {
                    case .idle, .loading:
                        sectionLoadingPlaceholder
                    case .unavailable:
                        compactEmptyState(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                    case .generating:
                        compactEmptyState(
                            "insights.repo.state.generating",
                            systemImage: "clock.arrow.circlepath"
                        )
                    case .failed:
                        compactEmptyState(
                            "error.loadFailed",
                            systemImage: "exclamationmark.triangle"
                        )
                    case .content, .stale:
                        EmptyView()
                    }
                }
            }
        }
    }

    private func contributorItem(_ contributor: RepositoryContributor) -> some View {
        let destinationURL = contributorProfileURL(contributor)
        let isHovered = hoveredContributorID == contributor.id
        let content = HStack(spacing: 8) {
            AsyncImage(url: contributor.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Text(String(contributor.login.prefix(1)).uppercased())
                    .font(interfaceScale.font(.caption, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 低透明度强调色让 `.primary` 在明暗主题和增强对比度下都保持系统语义。
                    .background(InsightsColor.resolve(contributor.colorName).opacity(0.2))
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: contributor.login)
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right.square")
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(
                    String(
                        format: String.l10n("insights.repo.contributor.commitsFormat"),
                        locale: locale,
                        contributor.commits
                    )
                )
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredContributorID = contributor.id
            } else if hoveredContributorID == contributor.id {
                hoveredContributorID = nil
            }
        }

        return Button {
            NSWorkspace.shared.open(destinationURL)
        } label: {
            content
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(Text(verbatim: destinationURL.absoluteString))
        .accessibilityAddTraits(.isLink)
    }

    /// 优先 API `html_url`；旧缓存缺失时用 github.com/{login}。
    private func contributorProfileURL(_ contributor: RepositoryContributor) -> URL {
        if let profileHTMLURL = contributor.profileHTMLURL {
            return profileHTMLURL
        }
        let encoded = contributor.login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? contributor.login
        return URL(string: "https://github.com/\(encoded)")!
    }

    private var displayedContributors: RepositoryContributorsInsight? {
        switch viewModel.contributorsState {
        case .content(let value), .stale(let value):
            return value
        case .loading(let cached),
             .generating(let cached),
             .unavailable(let cached),
             .failed(let cached):
            return cached
        case .idle:
            return nil
        }
    }

    private var healthSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.health",
            subtitle: "insights.repo.section.health.subtitle",
            systemImage: "heart.text.square.fill"
        ) {
            Group {
                switch viewModel.healthState {
                case .content(let health):
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 148), spacing: 10)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(healthDimensions(from: health)) { dimension in
                            healthItem(dimension)
                        }
                    }
                case .loading, .idle:
                    sectionLoadingPlaceholder
                case .empty, .unavailable:
                    compactEmptyState(
                        "insights.repo.state.noData",
                        systemImage: "heart.slash"
                    )
                case .failed:
                    compactEmptyState(
                        "error.loadFailed",
                        systemImage: "exclamationmark.triangle"
                    )
                }
            }
        }
    }

    private func healthItem(_ dimension: RepositoryHealthDimensionItem) -> some View {
        let tint = InsightsColor.resolve(dimension.tintName)
        // 细条 + 小号分数，弱化「表单 ProgressView」感，仍保留可读对比度。
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: dimension.systemImage)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                Text(LocalizedStringKey(dimension.titleKey))
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: "\(dimension.score)")
                    .font(interfaceScale.font(.captionSmall, weight: .semibold))
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(
                            width: max(
                                4,
                                proxy.size.width * CGFloat(dimension.score) / 100
                            )
                        )
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.4),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(dimension.titleKey)))
        .accessibilityValue(
            Text(verbatim: dimension.score.formatted(.number.locale(locale)))
        )
    }

    private var localSignalsSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                communitySignalGroup.frame(minWidth: 248)
                securitySignalGroup.frame(minWidth: 248)
            }
            VStack(spacing: 14) {
                communitySignalGroup
                securitySignalGroup
            }
        }
    }

    private var communitySignalGroup: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.community",
            subtitle: "insights.repo.section.community.subtitle",
            systemImage: "person.2.fill"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if let community = displayedCommunity {
                    Text(
                        String(
                            format: String.l10n("insights.repo.community.healthFormat"),
                            locale: locale,
                            community.healthPercentage
                        )
                    )
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                    VStack(spacing: 0) {
                        localSignalRow(
                            id: "community.readme",
                            title: "insights.repo.signal.readme",
                            isAvailable: community.hasReadme,
                            systemImage: "doc.text.fill",
                            destinationURL: communitySignalURL(
                                isAvailable: community.hasReadme,
                                stored: community.readmeHTMLURL,
                                fallbackSuffix: "#readme"
                            )
                        )
                        Divider().padding(.leading, 28)
                        localSignalRow(
                            id: "community.conduct",
                            title: "insights.repo.signal.conduct",
                            isAvailable: community.hasCodeOfConduct,
                            systemImage: "person.2.fill",
                            destinationURL: communitySignalURL(
                                isAvailable: community.hasCodeOfConduct,
                                stored: community.codeOfConductHTMLURL,
                                fallbackSuffix: "/community"
                            )
                        )
                        Divider().padding(.leading, 28)
                        localSignalRow(
                            id: "community.contributing",
                            title: "insights.repo.signal.contributing",
                            isAvailable: community.hasContributing,
                            systemImage: "hand.raised.fill",
                            destinationURL: communitySignalURL(
                                isAvailable: community.hasContributing,
                                stored: community.contributingHTMLURL,
                                fallbackSuffix: "/community"
                            )
                        )
                        Divider().padding(.leading, 28)
                        localSignalRow(
                            id: "community.license",
                            title: "insights.repo.signal.license",
                            isAvailable: community.hasLicense,
                            systemImage: "checkmark.seal.fill",
                            destinationURL: communitySignalURL(
                                isAvailable: community.hasLicense,
                                stored: community.licenseHTMLURL,
                                fallbackSuffix: "/community"
                            )
                        )
                    }
                } else {
                    switch viewModel.remoteCommunityState {
                    case .idle, .loading:
                        sectionLoadingPlaceholder
                    case .unavailable:
                        compactEmptyState(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "person.2.slash"
                        )
                    case .generating:
                        compactEmptyState(
                            "insights.repo.state.generating",
                            systemImage: "clock.arrow.circlepath"
                        )
                    case .failed:
                        compactEmptyState(
                            "error.loadFailed",
                            systemImage: "exclamationmark.triangle"
                        )
                    case .content, .stale:
                        EmptyView()
                    }
                }
            }
        }
    }

    private var displayedCommunity: RepositoryCommunityInsight? {
        switch viewModel.remoteCommunityState {
        case .content(let value), .stale(let value):
            return value
        case .loading(let cached),
             .generating(let cached),
             .unavailable(let cached),
             .failed(let cached):
            return cached
        case .idle:
            return nil
        }
    }

    private var securitySignalGroup: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.security",
            subtitle: "insights.repo.section.security.subtitle",
            systemImage: "lock.shield.fill"
        ) {
            switch viewModel.openSSFState {
            case .content(let openSSF):
                localSignalRow(
                    id: "security.openssf",
                    title: "insights.repo.signal.openssf",
                    statusText: String(format: "%.1f / 10", locale: locale, openSSF.score),
                    statusColor: openSSF.score >= 5 ? .green : .orange,
                    systemImage: "shield.checkered",
                    destinationURL: openSSFScorecardURL
                )
            case .loading, .idle:
                sectionLoadingPlaceholder
            case .empty, .unavailable:
                compactEmptyState(
                    "insights.repo.state.noData",
                    systemImage: "shield.slash"
                )
            case .failed:
                compactEmptyState(
                    "error.loadFailed",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    /// Available 才可跳；优先 API `html_url`，旧缓存缺失时用仓库页约定路径。
    private func communitySignalURL(
        isAvailable: Bool,
        stored: URL?,
        fallbackSuffix: String
    ) -> URL? {
        guard isAvailable else { return nil }
        if let stored { return stored }
        let base = repo.htmlUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + fallbackSuffix)
    }

    /// 与详情页 OpenSSF sheet 同源 scorecard.dev 查看器。
    private var openSSFScorecardURL: URL? {
        URL(string: "https://scorecard.dev/viewer/?uri=github.com/\(repo.owner)/\(repo.name)")
    }

    private func localSignalRow(
        id: String,
        title: LocalizedStringKey,
        isAvailable: Bool,
        systemImage: String,
        destinationURL: URL?
    ) -> some View {
        localSignalRow(
            id: id,
            title: title,
            statusText: String.l10n(
                isAvailable ? "insights.repo.signal.available" : "insights.repo.signal.missing"
            ),
            statusColor: isAvailable ? .green : .orange,
            systemImage: systemImage,
            destinationURL: destinationURL
        )
    }

    @ViewBuilder
    private func localSignalRow(
        id: String,
        title: LocalizedStringKey,
        statusText: String,
        statusColor: Color,
        systemImage: String,
        destinationURL: URL?
    ) -> some View {
        let isTappable = destinationURL != nil
        let isHovered = hoveredLocalSignalID == id
        let content = HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Text(title)
                    .font(interfaceScale.font(.caption))
                if isTappable {
                    Image(systemName: "arrow.up.right.square")
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: statusText)
                .font(interfaceScale.font(.captionSmall, weight: .medium))
                .foregroundStyle(statusColor)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovered && isTappable ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            guard isTappable else { return }
            if hovering {
                hoveredLocalSignalID = id
            } else if hoveredLocalSignalID == id {
                hoveredLocalSignalID = nil
            }
        }

        if let destinationURL {
            Button {
                NSWorkspace.shared.open(destinationURL)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text(verbatim: destinationURL.absoluteString))
            .accessibilityAddTraits(.isLink)
        } else {
            content
        }
    }

    /// 两个统计图共用的绘图高度，空态占位也按这个高度，避免切换范围时卡片跳高跳低。
    private static let chartPlotHeight: CGFloat = 196

    /// 首次加载只保留区块的稳定占位高度，加载反馈统一由标题栏的 SyncIconButton 承担。
    /// 禁止在内容中央放不确定进度环，否则刷新会清空内容并造成明显的页面跳动。
    private var sectionLoadingPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityHidden(true)
    }

    /// Star / Commit 空态：固定绘图高度 + 轻底，避免只剩一行文案或残留坐标轴标签。
    private func chartEmptyState(
        _ key: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(interfaceScale.font(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text(key)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: Self.chartPlotHeight)
        .padding(.horizontal, 16)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    /// 非图表区块的轻量空态：与 chartEmptyState 同一视觉语言，但不占满图表高度。
    private func compactEmptyState(
        _ key: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            Text(key)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    /// 区块内真正无内容时的空态；有缓存时不再叠「正在刷新/显示缓存」文案。
    private func healthDimensions(
        from health: RepositoryHealthInsight
    ) -> [RepositoryHealthDimensionItem] {
        [
            RepositoryHealthDimensionItem(
                id: "maintenance",
                titleKey: "insights.repo.health.maintenance",
                score: health.maintenanceScore,
                systemImage: "wrench.and.screwdriver.fill",
                tintName: "green"
            ),
            RepositoryHealthDimensionItem(
                id: "popularity",
                titleKey: "insights.repo.health.popularity",
                score: health.popularityScore,
                systemImage: "chart.line.uptrend.xyaxis",
                tintName: "blue"
            ),
            RepositoryHealthDimensionItem(
                id: "quality",
                titleKey: "insights.repo.health.quality",
                score: health.qualityScore,
                systemImage: "checkmark.seal.fill",
                tintName: "purple"
            ),
            RepositoryHealthDimensionItem(
                id: "security",
                titleKey: "insights.repo.health.security",
                score: health.securityScore,
                systemImage: "lock.shield.fill",
                tintName: "orange"
            )
        ]
    }

    private var timelineSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.timeline",
            subtitle: "insights.repo.section.timeline.subtitle",
            systemImage: "clock.arrow.circlepath"
        ) {
            // 时间线默认折叠；刷新交给整页 / 上游区块，避免再挂一颗 Sync。
            VStack(alignment: .leading, spacing: 8) {
                if timelineAllItems.isEmpty {
                    switch viewModel.recentActivityState {
                    case .idle, .loading:
                        sectionLoadingPlaceholder
                    case .unavailable:
                        compactEmptyState(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "clock.badge.exclamationmark"
                        )
                    case .generating:
                        compactEmptyState(
                            "insights.repo.state.generating",
                            systemImage: "clock.arrow.circlepath"
                        )
                    case .failed:
                        compactEmptyState(
                            "error.loadFailed",
                            systemImage: "exclamationmark.triangle"
                        )
                    case .content, .stale:
                        compactEmptyState(
                            "insights.repo.state.noData",
                            systemImage: "clock"
                        )
                    }
                } else {
                    let visibleItems = isTimelineExpanded
                        ? timelineAllItems
                        : Array(timelineAllItems.prefix(Self.collapsedTimelineLimit))
                    VStack(spacing: 0) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Divider().padding(.leading, 34)
                            }
                            timelineRow(item)
                        }
                    }

                    if timelineAllItems.count > Self.collapsedTimelineLimit {
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                                isTimelineExpanded.toggle()
                            }
                        } label: {
                            Text(
                                isTimelineExpanded
                                    ? "rag.workspace.citations.collapse"
                                    : "insights.drilldown.viewAll"
                            )
                            .font(interfaceScale.font(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                    }
                }
            }
        }
    }

    private var displayedRecentActivity: RepositoryRecentActivity? {
        switch viewModel.recentActivityState {
        case .content(let value), .stale(let value):
            return value
        case .loading(let cached),
             .generating(let cached),
             .unavailable(let cached),
             .failed(let cached):
            return cached
        case .idle:
            return nil
        }
    }

    /// 远端 PR / Issue 与本地 Release、commit activity 使用真实时间统一排序。
    private var timelineAllItems: [TimelineDisplayItem] {
        var items = displayedRecentActivity?.events.map { event in
            TimelineDisplayItem(
                id: event.id,
                title: event.title,
                detail: String(
                    format: String.l10n(
                        event.kind == .pullRequest
                            ? "insights.repo.timeline.pullRequestFormat"
                            : "insights.repo.timeline.issueFormat"
                    ),
                    locale: locale,
                    event.number
                ),
                occurredAt: event.occurredAt,
                systemImage: event.kind == .pullRequest
                    ? "arrow.triangle.pull"
                    : "record.circle",
                tintName: event.kind == .pullRequest ? "purple" : "orange",
                destinationURL: event.htmlURL
            )
        } ?? []

        if case .content(let release) = viewModel.releaseState,
           let publishedAt = release.publishedAt {
            items.append(
                TimelineDisplayItem(
                    id: "release-\(release.tagName)",
                    title: String(
                        format: String.l10n("insights.repo.timeline.releaseFormat"),
                        release.tagName
                    ),
                    detail: release.name ?? String.l10n("insights.repo.local.release"),
                    occurredAt: publishedAt,
                    systemImage: "tag.fill",
                    tintName: "blue",
                    destinationURL: release.htmlURL ?? releaseGitHubURL(tagName: release.tagName)
                )
            )
        }

        if let commitActivity = displayedCommitActivity,
           let latestPoint = commitActivity.points.last {
            let total = commitActivity.points(in: viewModel.commitActivityRange).reduce(0) {
                $0 + $1.commits
            }
            items.append(
                TimelineDisplayItem(
                    id: "commit-\(Int(latestPoint.weekStart.timeIntervalSince1970))",
                    title: String.l10n("insights.repo.timeline.commitActivity"),
                    detail: String(
                        format: String.l10n("insights.repo.commit.totalFormat"),
                        locale: locale,
                        total
                    ),
                    occurredAt: latestPoint.weekStart,
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                    tintName: "green",
                    destinationURL: nil
                )
            )
        }

        return items.sorted { $0.occurredAt > $1.occurredAt }
    }

    @ViewBuilder
    private func timelineRow(_ item: TimelineDisplayItem) -> some View {
        let isTappable = item.destinationURL != nil
        let isHovered = hoveredTimelineItemID == item.id
        let content = HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.systemImage)
                .foregroundStyle(InsightsColor.resolve(item.tintName))
                .frame(width: 20)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: item.title)
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    if isTappable {
                        // 可跳转明示：与 Release / Activity 外链一致，避免「点了没反应」的猜谜。
                        Image(systemName: "arrow.up.right.square")
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                Text(verbatim: item.detail)
                    .font(interfaceScale.font(.captionSmall))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            // 用静态日期时间，不用 .relative「几分几秒」计时器（会一直跳秒）。
            Text(verbatim: timelineOccurredLabel(item.occurredAt))
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredTimelineItemID = item.id
            } else if hoveredTimelineItemID == item.id {
                hoveredTimelineItemID = nil
            }
        }

        if let destinationURL = item.destinationURL {
            Button {
                NSWorkspace.shared.open(destinationURL)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(Text(verbatim: destinationURL.absoluteString))
            .accessibilityAddTraits(.isLink)
        } else {
            content
        }
    }

    /// 时间线右侧时间：月日 + 时分，跟随应用 Locale，避免相对计时器跳动。
    private func timelineOccurredLabel(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle()
                .month(.abbreviated)
                .day()
                .hour()
                .minute()
                .locale(locale)
        )
    }

    /// 本地 release 缺 `html_url` 时，用仓库页 + tag 兜底拼 GitHub release 链接。
    private func releaseGitHubURL(tagName: String) -> URL? {
        let base = repo.htmlUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedTag = tagName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tagName
        return URL(string: "\(base)/releases/tag/\(encodedTag)")
    }
}
