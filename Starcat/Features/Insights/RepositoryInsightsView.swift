//
//  RepositoryInsightsView.swift
//  Starcat
//
//  仓库详情内的洞察页面。
//
//  Star 趋势使用独立 ViewModel 与范围，避免活动指标的 range、刷新和失败状态污染
//  长期历史；其余区块继续消费各自的本地或远端状态机。
//
//  层级约定（对齐我的洞察）：window 灰底 → KPI / 事实块浅色 tint → emphasized section
//  面板 + 彩色标题图标；概览带与深潜带用组间间距区分，不引入嵌套大卡片。
//

import AppKit
import Charts
import SwiftUI

/// 不同精度折线之间的显式连接段。
///
/// Swift Charts 会把不同 `series` 当成互不相连的折线；当后一组只有一个 snapshot
/// 点时，它只能画出圆点。桥接段保留前一组的视觉语义，让曲线连续但不伪造数据来源。
struct StarHistoryChartBridge: Equatable, Identifiable, Sendable {
    let start: StarHistoryPoint
    let end: StarHistoryPoint
    let inheritedPrecision: StarHistoryPrecision

    var id: String {
        "\(start.id)->\(end.id)"
    }
}

enum StarHistoryChartSeriesBuilder {
    /// 输入点必须按日期升序；只在精度切换处生成相邻两点桥接。
    static func bridges(in points: [StarHistoryPoint]) -> [StarHistoryChartBridge] {
        guard points.count >= 2 else { return [] }
        return zip(points, points.dropFirst()).compactMap { start, end in
            guard start.precision != end.precision else { return nil }
            return StarHistoryChartBridge(
                start: start,
                end: end,
                inheritedPrecision: start.precision
            )
        }
    }
}

enum StarHistoryRestrictionNoticePolicy {
    /// 已拿到 GitHub Stargazers 数据时不再提示访问限制；加载与失败状态也不抢占主反馈。
    static func shouldShow(
        points: [StarHistoryPoint],
        phase: StarHistoryViewPhase
    ) -> Bool {
        guard !points.contains(where: { $0.source == .githubStargazers }) else {
            return false
        }
        switch phase {
        case .content, .stale, .privateOnly, .unavailable:
            return true
        case .idle, .loading, .building, .failed:
            return false
        }
    }
}

enum StarHistoryDisplayPolicy {
    /// Starcat 本机快照是所有仓库的共同基线，因此即使暂时没有数据也要常驻在首位。
    /// 其余图例只按当前实际出现的精度追加，避免暗示尚未获取到的远端历史。
    static func legendPrecisions(points: [StarHistoryPoint]) -> [StarHistoryPrecision] {
        var precisions: [StarHistoryPrecision] = [.snapshot]
        if points.contains(where: { $0.precision == .reconstructed }) {
            precisions.append(.reconstructed)
        }
        if points.contains(where: { $0.precision == .estimated }) {
            precisions.append(.estimated)
        }
        return precisions
    }

    /// 图表选中日期后返回最近点，供图内 RuleMark 和浮层使用。
    static func selectedPoint(
        in points: [StarHistoryPoint],
        selectedDate: Date?
    ) -> StarHistoryPoint? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate))
                < abs($1.date.timeIntervalSince(selectedDate))
        }
    }
}

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
    /// 贡献者默认截断；更多走底部「查看全部」，不在网格里再塞 +N。
    @State private var isContributorsExpanded = false
    /// ScrollView 内容固有高度。Hero 折叠后视口变高时，用它锁死 contentSize，
    /// 避免 VStack 吃满纵向 proposal 在末卡后留下可滚留白。
    @State private var insightsContentHeight: CGFloat = 0

    @Environment(\.locale) private var locale
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(AuthSession.self) private var authSession

    /// 折叠态只展示前 4 人；样本人数已在集中度行给出总量。
    private static let visibleContributorLimit = 4
    private static let collapsedTimelineLimit = 5
    /// 与 RepoDetailScrollReport 同口径，忽略亚像素测高抖动。
    private static let contentHeightTolerance: CGFloat = 0.5
    /// GitHub 公告解释了 Stargazers 列表的权限收紧，比通用 API 参数页更直接。
    private static let githubStargazersRestrictionURL = URL(
        string: "https://github.blog/changelog/2026-06-30-upcoming-access-restrictions-to-public-api-endpoints-and-ui-views/"
    )!

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
                // 改为 VStack，并用「概览 / 趋势 / 健康信号」三段节奏降低同权卡片疲劳。
                // 组间只靠 spacing，不再插 Divider——emphasized 卡片本身已有边界。
                VStack(alignment: .leading, spacing: 24) {
                    // 上半：一眼能扫完的本地事实 + 活动 KPI
                    VStack(alignment: .leading, spacing: 12) {
                        localOverviewSection
                        activitySection
                    }

                    // 中段：需要盯图的趋势深潜
                    VStack(alignment: .leading, spacing: 12) {
                        starHistorySection
                        commitSection
                        contributorSection
                    }

                    // 下半：节奏 / 健康 / 社区安全 / 时间线
                    VStack(alignment: .leading, spacing: 12) {
                        releaseCadenceSection
                        healthSection
                        localSignalsSection
                        timelineSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                // 外层 Scaffold 在 Hero 折叠后会扩大正文视口；内容栈必须坚持使用卡片的
                // 固有高度，否则 VStack 会接受扩大的纵向 proposal，在最后一张卡片后留下
                // 一段可滚动但不可见的空白。fixedSize 测固有高，再 frame 锁死，
                // 比单靠 fixedSize 更能扛住折叠瞬间的 proposal 拉伸。
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: InsightsContentHeightKey.self,
                            value: proxy.size.height
                        )
                    }
                }
                .onPreferenceChange(InsightsContentHeightKey.self) { height in
                    guard height > 0,
                          abs(height - insightsContentHeight) > Self.contentHeightTolerance
                    else { return }
                    insightsContentHeight = height
                }
                .frame(
                    height: insightsContentHeight > 0 ? insightsContentHeight : nil,
                    alignment: .top
                )
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
        // 与 Release 详情一致：body 吃满 Scaffold 剩余空间，滚动发生在内容区自身。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: repo.id) { _, _ in
            // 切仓库时清掉旧高度，避免短暂锁在上一仓的 contentSize。
            insightsContentHeight = 0
        }
        .accessibilityLabel(Text("insights.repo.mode.insights"))
    }

    /// README 底栏同款 `.bar`；右侧全局刷新，分区 Sync 全部保留。
    ///
    /// 刷新归属：
    /// - 点全局 → `isRefreshingAll`，各面板 Sync 通过 `|| isRefreshingAll` 一起转；
    /// - 点某面板 → 只拉高该面板旗标，**不**带动全局（全局只看 `isRefreshingAll`）。
    private var insightsGlobalFooter: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            SyncIconButton(
                isRefreshing: viewModel.isRefreshingAll,
                disabled: viewModel.isRefreshingAll,
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

    private func refreshAllInsights() async {
        let authenticated = authSession.state.isAuthenticated
        // Star 与其它区块共用「全局」冷却；未真正开刷时只靠 isRefreshingAll 脉冲带动各面板确认转圈。
        let started = await viewModel.refreshAll(
            repo: repo,
            isAuthenticated: authenticated
        )
        guard started else { return }
        // 远端区块已返回后仍保持 isRefreshingAll，直到 Star 也结束，避免全局图标先停、Star 还在转。
        defer { viewModel.finishGlobalRefresh() }
        await starHistoryViewModel.refresh(repo: repo)
    }

    private var localOverviewSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.local",
            subtitle: "insights.repo.section.local.subtitle",
            systemImage: "internaldrive.fill",
            iconColor: .cyan,
            chrome: .emphasized
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
        // 与我的洞察 KPI 同款：极浅语义 tint，避免中性灰块在 emphasized 面板里糊成一片。
        .background(
            tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
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
            systemImage: "waveform.path.ecg",
            iconColor: .orange,
            chrome: .emphasized
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // 派生三指标与时间切换同一行：左指标、右控件，避免底部再占一行。
                HStack(alignment: .center, spacing: 8) {
                    if let counts = displayedActivityCounts {
                        activityDerivedMetricsRow(counts)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if isActivityAwaitingFirstContent {
                        InsightsSectionSkeleton(kind: .derivedPills())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
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
            activityRangePicker
            activityRefreshButton
        }
    }

    @ViewBuilder
    private var activityBody: some View {
        if let counts = displayedActivityCounts {
            // 有缓存就只展示四卡；刷新态由 SyncIconButton 表达，派生指标已上移到控件行。
            HStack(alignment: .top, spacing: 10) {
                ForEach(activityMetrics(from: counts)) { metric in
                    activityMetric(metric)
                }
            }
        } else {
            switch viewModel.activityState {
            case .idle, .loading:
                InsightsSectionSkeleton(kind: .metricTiles())
            case .generating:
                // GitHub 仍在准备：保持骨架轮廓，弱文案不抢戏。
                InsightsSectionSkeleton(
                    kind: .metricTiles(),
                    statusCaptionKey: "insights.repo.state.generating"
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

    /// 活动区尚无缓存内容，且仍在首次拉取 / GitHub 准备中。
    private var isActivityAwaitingFirstContent: Bool {
        switch viewModel.activityState {
        case .idle, .loading, .generating:
            return true
        case .content, .stale, .unavailable, .failed:
            return false
        }
    }

    private func activityDerivedMetricsRow(_ counts: RepositoryActivityCounts) -> some View {
        HStack(spacing: 8) {
            activityDerivedMetric(
                title: "insights.repo.activity.prThroughput",
                value: activityRatio(counts.pullRequestThroughput),
                systemImage: "arrow.triangle.merge",
                tintName: "green"
            )
            activityDerivedMetric(
                title: "insights.repo.activity.issueThroughput",
                value: activityRatio(counts.issueThroughput),
                systemImage: "checkmark.circle",
                tintName: "blue"
            )
            activityDerivedMetric(
                title: "insights.repo.activity.netIssueChange",
                value: signedActivityChange(counts.netIssueChange),
                systemImage: "arrow.up.arrow.down",
                tintName: counts.netIssueChange > 0 ? "orange" : "green"
            )
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
            isRefreshing: viewModel.isRefreshingActivity || viewModel.isRefreshingAll,
            disabled: viewModel.isRefreshingActivity || viewModel.isRefreshingAll,
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
            tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(metric.titleKey)))
        .accessibilityValue(Text(verbatim: activityMetricAccessibilityValue(metric)))
    }

    private func activityDerivedMetric(
        title: LocalizedStringKey,
        value: String,
        systemImage: String,
        tintName: String
    ) -> some View {
        let tint = InsightsColor.resolve(tintName)
        return HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)

            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 6)

            Text(verbatim: value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(interfaceScale.font(.caption))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: value))
    }

    private func activityRatio(_ ratio: Double?) -> String {
        guard let ratio else {
            return String.l10n("insights.repo.state.noData")
        }
        return ratio.formatted(
            .percent.precision(.fractionLength(ratio < 1 ? 0 : 1)).locale(locale)
        )
    }

    private func signedActivityChange(_ value: Int) -> String {
        let formatted = abs(value).formatted(.number.locale(locale))
        if value > 0 { return "+\(formatted)" }
        if value < 0 { return "−\(formatted)" }
        return "0"
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
            iconColor: .yellow,
            chrome: .emphasized,
            headerTrailing: { starDataSourceBadge }
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        if isStarHistoryWaitingForFirstPaint {
                            InsightsSectionSkeleton(kind: .metricTiles(count: 3, minHeight: 58))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            starMetrics
                        }
                        Spacer(minLength: 8)
                        starControls
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if isStarHistoryWaitingForFirstPaint {
                            InsightsSectionSkeleton(kind: .metricTiles(count: 3, minHeight: 58))
                        } else {
                            starMetrics
                        }
                        starControls
                    }
                }

                if isStarHistoryWaitingForFirstPaint {
                    VStack(alignment: .leading, spacing: 10) {
                        InsightsSectionSkeleton(kind: .derivedPills(count: 2))
                        InsightsSectionSkeleton(
                            kind: .chart(height: Self.chartPlotHeight),
                            statusCaptionKey: isStarHistoryBuilding
                                ? "insights.repo.state.generating"
                                : nil
                        )
                    }
                } else if !displayedStarPoints.isEmpty {
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
                } else {
                    chartEmptyState(
                        "insights.repo.star.state.unavailable",
                        systemImage: "star.slash"
                    )
                }

                if displayedStarPoints.isEmpty,
                   StarHistoryRestrictionNoticePolicy.shouldShow(
                    points: displayedStarPoints,
                    phase: starHistoryViewModel.phase
                   ) {
                    starHistoryRestrictionLink
                        .padding(.horizontal, 2)
                }
            }
        }
    }

    /// 首次拉取尚未落点时，用骨架占位；不再留空白或叠空态。
    private var isStarHistoryWaitingForFirstPaint: Bool {
        switch starHistoryViewModel.phase {
        case .idle, .loading, .building:
            return displayedStarPoints.isEmpty
        default:
            return false
        }
    }

    /// GitHub Star History 仍在异步构建（202 / building）。
    private var isStarHistoryBuilding: Bool {
        if case .building = starHistoryViewModel.phase {
            return displayedStarPoints.isEmpty
        }
        return false
    }

    /// 日期范围已经包含最后观测日期，更新时间只保留时分，避免同一天日期重复两次。
    private var starCoverageSummary: some View {
        HStack(spacing: 5) {
            Text(verbatim: starCoverageRangeText)
            Text("·")
            Text("insights.repo.star.updated")
            if let updatedAt = starHistoryViewModel.updatedAt {
                Text(updatedAt, format: .dateTime.hour().minute())
            } else {
                Text("insights.repo.state.noData")
            }
        }
    }

    private var starCoverageRangeText: String {
        guard let coverageStart = starHistoryViewModel.coverageStart else {
            return String.l10n("insights.repo.state.noData")
        }
        let coverageEnd = max(coverageStart, displayedStarPoints.last?.date ?? coverageStart)
        return Date.IntervalFormatStyle(
            date: .abbreviated,
            time: .omitted,
            locale: locale
        ).format(coverageStart..<coverageEnd)
    }

    /// 第一行固定图例靠左、覆盖信息靠右；限制链接保留第二行并独立右对齐。
    /// 每一行内容都不换行，悬停也只更新图内浮层。
    private var starFooter: some View {
        let showsRestriction = StarHistoryRestrictionNoticePolicy.shouldShow(
            points: displayedStarPoints,
            phase: starHistoryViewModel.phase
        )
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                starSources
                Spacer(minLength: 12)
                starCoverageSummary
                    .lineLimit(1)
            }
            if showsRestriction {
                starHistoryRestrictionLink
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(interfaceScale.font(.captionSmall))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    /// 页面只显示问题式短链接；完整限制说明保留在 help 与 VoiceOver hint。
    private var starHistoryRestrictionLink: some View {
        Link(destination: Self.githubStargazersRestrictionURL) {
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .accessibilityHidden(true)
                Text("insights.repo.star.restriction.learnMore")
                    .underline()
            }
        }
        .lineLimit(1)
        .help(Text("insights.repo.star.restriction.message"))
        .accessibilityHint(Text("insights.repo.star.restriction.message"))
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
            Color.yellow.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.yellow.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value))
    }

    private func starVelocityMetric(
        value: String,
        label: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.blue)
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Text(verbatim: value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(interfaceScale.font(.caption))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            Color.blue.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.blue.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value))
    }

    private var starMetrics: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 三个总量指标固定一行：自适应网格会把「1 年增长」挤到下一行。
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

            HStack(spacing: 8) {
                starVelocityMetric(
                    value: signedRate(starHistoryViewModel.averageDailyGrowth30Days),
                    label: "insights.repo.star.velocity30Days",
                    systemImage: "calendar.day.timeline.leading"
                )
                starVelocityMetric(
                    value: signedRate(starHistoryViewModel.averageMonthlyGrowthOneYear),
                    label: "insights.repo.star.velocityOneYear",
                    systemImage: "calendar"
                )
            }
        }
    }

    private func signedRate(_ value: Double?) -> String {
        guard let value else {
            return String.l10n("insights.repo.state.noData")
        }
        let fractionDigits = abs(value) < 1 ? 2 : 1
        let formatted = abs(value).formatted(
            .number.precision(.fractionLength(fractionDigits)).locale(locale)
        )
        if value > 0 { return "+\(formatted)" }
        if value < 0 { return "−\(formatted)" }
        return formatted
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
            // 全局刷新时跟着转；单独刷 Star 不得带动底栏全局图标。
            isRefreshing: starHistoryViewModel.isRefreshing || viewModel.isRefreshingAll,
            disabled: starHistoryViewModel.isRefreshing || viewModel.isRefreshingAll,
            tooltip: String.l10n("insights.repo.star.refresh")
        ) {
            Task {
                await starHistoryViewModel.refresh(repo: repo)
            }
        }
    }

    private var starSources: some View {
        // 顺序是产品语义：本机精确快照是共同基线，项目仓库再追加 GitHub 重建历史。
        HStack(spacing: 8) {
            ForEach(
                StarHistoryDisplayPolicy.legendPrecisions(points: displayedStarPoints),
                id: \.rawValue
            ) { precision in
                switch precision {
                case .snapshot:
                    starSourceChip(
                        title: "insights.repo.star.source.snapshot",
                        systemImage: "internaldrive.fill",
                        dashed: false
                    )
                case .reconstructed:
                    starSourceChip(
                        title: "insights.repo.star.source.name.githubStargazers",
                        systemImage: "person.2.fill",
                        dashed: true
                    )
                case .estimated:
                    starSourceChip(
                        title: "insights.repo.star.source.estimated",
                        systemImage: "waveform.path.ecg",
                        dashed: true
                    )
                }
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

    private var reconstructedStarPoints: [StarHistoryPoint] {
        displayedStarPoints.filter { $0.precision == .reconstructed }
    }

    private var preciseStarPoints: [StarHistoryPoint] {
        displayedStarPoints.filter { $0.precision == .snapshot }
    }

    private var starLineBridges: [StarHistoryChartBridge] {
        StarHistoryChartSeriesBuilder.bridges(in: displayedStarPoints)
    }

    private var selectedStarPoint: StarHistoryPoint? {
        StarHistoryDisplayPolicy.selectedPoint(
            in: displayedStarPoints,
            selectedDate: selectedStarDate
        )
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
            // 正常有点：项目重建历史优先展示专属来源，其次公共估算，最后本机快照。
            guard !displayedStarPoints.isEmpty else { return nil }
            if displayedStarPoints.contains(where: { $0.source == .githubStargazers }) {
                return ("person.2.fill", "insights.repo.star.source.githubStargazers")
            }
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

            ForEach(reconstructedStarPoints) { point in
                LineMark(
                    x: .value("Date", point.date),
                    y: .value("Stars", point.count),
                    series: .value("Source", "GitHub Stargazers")
                )
                .foregroundStyle(Color.blue.opacity(0.8))
                // 虚线提示这是按当前 Stargazers 重建的曲线，不等同完整历史事件流。
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 3]))
                .interpolationMethod(.catmullRom)
            }

            ForEach(starLineBridges) { bridge in
                starBridgeMarks(bridge)
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

    /// 桥接段沿用前一组折线的样式：估算 / 重建继续虚线，精确快照保持实线。
    ///
    /// 使用线性插值是为了只表达两个观测点之间的连接，不在长时间空档里制造
    /// Catmull-Rom 曲线的额外波动。
    @ChartContentBuilder
    private func starBridgeMarks(_ bridge: StarHistoryChartBridge) -> some ChartContent {
        let color: Color = switch bridge.inheritedPrecision {
        case .estimated:
            Color.blue.opacity(0.72)
        case .reconstructed:
            Color.blue.opacity(0.8)
        case .snapshot:
            Color.blue
        }
        let strokeStyle: StrokeStyle = switch bridge.inheritedPrecision {
        case .estimated:
            StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4])
        case .reconstructed:
            StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 3])
        case .snapshot:
            StrokeStyle(lineWidth: 2.5, lineCap: .round)
        }

        LineMark(
            x: .value("Date", bridge.start.date),
            y: .value("Stars", bridge.start.count),
            series: .value("Source", bridge.id)
        )
        .foregroundStyle(color)
        .lineStyle(strokeStyle)
        .interpolationMethod(.linear)

        LineMark(
            x: .value("Date", bridge.end.date),
            y: .value("Stars", bridge.end.count),
            series: .value("Source", bridge.id)
        )
        .foregroundStyle(color)
        .lineStyle(strokeStyle)
        .interpolationMethod(.linear)
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

    private var commitSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.commits",
            subtitle: LocalizedStringKey(
                viewModel.commitActivityRange.usesDailyCommitBars
                    ? "insights.repo.section.commits.subtitle.daily"
                    : "insights.repo.section.commits.subtitle"
            ),
            systemImage: "chart.bar.fill",
            iconColor: .blue,
            chrome: .emphasized
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // 与活动概览同款：左脉搏三指标、右独立 range + 刷新。
                HStack(alignment: .center, spacing: 8) {
                    if let pulse = displayedCommitActivity?.maintenancePulse {
                        maintenancePulseRow(pulse)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if isCommitAwaitingFirstContent {
                        InsightsSectionSkeleton(kind: .derivedPills())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Spacer(minLength: 0)
                    }
                    commitControls
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

    private var commitControls: some View {
        HStack(spacing: 8) {
            PillSegmentedControl(
                items: Array(RepositoryActivityRange.allCases),
                selection: commitActivityRangeBinding,
                title: { LocalizedStringKey($0.titleKey) },
                size: .compact
            )
            .accessibilityLabel(Text("insights.repo.activity.range.label"))

            SyncIconButton(
                isRefreshing: viewModel.isRefreshingCommitActivity || viewModel.isRefreshingAll,
                disabled: viewModel.isRefreshingCommitActivity || viewModel.isRefreshingAll,
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
                InsightsSectionSkeleton(kind: .chart(height: Self.chartPlotHeight))
            case .generating:
                InsightsSectionSkeleton(
                    kind: .chart(height: Self.chartPlotHeight),
                    statusCaptionKey: "insights.repo.state.generating"
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

    /// 提交图尚无缓存，且仍在首次拉取 / GitHub 准备中。
    private var isCommitAwaitingFirstContent: Bool {
        switch viewModel.commitActivityState {
        case .idle, .loading, .generating:
            return true
        case .content, .stale, .unavailable, .failed:
            return false
        }
    }

    private func maintenancePulseRow(_ pulse: RepositoryMaintenancePulse) -> some View {
        HStack(spacing: 8) {
            commitPulseMetric(
                title: "insights.repo.commit.pulse.recent",
                value: pulse.recentCommits.formatted(.number.locale(locale)),
                systemImage: "bolt.fill"
            )
            commitPulseMetric(
                title: "insights.repo.commit.pulse.comparison",
                value: signedPercentage(pulse.comparisonPercentage),
                systemImage: "chart.line.uptrend.xyaxis"
            )
            commitPulseMetric(
                title: "insights.repo.commit.pulse.activeWeeks",
                value: String(
                    format: String.l10n("insights.repo.commit.pulse.activeWeeksFormat"),
                    locale: locale,
                    pulse.activeWeeks
                ),
                systemImage: "calendar.badge.checkmark"
            )
        }
        .accessibilityElement(children: .contain)
    }

    private func commitPulseMetric(
        title: LocalizedStringKey,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.blue)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Text(verbatim: value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(interfaceScale.font(.caption))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            Color.blue.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.blue.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: value))
    }

    private func signedPercentage(_ value: Int?) -> String {
        guard let value else {
            return String.l10n("insights.repo.state.noData")
        }
        if value > 0 { return "+\(value)%" }
        return "\(value)%"
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
            systemImage: "person.3.fill",
            iconColor: .purple,
            chrome: .emphasized
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
                        if let concentration = insight.concentration {
                            contributorConcentrationRow(concentration)
                        }

                        let visible = isContributorsExpanded
                            ? insight.contributors
                            : Array(insight.contributors.prefix(Self.visibleContributorLimit))
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 142), spacing: 10)],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(visible) { contributor in
                                contributorItem(contributor)
                            }
                        }

                        if insight.contributors.count > Self.visibleContributorLimit {
                            HStack {
                                Spacer(minLength: 0)
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
                    }
                } else {
                    switch viewModel.contributorsState {
                    case .idle, .loading:
                        InsightsSectionSkeleton(kind: .contributorBlock())
                    case .unavailable:
                        compactEmptyState(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "person.crop.circle.badge.exclamationmark"
                        )
                    case .generating:
                        InsightsSectionSkeleton(
                            kind: .contributorBlock(),
                            statusCaptionKey: "insights.repo.state.generating"
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

    private func contributorConcentrationRow(
        _ concentration: RepositoryContributorConcentration
    ) -> some View {
        HStack(spacing: 8) {
            contributorConcentrationMetric(
                title: "insights.repo.contributor.topOneShare",
                value: contributorShare(concentration.topContributorShare),
                systemImage: "person.fill"
            )
            contributorConcentrationMetric(
                title: "insights.repo.contributor.topThreeShare",
                value: contributorShare(concentration.topThreeShare),
                systemImage: "person.3.fill"
            )
            contributorConcentrationMetric(
                title: "insights.repo.contributor.sampleSize",
                value: concentration.sampledContributors.formatted(.number.locale(locale)),
                systemImage: "number"
            )
        }
    }

    private func contributorConcentrationMetric(
        title: LocalizedStringKey,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.purple)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Text(verbatim: value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(interfaceScale.font(.caption))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.55),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: value))
    }

    private func contributorShare(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
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
            systemImage: "heart.text.square.fill",
            iconColor: .pink,
            chrome: .emphasized
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
                    InsightsSectionSkeleton(kind: .healthGrid())
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

    private var releaseCadenceSection: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.releaseCadence",
            subtitle: "insights.repo.section.releaseCadence.subtitle",
            systemImage: "tag.fill",
            iconColor: .blue,
            chrome: .emphasized
        ) {
            switch viewModel.releaseCadenceState {
            case .content(let cadence):
                HStack(spacing: 8) {
                    releaseCadenceMetric(
                        title: "insights.repo.releaseCadence.lastYear",
                        value: cadence.releasesLastYear.formatted(.number.locale(locale)),
                        systemImage: "calendar"
                    )
                    releaseCadenceMetric(
                        title: "insights.repo.releaseCadence.averageInterval",
                        value: cadence.averageIntervalDays.map {
                            String(
                                format: String.l10n("insights.repo.releaseCadence.daysFormat"),
                                locale: locale,
                                $0
                            )
                        } ?? String.l10n("insights.repo.state.noData"),
                        systemImage: "arrow.left.and.right"
                    )
                    releaseCadenceMetric(
                        title: "insights.repo.releaseCadence.latest",
                        value: shortDate(cadence.latestPublishedAt),
                        systemImage: "clock"
                    )
                }
            case .loading, .idle:
                InsightsSectionSkeleton(kind: .derivedPills(count: 3))
            case .empty:
                compactEmptyState(
                    "insights.repo.releaseCadence.empty",
                    systemImage: "tag.slash"
                )
            case .unavailable:
                compactEmptyState(
                    "insights.repo.releaseCadence.authenticationRequired",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
            case .failed:
                compactEmptyState(
                    "insights.repo.releaseCadence.loadFailed",
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    private func releaseCadenceMetric(
        title: LocalizedStringKey,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.blue)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Text(verbatim: value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(interfaceScale.font(.caption))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            Color.blue.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.blue.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: value))
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
            tint.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringKey(dimension.titleKey)))
        .accessibilityValue(
            Text(verbatim: dimension.score.formatted(.number.locale(locale)))
        )
    }

    private var localSignalsSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                communitySignalGroup.frame(minWidth: 248)
                securitySignalGroup.frame(minWidth: 248)
            }
            VStack(spacing: 12) {
                communitySignalGroup
                securitySignalGroup
            }
        }
    }

    private var communitySignalGroup: some View {
        InsightsSectionContainer(
            title: "insights.repo.section.community",
            subtitle: "insights.repo.section.community.subtitle",
            systemImage: "person.2.fill",
            iconColor: .indigo,
            chrome: .emphasized
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
                            id: "community.issueTemplate",
                            title: "insights.repo.signal.issueTemplate",
                            isAvailable: community.hasIssueTemplate,
                            systemImage: "exclamationmark.bubble.fill",
                            destinationURL: communitySignalURL(
                                isAvailable: community.hasIssueTemplate,
                                stored: community.issueTemplateHTMLURL,
                                fallbackSuffix: "/issues/new/choose"
                            )
                        )
                        Divider().padding(.leading, 28)
                        localSignalRow(
                            id: "community.pullRequestTemplate",
                            title: "insights.repo.signal.pullRequestTemplate",
                            isAvailable: community.hasPullRequestTemplate,
                            systemImage: "arrow.triangle.pull",
                            destinationURL: communitySignalURL(
                                isAvailable: community.hasPullRequestTemplate,
                                stored: community.pullRequestTemplateHTMLURL,
                                fallbackSuffix: "/compare"
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
                        InsightsSectionSkeleton(kind: .signalRows(count: 6))
                    case .unavailable:
                        compactEmptyState(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "person.2.slash"
                        )
                    case .generating:
                        InsightsSectionSkeleton(
                            kind: .signalRows(count: 6),
                            statusCaptionKey: "insights.repo.state.generating"
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
            systemImage: "lock.shield.fill",
            iconColor: .red,
            chrome: .emphasized
        ) {
            VStack(spacing: 0) {
                openSSFSignalContent
                Divider().padding(.leading, 28)
                securityAdvisoriesContent
            }
        }
    }

    @ViewBuilder
    private var openSSFSignalContent: some View {
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
            InsightsSectionSkeleton(kind: .signalRows(count: 1))
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

    @ViewBuilder
    private var securityAdvisoriesContent: some View {
        if let insight = displayedSecurityAdvisories {
            VStack(spacing: 0) {
                localSignalRow(
                    id: "security.advisories",
                    title: "insights.repo.signal.securityAdvisories",
                    statusText: insight.advisories.count.formatted(.number.locale(locale)),
                    statusColor: insight.advisories.isEmpty ? .green : .orange,
                    systemImage: "exclamationmark.shield.fill",
                    destinationURL: repositorySecurityAdvisoriesURL
                )
                Divider().padding(.leading, 28)
                localSignalRow(
                    id: "security.highRiskAdvisories",
                    title: "insights.repo.signal.highRiskAdvisories",
                    statusText: insight.highOrCriticalCount.formatted(.number.locale(locale)),
                    statusColor: insight.highOrCriticalCount == 0 ? .green : .orange,
                    systemImage: "exclamationmark.triangle.fill",
                    destinationURL: nil
                )
                if let latestPublishedAt = insight.latestPublishedAt {
                    Divider().padding(.leading, 28)
                    localSignalRow(
                        id: "security.latestAdvisory",
                        title: "insights.repo.signal.latestAdvisory",
                        statusText: shortDate(latestPublishedAt),
                        statusColor: .orange,
                        systemImage: "calendar",
                        destinationURL: insight.advisories.first?.htmlURL
                    )
                }
            }
        } else {
            switch viewModel.securityAdvisoriesState {
            case .idle, .loading:
                InsightsSectionSkeleton(kind: .signalRows(count: 2))
            case .unavailable:
                compactEmptyState(
                    authSession.state.isAuthenticated
                        ? "insights.repo.state.noData"
                        : "insights.repo.state.loginRequired",
                    systemImage: "lock.slash"
                )
            case .generating:
                InsightsSectionSkeleton(
                    kind: .signalRows(count: 2),
                    statusCaptionKey: "insights.repo.state.generating"
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

    private var displayedSecurityAdvisories: RepositorySecurityAdvisoriesInsight? {
        viewModel.securityAdvisoriesState.visibleValue
    }

    private var repositorySecurityAdvisoriesURL: URL? {
        let base = repo.htmlUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + "/security/advisories")
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
            systemImage: "clock.arrow.circlepath",
            iconColor: .cyan,
            chrome: .emphasized
        ) {
            // 时间线默认折叠；刷新交给整页 / 上游区块，避免再挂一颗 Sync。
            VStack(alignment: .leading, spacing: 8) {
                if timelineAllItems.isEmpty {
                    switch viewModel.recentActivityState {
                    case .idle, .loading:
                        InsightsSectionSkeleton(kind: .signalRows(count: 5))
                    case .unavailable:
                        compactEmptyState(
                            authSession.state.isAuthenticated
                                ? "insights.repo.state.noData"
                                : "insights.repo.state.loginRequired",
                            systemImage: "clock.badge.exclamationmark"
                        )
                    case .generating:
                        InsightsSectionSkeleton(
                            kind: .signalRows(count: 5),
                            statusCaptionKey: "insights.repo.state.generating"
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
                        HStack {
                            Spacer(minLength: 0)
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

/// 仓库洞察 ScrollView 内容固有高度；仅用于锁定 contentSize，不参与业务状态。
private struct InsightsContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
