//
//  StarcatContributionSummaryWidget.swift
//  StarcatWidgets
//
//  热力图与双指标组合 Widget 的注册入口。
//

import SwiftUI
import WidgetKit

/// 对应参考图中的“左侧草坪、右侧今日与总贡献”中尺寸卡片。
struct StarcatContributionSummaryWidget: Widget {
    private let kind = "com.starcat.widget.contribution-summary"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StarcatContributionProvider()) { entry in
            StarcatContributionSummaryWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("widget.contribution.summary.displayName")
        .description("widget.contribution.summary.description")
        .supportedFamilies([.systemMedium])
    }
}
