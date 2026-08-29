//
//  StarcatCollectionTrendWidget.swift
//  StarcatWidgets
//
//  用收藏日历热力图展示公开 GitHub Star 的增长节奏与整理状态。
//
//  Widget Extension 只读取 App Group 聚合快照，不访问 GRDB、网络或 Keychain。
//  每个 Widget 实例可独立选择热力图配色，系统背景与文字语义色保持不变。
//

import AppIntents
import SwiftUI
import WidgetKit

/// 收藏趋势 Widget 的注册入口。
struct StarcatCollectionTrendWidget: Widget {
    private let kind = "com.starcat.widget.collection-trend"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: CollectionTrendConfigurationIntent.self,
            provider: StarcatCollectionTrendProvider()
        ) { entry in
            StarcatCollectionTrendWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("widget.collectionTrend.displayName")
        .description("widget.collectionTrend.heatmapDescription")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// 时间线条目把共享快照与单实例主题组合起来，不把展示偏好写入业务快照。
struct StarcatCollectionTrendEntry: TimelineEntry {
    let date: Date
    let base: StarcatWidgetEntry
    let palette: CollectionTrendPalette
}

/// 收藏趋势沿用标准快照刷新节奏；主应用发布新快照后仍会主动 reload timeline。
struct StarcatCollectionTrendProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> StarcatCollectionTrendEntry {
        makeEntry(base: .placeholder, configuration: CollectionTrendConfigurationIntent())
    }

    func snapshot(
        for configuration: CollectionTrendConfigurationIntent,
        in context: Context
    ) async -> StarcatCollectionTrendEntry {
        makeEntry(
            base: context.isPreview ? .placeholder : StarcatWidgetSnapshotLoader.load(),
            configuration: configuration
        )
    }

    func timeline(
        for configuration: CollectionTrendConfigurationIntent,
        in context: Context
    ) async -> Timeline<StarcatCollectionTrendEntry> {
        let base = StarcatWidgetSnapshotLoader.load()
        let entry = makeEntry(base: base, configuration: configuration)
        return Timeline(
            entries: [entry],
            policy: .after(
                StarcatWidgetSnapshotLoader.nextRefresh(
                    after: entry.date,
                    isReady: entry.base.snapshot != nil,
                    kind: .standard
                )
            )
        )
    }

    private func makeEntry(
        base: StarcatWidgetEntry,
        configuration: CollectionTrendConfigurationIntent
    ) -> StarcatCollectionTrendEntry {
        StarcatCollectionTrendEntry(
            date: base.date,
            base: base,
            palette: configuration.palette
        )
    }
}

/// Small / Medium 逐级增加指标密度，热力图始终是主要视觉焦点。
struct StarcatCollectionTrendWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StarcatCollectionTrendEntry

    private var insightsURL: URL {
        WidgetAppDeepLink(destination: .insights).url
    }

    private var referenceDate: Date {
        entry.base.snapshot?.generatedAt ?? entry.date
    }

    var body: some View {
        if let emptyView = entry.base.content.emptyView {
            emptyView
        } else if let trend = entry.base.snapshot?.collectionTrend,
                  let dailyPoints = trend.dailyPoints,
                  !dailyPoints.isEmpty {
            trendContent(trend, dailyPoints: dailyPoints)
                .widgetURL(insightsURL)
                .accessibilityHint(Text("widget.collectionTrend.openInsights"))
        } else {
            // v1/v2 快照没有单日聚合，不能伪造星期分布；等待主应用发布 v3 快照。
            StarcatWidgetEmptyView(
                symbol: "square.grid.3x3",
                titleKey: "widget.collectionTrend.empty.title",
                subtitleKey: "widget.collectionTrend.empty.subtitle",
                openURL: insightsURL,
                accessibilityHintKey: "widget.collectionTrend.openInsights"
            )
        }
    }

    @ViewBuilder
    private func trendContent(
        _ trend: WidgetCollectionTrend,
        dailyPoints: [WidgetCollectionTrendDay]
    ) -> some View {
        switch family {
        case .systemSmall:
            smallContent(trend, dailyPoints: dailyPoints)
        default:
            mediumContent(trend, dailyPoints: dailyPoints)
        }
    }

    /// Small 去掉传统标题栏，把有限面积留给最近七周热力格。
    private func smallContent(
        _ trend: WidgetCollectionTrend,
        dailyPoints: [WidgetCollectionTrendDay]
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                Text("widget.collectionTrend.last30Days")
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(trend.addedInLast30DaysCount)")
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                if entry.base.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("widget.common.stale"))
                }
            }
            .font(.caption)

            StarcatCollectionHeatmap(
                points: dailyPoints,
                weekCount: 7,
                referenceDate: referenceDate,
                palette: entry.palette
            )
        }
        .accessibilityElement(children: .combine)
    }

    /// Medium 使用左右分栏：十三周热力图负责节奏，右侧大数字负责快速扫描。
    private func mediumContent(
        _ trend: WidgetCollectionTrend,
        dailyPoints: [WidgetCollectionTrendDay]
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                compactTitle
                StarcatCollectionHeatmap(
                    points: dailyPoints,
                    weekCount: 13,
                    referenceDate: referenceDate,
                    palette: entry.palette
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().opacity(0.35)

            VStack(alignment: .leading, spacing: 2) {
                metric(
                    value: "\(trend.addedInLast30DaysCount)",
                    titleKey: "widget.collectionTrend.last30Days",
                    prominent: true
                )
                Spacer(minLength: 8)
                metric(
                    value: "\(trend.totalCount)",
                    titleKey: "widget.collectionTrend.total"
                )
            }
            .frame(width: 92, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var compactTitle: some View {
        HStack(spacing: 5) {
            Image(systemName: "square.grid.3x3.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("widget.collectionTrend.title")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if entry.base.isStale {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("widget.common.stale"))
            }
        }
        .font(.caption.weight(.semibold))
    }

    private func metric(
        value: String,
        titleKey: LocalizedStringKey,
        prominent: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: value)
                .font(
                    prominent
                        ? .system(size: 30, weight: .bold, design: .rounded)
                        : .title3.weight(.bold)
                )
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
            Text(titleKey)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

}
