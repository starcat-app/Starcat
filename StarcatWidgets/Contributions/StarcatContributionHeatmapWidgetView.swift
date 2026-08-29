//
//  StarcatContributionHeatmapWidgetView.swift
//  StarcatWidgets
//
//  小、中尺寸纯贡献热力图布局。
//

import SwiftUI
import WidgetKit

/// 只保留贡献格本身，让桌面上可以作为安静、低文字密度的状态卡片使用。
struct StarcatContributionHeatmapWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: StarcatWidgetEntry

    private var openURL: URL {
        WidgetAppDeepLink(destination: .main).url
    }

    var body: some View {
        if let emptyView = entry.content.emptyView {
            emptyView
        } else if let activity = entry.snapshot?.contributionActivity {
            ZStack(alignment: .topTrailing) {
                StarcatContributionHeatmap(
                    weeks: activity.weeks,
                    weekCount: family == .systemSmall ? 7 : 18
                )

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
                Text("widget.contribution.total.accessibility \(activity.totalContributions)")
            )
        } else {
            StarcatWidgetEmptyView(
                symbol: "square.grid.3x3.fill",
                titleKey: "widget.contribution.empty.title",
                subtitleKey: "widget.contribution.empty.subtitle",
                openURL: openURL,
                accessibilityHintKey: "widget.contribution.openStarcat"
            )
        }
    }
}
