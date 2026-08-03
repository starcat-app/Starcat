//
//  StarcatCollectionTrendWidget.swift
//  StarcatWidgets
//
//  用 Swift Charts 展示公开收藏的近 12 周增长节奏与阅读状态分布。
//
//  Widget Extension 只读取 App Group 聚合快照，不访问 GRDB、网络或 Keychain。
//  三种尺寸共用同一份趋势数据，按系统分配空间逐级增加信息密度。
//

import Charts
import SwiftUI
import WidgetKit

/// 收藏趋势 Widget 的注册入口。
struct StarcatCollectionTrendWidget: Widget {
    private let kind = "com.starcat.widget.collection-trend"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StarcatCollectionTrendProvider()) { entry in
            StarcatCollectionTrendWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("widget.collectionTrend.displayName")
        .description("widget.collectionTrend.description")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// 收藏趋势沿用标准快照刷新节奏；主应用发布新快照后仍会主动 reload timeline。
struct StarcatCollectionTrendProvider: TimelineProvider {
    func placeholder(in context: Context) -> StarcatWidgetEntry {
        .placeholder
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (StarcatWidgetEntry) -> Void
    ) {
        completion(context.isPreview ? .placeholder : StarcatWidgetSnapshotLoader.load())
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<StarcatWidgetEntry>) -> Void
    ) {
        let entry = StarcatWidgetSnapshotLoader.load()
        completion(
            Timeline(
                entries: [entry],
                policy: .after(
                    StarcatWidgetSnapshotLoader.nextRefresh(
                        after: entry.date,
                        isReady: entry.snapshot != nil,
                        kind: .standard
                    )
                )
            )
        )
    }
}

/// 按 Small / Medium / Large 渐进呈现趋势指标。
struct StarcatCollectionTrendWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StarcatWidgetEntry

    private var insightsURL: URL {
        WidgetAppDeepLink(destination: .insights).url
    }

    var body: some View {
        if let emptyView = entry.content.emptyView {
            emptyView
        } else if let trend = entry.snapshot?.collectionTrend {
            trendContent(trend)
                .widgetURL(insightsURL)
                .accessibilityHint(Text("widget.collectionTrend.openInsights"))
        } else {
            // v1 ready 快照没有趋势字段；引导打开主应用发布 v2，而不是把它误报成零收藏。
            StarcatWidgetEmptyView(
                symbol: "chart.bar.xaxis",
                titleKey: "widget.collectionTrend.empty.title",
                subtitleKey: "widget.collectionTrend.empty.subtitle",
                openURL: insightsURL,
                accessibilityHintKey: "widget.collectionTrend.openInsights"
            )
        }
    }

    @ViewBuilder
    private func trendContent(_ trend: WidgetCollectionTrend) -> some View {
        switch family {
        case .systemSmall:
            smallContent(trend)
        case .systemLarge:
            largeContent(trend)
        default:
            mediumContent(trend)
        }
    }

    /// Small 以“近 30 天”为主指标，同时保留 6 周方向感和公开收藏总数。
    private func smallContent(_ trend: WidgetCollectionTrend) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            StarcatWidgetHeader(
                "widget.collectionTrend.title",
                systemImage: "chart.bar.xaxis",
                isStale: entry.isStale
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(trend.addedInLast30DaysCount)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text("widget.collectionTrend.last30Days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            collectionChart(
                points: Array(trend.weeklyPoints.suffix(6)),
                height: 42
            )

            HStack {
                Text("widget.collectionTrend.publicScope")
                Spacer(minLength: 6)
                Text(verbatim: "\(trend.totalCount)")
                    .fontWeight(.semibold)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Medium 用三项统计解释 12 周柱形图，避免只给一张没有上下文的图。
    private func mediumContent(_ trend: WidgetCollectionTrend) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            StarcatWidgetHeader(
                "widget.collectionTrend.title",
                systemImage: "chart.bar.xaxis",
                isStale: entry.isStale
            ) {
                Text("widget.collectionTrend.publicScope")
            }

            HStack(spacing: 18) {
                metric(
                    value: "\(trend.weeklyPoints.last?.count ?? 0)",
                    titleKey: "widget.collectionTrend.thisWeek"
                )
                metric(
                    value: "\(trend.addedInLast30DaysCount)",
                    titleKey: "widget.collectionTrend.last30Days"
                )
                metric(
                    value: "\(trend.totalCount)",
                    titleKey: "widget.collectionTrend.total"
                )
            }

            collectionChart(points: trend.weeklyPoints, height: 54)
        }
        .accessibilityElement(children: .contain)
    }

    /// Large 增加周均与状态分布，让“收藏速度”和“整理进度”在同一张卡片里形成闭环。
    private func largeContent(_ trend: WidgetCollectionTrend) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StarcatWidgetHeader(
                "widget.collectionTrend.title",
                systemImage: "chart.bar.xaxis",
                isStale: entry.isStale
            ) {
                Text("widget.collectionTrend.publicScope")
            }

            HStack(spacing: 24) {
                metric(
                    value: "\(trend.weeklyPoints.last?.count ?? 0)",
                    titleKey: "widget.collectionTrend.thisWeek"
                )
                metric(
                    value: "\(trend.addedInLast30DaysCount)",
                    titleKey: "widget.collectionTrend.last30Days"
                )
                metric(
                    value: weeklyAverageText(trend.weeklyPoints),
                    titleKey: "widget.collectionTrend.weeklyAverage"
                )
                metric(
                    value: "\(trend.totalCount)",
                    titleKey: "widget.collectionTrend.total"
                )
            }

            collectionChart(points: trend.weeklyPoints, height: 106)

            Divider().opacity(0.35)

            statusDistribution(trend.statusBreakdown)
        }
        .accessibilityElement(children: .contain)
    }

    /// 当前周使用强调色，历史周降为 secondary；坐标轴隐藏后更适合桌面卡片密度。
    private func collectionChart(
        points: [WidgetCollectionTrendPoint],
        height: CGFloat
    ) -> some View {
        let lastWeek = points.last?.weekStart
        let maximum = max(1, points.map(\.count).max() ?? 0)

        return Chart(points, id: \.weekStart) { point in
            BarMark(
                x: .value("Week", point.weekStart),
                y: .value("Count", point.count)
            )
            .foregroundStyle(
                point.weekStart == lastWeek
                    ? Color.accentColor
                    : Color.secondary.opacity(0.35)
            )
            .cornerRadius(3)
        }
        .chartXScale(range: .plotDimension(padding: 3))
        .chartYScale(domain: 0...maximum)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: height)
        // 数值已经由上方指标和状态行完整表达，隐藏逐柱 VoiceOver 可避免 12 次冗余朗读。
        .accessibilityHidden(true)
    }

    private func metric(value: String, titleKey: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
            Text(titleKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func statusDistribution(
        _ breakdown: WidgetCollectionStatusBreakdown
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                BarMark(
                    x: .value("Count", breakdown.unreadCount),
                    y: .value("Status", "Public")
                )
                .foregroundStyle(.orange)
                BarMark(
                    x: .value("Count", breakdown.readCount),
                    y: .value("Status", "Public")
                )
                .foregroundStyle(.blue)
                BarMark(
                    x: .value("Count", breakdown.usingCount),
                    y: .value("Status", "Public")
                )
                .foregroundStyle(.green)
            }
            .chartXScale(
                domain: 0...max(
                    1,
                    breakdown.unreadCount + breakdown.readCount + breakdown.usingCount
                )
            )
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 10)
            .accessibilityHidden(true)

            HStack(spacing: 16) {
                statusLabel(
                    color: .orange,
                    titleKey: "widget.collectionTrend.unread",
                    count: breakdown.unreadCount
                )
                statusLabel(
                    color: .blue,
                    titleKey: "widget.collectionTrend.read",
                    count: breakdown.readCount
                )
                statusLabel(
                    color: .green,
                    titleKey: "widget.collectionTrend.using",
                    count: breakdown.usingCount
                )
            }
        }
    }

    private func statusLabel(
        color: Color,
        titleKey: LocalizedStringKey,
        count: Int
    ) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(titleKey)
                .foregroundStyle(.secondary)
            Text(verbatim: "\(count)")
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
        .font(.caption)
    }

    private func weeklyAverageText(_ points: [WidgetCollectionTrendPoint]) -> String {
        guard !points.isEmpty else { return "0" }
        let average = Double(points.map(\.count).reduce(0, +)) / Double(points.count)
        return average.formatted(.number.precision(.fractionLength(1)))
    }
}
