//
//  RepositoryInsightsView.swift
//  Starcat
//
//  仓库详情内的洞察页面。首阶段使用稳定 Mock 快照验证信息架构与图表密度；
//  View 只消费 RepositoryInsightsSnapshot，后续接入真实 Provider 时不改页面结构。
//

import Charts
import SwiftUI

struct RepositoryInsightsView: View {
    /// Star 趋势范围独立于活动统计范围；默认一年与设计文档口径一致。
    private enum StarRange: String, CaseIterable, Identifiable {
        case threeMonths
        case oneYear
        case all

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .threeMonths: return "insights.repo.star.range.threeMonths"
            case .oneYear:     return "insights.repo.star.range.oneYear"
            case .all:         return "insights.repo.star.range.all"
            }
        }
    }

    let repo: Repo
    let viewModel: RepositoryInsightsViewModel
    let onScrollReport: (RepoDetailScrollReport) -> Void

    private let snapshot: RepositoryInsightsSnapshot

    @State private var starRange: StarRange = .oneYear
    @State private var selectedStarDate: Date?
    @State private var isRefreshingStars = false

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(AuthSession.self) private var authSession

    init(
        repo: Repo,
        viewModel: RepositoryInsightsViewModel,
        onScrollReport: @escaping (RepoDetailScrollReport) -> Void
    ) {
        self.repo = repo
        self.viewModel = viewModel
        self.onScrollReport = onScrollReport
        snapshot = InsightsMockData.repositoryInsights(for: repo)
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
            return String(format: "%.1f / 10", openSSF.score)
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
                HStack(spacing: 8) {
                    Picker("insights.repo.activity.range.label", selection: activityRangeBinding) {
                        ForEach(RepositoryActivityRange.allCases) { range in
                            Text(LocalizedStringKey(range.titleKey)).tag(range)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)

                    Spacer(minLength: 8)

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
                Text(metric.value.formatted())
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

                ViewThatFits(in: .horizontal) {
                    starSources
                    VStack(alignment: .leading, spacing: 6) {
                        starSourceChip(
                            title: "insights.repo.star.source.estimated",
                            systemImage: "waveform.path.ecg",
                            dashed: true
                        )
                        starSourceChip(
                            title: "insights.repo.star.source.local",
                            systemImage: "internaldrive.fill",
                            dashed: false
                        )
                        MockDataBadge()
                    }
                }

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

                    ForEach(localStarPoints) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Stars", point.count),
                            series: .value("Source", "Local")
                        )
                        .foregroundStyle(Color.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .interpolationMethod(.catmullRom)
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
                .accessibilityLabel(Text("insights.repo.section.stars"))
                .accessibilityValue(
                    Text(
                        "\(snapshot.currentStars.formatted()) · \(signed(snapshot.starGrowthOneYear))"
                    )
                )

                HStack(spacing: 5) {
                    Text("insights.repo.star.coverage")
                    if let first = displayedStarPoints.first?.date {
                        Text(first, format: .dateTime.year().month().day())
                    }
                    Text("·")
                    Text("insights.repo.star.updated")
                    Text(snapshot.generatedAt, format: .dateTime.hour().minute())
                    Text("·")
                    Text("insights.repo.star.mockNotice")
                }
                .font(interfaceScale.font(.captionSmall))
                .foregroundStyle(.secondary)
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
    }

    private var starMetrics: some View {
        HStack(alignment: .top, spacing: 18) {
            starMetric(
                value: snapshot.currentStars.formatted(),
                label: "insights.repo.star.current"
            )
            starMetric(
                value: signed(snapshot.starGrowth30Days),
                label: "insights.repo.star.growth30Days"
            )
            starMetric(
                value: signed(snapshot.starGrowthOneYear),
                label: "insights.repo.star.growthOneYear"
            )
        }
    }

    private var starControls: some View {
        HStack(spacing: 8) {
            SyncIconButton(
                isRefreshing: isRefreshingStars,
                disabled: isRefreshingStars,
                tooltip: String.l10n("insights.repo.star.refresh")
            ) {
                refreshMockStarHistory()
            }

            Picker("insights.repo.star.range.label", selection: $starRange) {
                ForEach(StarRange.allCases) { range in
                    Text(range.titleKey).tag(range)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 176)
        }
    }

    private var starSources: some View {
        HStack(spacing: 8) {
            starSourceChip(
                title: "insights.repo.star.source.estimated",
                systemImage: "waveform.path.ecg",
                dashed: true
            )
            starSourceChip(
                title: "insights.repo.star.source.local",
                systemImage: "internaldrive.fill",
                dashed: false
            )
            MockDataBadge()
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
            Text(point.date, format: .dateTime.year().month().day())
            Text("·")
            Text(point.count.formatted())
                .monospacedDigit()
        }
        .font(interfaceScale.font(.captionSmall, weight: .medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
    }

    private var displayedStarPoints: [StarHistoryPoint] {
        let cutoff: Date?
        switch starRange {
        case .threeMonths:
            cutoff = snapshot.generatedAt.addingTimeInterval(-92 * 86_400)
        case .oneYear:
            cutoff = snapshot.generatedAt.addingTimeInterval(-366 * 86_400)
        case .all:
            cutoff = nil
        }
        guard let cutoff else { return snapshot.starHistory }
        return snapshot.starHistory.filter { $0.date >= cutoff }
    }

    /// Mock 将最后三个月视为本机精确观察点；折线在边界保留一个重叠点，
    /// 让两种来源视觉连续，同时用线型明确区分精度。
    private var estimatedStarPoints: [StarHistoryPoint] {
        guard displayedStarPoints.count > 3 else { return displayedStarPoints.prefix(1).map { $0 } }
        return Array(displayedStarPoints.dropLast(2))
    }

    private var localStarPoints: [StarHistoryPoint] {
        Array(displayedStarPoints.suffix(3))
    }

    private var selectedStarPoint: StarHistoryPoint? {
        guard let selectedStarDate else { return nil }
        return displayedStarPoints.min {
            abs($0.date.timeIntervalSince(selectedStarDate)) < abs($1.date.timeIntervalSince(selectedStarDate))
        }
    }

    private func signed(_ value: Int) -> String {
        value >= 0 ? "+\(value.formatted())" : value.formatted()
    }

    /// 前端验收期刷新只提供可见反馈，不改变确定性 Mock，也不触发网络请求。
    private func refreshMockStarHistory() {
        guard !isRefreshingStars else { return }
        isRefreshingStars = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            isRefreshingStars = false
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
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 142), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(snapshot.contributors) { contributor in
                    contributorItem(contributor)
                }
            }
        }
    }

    private func contributorItem(_ contributor: RepositoryContributor) -> some View {
        HStack(spacing: 8) {
            Text(String(contributor.login.prefix(1)).uppercased())
                .font(interfaceScale.font(.caption, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(InsightsColor.resolve(contributor.colorName), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: contributor.login)
                    .font(interfaceScale.font(.caption, weight: .medium))
                    .lineLimit(1)
                Text(
                    String(
                        format: String.l10n("insights.repo.contributor.commitsFormat"),
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
            switch viewModel.communityState {
            case .content(let community):
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
                }
            case .loading, .idle:
                sectionProgress
            case .empty, .unavailable:
                sectionMessage("insights.repo.state.noData", systemImage: "person.2.slash")
            case .failed:
                sectionMessage("error.loadFailed", systemImage: "exclamationmark.triangle")
            }
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
                    Text(verbatim: String(format: "%.1f / 10", openSSF.score))
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
            VStack(spacing: 0) {
                ForEach(Array(snapshot.timelineItems.enumerated()), id: \.element.id) { index, item in
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
                            Text(verbatim: item.detail)
                                .font(interfaceScale.font(.captionSmall))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Text(LocalizedStringKey(item.relativeTimeKey))
                            .font(interfaceScale.font(.captionSmall))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}
