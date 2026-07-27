//
//  RepositoryInsightsView.swift
//  Starcat
//
//  仓库详情内的洞察页面。
//
//  Star 趋势使用独立 ViewModel 与范围，避免活动指标的 range、刷新和失败状态污染
//  长期历史；其余区块继续消费各自的本地或远端状态机。
//

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
    }

    let repo: Repo
    let viewModel: RepositoryInsightsViewModel
    let starHistoryViewModel: StarHistoryViewModel
    let onScrollReport: (RepoDetailScrollReport) -> Void

    @State private var selectedStarDate: Date?

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(AuthSession.self) private var authSession

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
        ScrollView {
            LazyVStack(spacing: 14) {
                localOverviewSection
                activitySection
                starHistorySection
                commitSection
                contributorSection
                healthSection
                localSignalsSection
                timelineSection
            }
            .padding(18)
        }
        .detailScrollViewStyle()
        .onScrollGeometryChange(for: RepoDetailScrollReport.self) { geometry in
            RepoDetailScrollReport(
                offsetY: max(0, geometry.contentOffset.y),
                scrollOverflow: max(0, geometry.contentSize.height - geometry.containerSize.height)
            )
        } action: { _, report in
            onScrollReport(report)
        }
        .accessibilityLabel(Text("insights.repo.mode.insights"))
    }

    private var localOverviewSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.local",
            subtitle: "insights.repo.section.local.subtitle",
            systemImage: "internaldrive.fill"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 10)],
                spacing: 10
            ) {
                localFact(
                    title: "insights.repo.local.release",
                    systemImage: "tag.fill",
                    value: releaseValue
                )
                localFact(
                    title: "insights.repo.local.license",
                    systemImage: "checkmark.seal.fill",
                    value: repo.license ?? String.l10n("insights.repo.state.noData")
                )
                localFact(
                    title: "insights.repo.local.health",
                    systemImage: "heart.text.square.fill",
                    value: healthValue
                )
                localFact(
                    title: "insights.repo.local.openssf",
                    systemImage: "shield.checkered",
                    value: openSSFValue
                )
            }
        }
    }

    private func localFact(
        title: LocalizedStringKey,
        systemImage: String,
        value: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(interfaceScale.font(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let value {
                Text(verbatim: value)
                    .font(interfaceScale.font(.bodyEmphasis))
                    .lineLimit(1)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.55),
            in: RoundedRectangle(cornerRadius: 7)
        )
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
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        activityRangePicker
                        Spacer(minLength: 8)
                        activityRefreshButton
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        activityRangePicker
                        activityRefreshButton
                    }
                }

                if let counts = displayedActivityCounts {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 128), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(activityMetrics(from: counts)) { metric in
                            activityMetric(metric)
                        }
                    }
                    if let message = activityStatusMessage {
                        Label(message.key, systemImage: message.systemImage)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    switch viewModel.activityState {
                    case .idle, .loading:
                        sectionProgress
                    case .generating:
                        sectionMessage(
                            "insights.repo.state.generating",
                            systemImage: "clock.arrow.circlepath"
                        )
                    case .unavailable:
                        sectionMessage(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                    case .failed:
                        sectionMessage(
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

    private var activityRangePicker: some View {
        Picker("insights.repo.activity.range.label", selection: activityRangeBinding) {
            ForEach(RepositoryActivityRange.allCases) { range in
                Text(LocalizedStringKey(range.titleKey)).tag(range)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 280)
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

    private var activityStatusMessage: (key: LocalizedStringKey, systemImage: String)? {
        switch viewModel.activityState {
        case .stale:
            return ("insights.repo.state.stale", "clock.badge.exclamationmark")
        case .generating:
            return ("insights.repo.state.generating", "clock.arrow.circlepath")
        case .unavailable:
            return (
                authSession.state.isAuthenticated
                    ? "insights.repo.state.noData"
                    : "insights.repo.state.loginRequired",
                "person.crop.circle.badge.exclamationmark"
            )
        case .failed:
            return ("insights.repo.state.refreshFailed", "exclamationmark.triangle")
        case .idle, .loading, .content:
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
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: metric.systemImage)
                    .foregroundStyle(tint)
                Text(LocalizedStringKey(metric.titleKey))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            .font(interfaceScale.font(.caption))

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.value.formatted(.number.locale(locale)))
                    .font(interfaceScale.font(size: 22, weight: .semibold))
                    .monospacedDigit()
                if let delta = metric.delta {
                    Text(verbatim: delta >= 0 ? "+\(delta)%" : "\(delta)%")
                        .font(interfaceScale.font(.captionSmall, weight: .medium))
                        .foregroundStyle(delta >= 0 ? .green : .red)
                        .monospacedDigit()
                }
            }

            Text(LocalizedStringKey(viewModel.activityRange.titleKey))
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
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
            systemImage: "star.fill"
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

                starPhaseMessage

                if !displayedStarPoints.isEmpty {
                    starSources

                    starChart
                    starReadingRow

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
            }
        }
    }

    private func starMetric(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value)
                .font(interfaceScale.font(size: 20, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value))
    }

    private var starMetrics: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)],
            alignment: .leading,
            spacing: 10
        ) {
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
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                starRefreshButton
                starRangePicker
            }
            VStack(alignment: .leading, spacing: 8) {
                starRangePicker
                starRefreshButton
            }
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

    private var starRangePicker: some View {
        Picker("insights.repo.star.range.label", selection: starRangeBinding) {
            ForEach(StarHistoryRange.allCases) { range in
                Text(starRangeTitle(range)).tag(range)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(maxWidth: 176)
    }

    private var starSources: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
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

    @ViewBuilder
    private var starPhaseMessage: some View {
        switch starHistoryViewModel.phase {
        case .idle where displayedStarPoints.isEmpty:
            sectionProgress
        case .loading where displayedStarPoints.isEmpty:
            sectionProgress
        case .building:
            starStatusMessage(
                "insights.repo.star.state.building",
                systemImage: "clock.arrow.circlepath"
            )
        case .stale:
            starStatusMessage(
                "insights.repo.star.state.stale",
                systemImage: "wifi.exclamationmark"
            )
        case .privateOnly:
            starStatusMessage(
                "insights.repo.star.state.private",
                systemImage: "lock.fill"
            )
        case .unavailable where displayedStarPoints.isEmpty:
            sectionMessage("insights.repo.star.state.unavailable", systemImage: "star.slash")
        case .failed where displayedStarPoints.isEmpty:
            sectionMessage("error.loadFailed", systemImage: "exclamationmark.triangle")
        default:
            EmptyView()
        }
    }

    private func starStatusMessage(
        _ key: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        Label(key, systemImage: systemImage)
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.55),
                in: RoundedRectangle(cornerRadius: 7)
            )
    }

    private var starChart: some View {
        Chart {
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

            if let selectedStarPoint {
                RuleMark(x: .value("Selected", selectedStarPoint.date))
                    .foregroundStyle(Color.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        starSelectionAnnotation(selectedStarPoint)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel(format: .dateTime.year().month(.abbreviated))
                    .font(interfaceScale.font(.captionSmall))
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
        .chartXSelection(value: $selectedStarDate)
        .frame(minHeight: 200, idealHeight: 230, maxHeight: 250)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("insights.repo.section.stars"))
        .accessibilityValue(Text(starChartAccessibilityValue))
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

    @ViewBuilder
    private var starReadingRow: some View {
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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "scope")
                    .foregroundStyle(.secondary)
                Text("insights.repo.star.reading.label")
                    .font(interfaceScale.font(.caption, weight: .medium))
                Text(verbatim: value)
                    .font(interfaceScale.font(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("insights.repo.star.reading.label"))
            .accessibilityValue(Text(verbatim: value))
        }
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
                HStack(spacing: 8) {
                    Text(LocalizedStringKey(viewModel.activityRange.titleKey))
                        .font(interfaceScale.font(.caption, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

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

                if let activity = displayedCommitActivity {
                    let points = activity.points(in: viewModel.activityRange)
                    if points.isEmpty {
                        sectionMessage("insights.repo.state.noData", systemImage: "chart.bar.xaxis")
                    } else {
                        Chart(points) { point in
                            BarMark(
                                x: .value("Week", point.weekStart),
                                y: .value("Commits", point.commits)
                            )
                            .foregroundStyle(Color.green)
                            .cornerRadius(2)
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                    .font(interfaceScale.font(.captionSmall))
                                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.08))
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading) {
                                AxisValueLabel()
                                    .font(interfaceScale.font(.captionSmall))
                                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                            }
                        }
                        .frame(height: 176)
                        .accessibilityLabel(Text("insights.repo.section.commits"))
                        .accessibilityValue(
                            Text(
                                String(
                                    format: String.l10n("insights.repo.commit.totalFormat"),
                                    locale: locale,
                                    points.reduce(0) { $0 + $1.commits }
                                )
                            )
                        )
                    }

                    if let message = commitStatusMessage {
                        Label(message.key, systemImage: message.systemImage)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    switch viewModel.commitActivityState {
                    case .idle, .loading:
                        sectionProgress
                    case .generating:
                        sectionMessage(
                            "insights.repo.state.generating",
                            systemImage: "clock.arrow.circlepath"
                        )
                    case .unavailable:
                        sectionMessage(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                    case .failed:
                        sectionMessage("error.loadFailed", systemImage: "exclamationmark.triangle")
                    case .content, .stale:
                        EmptyView()
                    }
                }
            }
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

    private var commitStatusMessage: (key: LocalizedStringKey, systemImage: String)? {
        switch viewModel.commitActivityState {
        case .stale:
            return ("insights.repo.state.stale", "clock.badge.exclamationmark")
        case .generating:
            return ("insights.repo.state.generating", "clock.arrow.circlepath")
        case .unavailable:
            return (
                authSession.state.isAuthenticated
                    ? "insights.repo.state.noData"
                    : "insights.repo.state.loginRequired",
                "person.crop.circle.badge.exclamationmark"
            )
        case .failed:
            return ("insights.repo.state.refreshFailed", "exclamationmark.triangle")
        case .idle, .loading, .content:
            return nil
        }
    }

    private var contributorSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.contributors",
            subtitle: "insights.repo.section.contributors.subtitle",
            systemImage: "person.3.fill"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    SyncIconButton(
                        isRefreshing: viewModel.isRefreshingContributors,
                        disabled: viewModel.isRefreshingContributors,
                        tooltip: String.l10n("insights.repo.contributor.refresh")
                    ) {
                        Task {
                            await viewModel.refreshContributors(
                                repo: repo,
                                isAuthenticated: authSession.state.isAuthenticated
                            )
                        }
                    }
                }

                if let insight = displayedContributors {
                    if insight.contributors.isEmpty {
                        sectionMessage("insights.repo.state.noData", systemImage: "person.3.sequence")
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 142), spacing: 12)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(insight.contributors) { contributor in
                                contributorItem(contributor)
                            }
                        }
                    }
                    if let message = contributorsStatusMessage {
                        Label(message.key, systemImage: message.systemImage)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    switch viewModel.contributorsState {
                    case .idle, .loading:
                        sectionProgress
                    case .unavailable:
                        sectionMessage(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                    case .generating:
                        sectionMessage(
                            "insights.repo.state.generating",
                            systemImage: "clock.arrow.circlepath"
                        )
                    case .failed:
                        sectionMessage("error.loadFailed", systemImage: "exclamationmark.triangle")
                    case .content, .stale:
                        EmptyView()
                    }
                }
            }
        }
    }

    private func contributorItem(_ contributor: RepositoryContributor) -> some View {
        HStack(spacing: 8) {
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
                Text(verbatim: contributor.login)
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .lineLimit(1)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var contributorsStatusMessage: (key: LocalizedStringKey, systemImage: String)? {
        switch viewModel.contributorsState {
        case .stale:
            return ("insights.repo.state.stale", "clock.badge.exclamationmark")
        case .unavailable:
            return (
                authSession.state.isAuthenticated
                    ? "insights.repo.state.noData"
                    : "insights.repo.state.loginRequired",
                "person.crop.circle.badge.exclamationmark"
            )
        case .failed:
            return ("insights.repo.state.refreshFailed", "exclamationmark.triangle")
        case .generating:
            return ("insights.repo.state.generating", "clock.arrow.circlepath")
        case .idle, .loading, .content:
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
                        columns: [GridItem(.adaptive(minimum: 142), spacing: 18)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(healthDimensions(from: health)) { dimension in
                            healthItem(dimension)
                        }
                    }
                case .loading, .idle:
                    sectionProgress
                case .empty, .unavailable:
                    sectionMessage("insights.repo.state.noData", systemImage: "heart.slash")
                case .failed:
                    sectionMessage("error.loadFailed", systemImage: "exclamationmark.triangle")
                }
            }
        }
    }

    private func healthItem(_ dimension: RepositoryHealthDimensionItem) -> some View {
        let tint = InsightsColor.resolve(dimension.tintName)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label {
                    Text(LocalizedStringKey(dimension.titleKey))
                } icon: {
                    Image(systemName: dimension.systemImage)
                        .foregroundStyle(tint)
                }
                .font(interfaceScale.font(.caption, weight: .medium))
                Spacer(minLength: 6)
                Text(verbatim: "\(dimension.score)")
                    .font(interfaceScale.font(.caption, weight: .semibold))
                    .monospacedDigit()
            }

            ProgressView(value: Double(dimension.score), total: 100)
                .tint(tint)
        }
        .frame(maxWidth: .infinity)
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
                HStack {
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
                    }
                    Spacer()
                    SyncIconButton(
                        isRefreshing: viewModel.isRefreshingCommunity,
                        disabled: viewModel.isRefreshingCommunity,
                        tooltip: String.l10n("insights.repo.community.refresh")
                    ) {
                        Task {
                            await viewModel.refreshCommunityProfile(
                                repo: repo,
                                isAuthenticated: authSession.state.isAuthenticated
                            )
                        }
                    }
                }

                if let community = displayedCommunity {
                    VStack(spacing: 0) {
                        localSignalRow(
                            title: "insights.repo.signal.readme",
                            isAvailable: community.hasReadme,
                            systemImage: "doc.text.fill"
                        )
                        Divider().padding(.leading, 28)
                        localSignalRow(
                            title: "insights.repo.signal.conduct",
                            isAvailable: community.hasCodeOfConduct,
                            systemImage: "person.2.fill"
                        )
                        Divider().padding(.leading, 28)
                        localSignalRow(
                            title: "insights.repo.signal.contributing",
                            isAvailable: community.hasContributing,
                            systemImage: "hand.raised.fill"
                        )
                        Divider().padding(.leading, 28)
                        localSignalRow(
                            title: "insights.repo.signal.license",
                            isAvailable: community.hasLicense,
                            systemImage: "checkmark.seal.fill"
                        )
                    }
                    if let message = communityStatusMessage {
                        Label(message.key, systemImage: message.systemImage)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    switch viewModel.remoteCommunityState {
                    case .idle, .loading:
                        sectionProgress
                    case .unavailable:
                        sectionMessage(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "person.2.slash"
                        )
                    case .generating:
                        sectionMessage(
                            "insights.repo.state.generating",
                            systemImage: "clock.arrow.circlepath"
                        )
                    case .failed:
                        sectionMessage("error.loadFailed", systemImage: "exclamationmark.triangle")
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

    private var communityStatusMessage: (key: LocalizedStringKey, systemImage: String)? {
        switch viewModel.remoteCommunityState {
        case .stale:
            return ("insights.repo.state.stale", "clock.badge.exclamationmark")
        case .unavailable:
            return (
                authSession.state.isAuthenticated
                    ? "insights.repo.state.noData"
                    : "insights.repo.state.loginRequired",
                "person.crop.circle.badge.exclamationmark"
            )
        case .failed:
            return ("insights.repo.state.refreshFailed", "exclamationmark.triangle")
        case .generating:
            return ("insights.repo.state.generating", "clock.arrow.circlepath")
        case .idle, .loading, .content:
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
                HStack(spacing: 8) {
                    Image(systemName: "shield.checkered")
                        .frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text("insights.repo.signal.openssf")
                        .font(interfaceScale.font(.caption))
                    Spacer(minLength: 8)
                    Text(verbatim: String(format: "%.1f / 10", locale: locale, openSSF.score))
                        .font(interfaceScale.font(.captionSmall, weight: .medium))
                        .foregroundStyle(openSSF.score >= 5 ? .green : .orange)
                        .monospacedDigit()
                }
                .padding(.vertical, 7)
            case .loading, .idle:
                sectionProgress
            case .empty, .unavailable:
                sectionMessage("insights.repo.state.noData", systemImage: "shield.slash")
            case .failed:
                sectionMessage("error.loadFailed", systemImage: "exclamationmark.triangle")
            }
        }
    }

    private func localSignalRow(
        title: LocalizedStringKey,
        isAvailable: Bool,
        systemImage: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .font(interfaceScale.font(.caption))
            Spacer(minLength: 8)
            Text(LocalizedStringKey(
                isAvailable ? "insights.repo.signal.available" : "insights.repo.signal.missing"
            ))
                .font(interfaceScale.font(.captionSmall, weight: .medium))
                .foregroundStyle(isAvailable ? .green : .orange)
        }
        .padding(.vertical, 7)
    }

    private var sectionProgress: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    private func sectionMessage(_ key: LocalizedStringKey, systemImage: String) -> some View {
        Label(key, systemImage: systemImage)
            .font(interfaceScale.font(.caption))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
    }

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
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    SyncIconButton(
                        isRefreshing: viewModel.isRefreshingRecentActivity,
                        disabled: viewModel.isRefreshingRecentActivity,
                        tooltip: String.l10n("insights.repo.timeline.refresh")
                    ) {
                        Task {
                            await viewModel.refreshRecentActivity(
                                repo: repo,
                                isAuthenticated: authSession.state.isAuthenticated
                            )
                        }
                    }
                }

                if timelineDisplayItems.isEmpty {
                    switch viewModel.recentActivityState {
                    case .idle, .loading:
                        sectionProgress
                    case .unavailable:
                        sectionMessage(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "clock.badge.exclamationmark"
                        )
                    case .generating:
                        sectionMessage(
                            "insights.repo.state.generating",
                            systemImage: "clock.arrow.circlepath"
                        )
                    case .failed:
                        sectionMessage("error.loadFailed", systemImage: "exclamationmark.triangle")
                    case .content, .stale:
                        sectionMessage("insights.repo.state.noData", systemImage: "clock")
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(timelineDisplayItems.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Divider().padding(.leading, 34)
                            }
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.systemImage)
                                    .foregroundStyle(InsightsColor.resolve(item.tintName))
                                    .frame(width: 20)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.title)
                                        .font(interfaceScale.font(.caption, weight: .medium))
                                        .lineLimit(2)
                                    Text(verbatim: item.detail)
                                        .font(interfaceScale.font(.captionSmall))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 12)

                                Text(item.occurredAt, style: .relative)
                                    .font(interfaceScale.font(.captionSmall))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    if let message = timelineStatusMessage {
                        Label(message.key, systemImage: message.systemImage)
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
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
    private var timelineDisplayItems: [TimelineDisplayItem] {
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
                tintName: event.kind == .pullRequest ? "purple" : "orange"
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
                    tintName: "blue"
                )
            )
        }

        if let commitActivity = displayedCommitActivity,
           let latestPoint = commitActivity.points.last {
            let total = commitActivity.points(in: viewModel.activityRange).reduce(0) {
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
                    tintName: "green"
                )
            )
        }

        return Array(items.sorted { $0.occurredAt > $1.occurredAt }.prefix(8))
    }

    private var timelineStatusMessage: (key: LocalizedStringKey, systemImage: String)? {
        switch viewModel.recentActivityState {
        case .stale:
            return ("insights.repo.state.stale", "clock.badge.exclamationmark")
        case .unavailable:
            return (
                authSession.state.isAuthenticated
                    ? "insights.repo.state.noData"
                    : "insights.repo.state.loginRequired",
                "person.crop.circle.badge.exclamationmark"
            )
        case .failed:
            return ("insights.repo.state.refreshFailed", "exclamationmark.triangle")
        case .generating:
            return ("insights.repo.state.generating", "clock.arrow.circlepath")
        case .idle, .loading, .content:
            return nil
        }
    }
}
