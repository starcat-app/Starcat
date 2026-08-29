//
//  StarcatContributionRadarWidget.swift
//  StarcatWidgets
//
//  五维 GitHub 活跃度雷达 Widget 的注册入口。
//

import SwiftUI
import WidgetKit

/// 对应参考图中的独立小尺寸雷达卡片。
struct StarcatContributionRadarWidget: Widget {
    private let kind = "com.starcat.widget.contribution-radar"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StarcatContributionProvider()) { entry in
            StarcatContributionRadarWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("widget.contribution.radar.displayName")
        .description("widget.contribution.radar.description")
        .supportedFamilies([.systemSmall])
    }
}
