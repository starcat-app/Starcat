//
//  StarcatContributionSummaryWidgetView.swift
//  StarcatWidgets
//
//  中尺寸热力图与双指标组合布局。
//

import SwiftUI

/// 热力图承担节奏扫描，右侧数字承担今日与年度汇总，两区用系统分隔线建立层级。
struct StarcatContributionSummaryWidgetView: View {
    let entry: StarcatWidgetEntry

    private var openURL: URL {
        WidgetAppDeepLink(destination: .main).url
    }

    var body: some View {
        if let emptyView = entry.content.emptyView {
            emptyView
        } else if let activity = entry.snapshot?.contributionActivity {
            HStack(spacing: 16) {
                StarcatContributionHeatmap(weeks: activity.weeks, weekCount: 11)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().opacity(0.35)

                VStack(alignment: .leading, spacing: 4) {
                    if entry.isStale {
                        HStack {
                            Spacer()
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(Text("widget.common.stale"))
                        }
                    }

                    Spacer(minLength: 0)
                    StarcatContributionMetric(
                        value: activity.todayContributions,
                        titleKey: "widget.contribution.today",
                        prominent: true
                    )
                    Spacer(minLength: 10)
                    StarcatContributionMetric(
                        value: activity.totalContributions,
                        titleKey: "widget.contribution.total",
                        prominent: true
                    )
                    Spacer(minLength: 0)
                }
                .frame(width: 118, alignment: .leading)
            }
            .widgetURL(openURL)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                Text(
                    "widget.contribution.summary.accessibility \(activity.todayContributions) \(activity.totalContributions)"
                )
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
