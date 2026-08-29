//
//  StarcatContributionOverviewWidgetView.swift
//  StarcatWidgets
//
//  中尺寸三指标、热力图与雷达图组合布局。
//

import SwiftUI

/// 在一个中尺寸卡片内同时表达贡献强度、峰值与活动结构。
struct StarcatContributionOverviewWidgetView: View {
    let entry: StarcatWidgetEntry

    private var openURL: URL {
        WidgetAppDeepLink(destination: .main).url
    }

    var body: some View {
        if let emptyView = entry.content.emptyView {
            emptyView
        } else if let activity = entry.snapshot?.contributionActivity {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 16) {
                        StarcatContributionMetric(
                            value: activity.todayContributions,
                            titleKey: "widget.contribution.today"
                        )
                        StarcatContributionMetric(
                            value: activity.bestDayContributions,
                            titleKey: "widget.contribution.best"
                        )
                        StarcatContributionMetric(
                            value: activity.totalContributions,
                            titleKey: "widget.contribution.total"
                        )
                    }

                    StarcatContributionHeatmap(weeks: activity.weeks, weekCount: 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                Divider().opacity(0.35)

                ZStack(alignment: .topTrailing) {
                    StarcatContributionRadarChart(stats: activity.stats)
                    if entry.isStale {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("widget.common.stale"))
                    }
                }
                .frame(width: 150)
            }
            .widgetURL(openURL)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text(
                    "widget.contribution.overview.accessibility \(activity.todayContributions) \(activity.bestDayContributions) \(activity.totalContributions)"
                )
            )
        } else {
            StarcatWidgetEmptyView(
                symbol: "chart.xyaxis.line",
                titleKey: "widget.contribution.empty.title",
                subtitleKey: "widget.contribution.empty.subtitle",
                openURL: openURL,
                accessibilityHintKey: "widget.contribution.openStarcat"
            )
        }
    }
}
