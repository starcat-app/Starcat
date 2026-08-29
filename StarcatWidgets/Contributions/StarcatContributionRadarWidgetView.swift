//
//  StarcatContributionRadarWidgetView.swift
//  StarcatWidgets
//
//  小尺寸五维贡献雷达布局。
//

import SwiftUI

/// 用单张雷达图比较近一年 Commit、Issue、PR、Review 与新建仓库数量。
struct StarcatContributionRadarWidgetView: View {
    let entry: StarcatWidgetEntry

    private var openURL: URL {
        WidgetAppDeepLink(destination: .main).url
    }

    var body: some View {
        if let emptyView = entry.content.emptyView {
            emptyView
        } else if let activity = entry.snapshot?.contributionActivity {
            ZStack(alignment: .topTrailing) {
                StarcatContributionRadarChart(stats: activity.stats)

                if entry.isStale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("widget.common.stale"))
                }
            }
            .widgetURL(openURL)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text(
                    "widget.contribution.radar.accessibility \(activity.stats.commits) \(activity.stats.issues) \(activity.stats.pullRequests) \(activity.stats.reviews) \(activity.stats.repositories)"
                )
            )
        } else {
            StarcatWidgetEmptyView(
                symbol: "pentagon",
                titleKey: "widget.contribution.empty.title",
                subtitleKey: "widget.contribution.empty.subtitle",
                openURL: openURL,
                accessibilityHintKey: "widget.contribution.openStarcat"
            )
        }
    }
}
