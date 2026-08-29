//
//  StarcatContributionHeatmapWidget.swift
//  StarcatWidgets
//
//  纯热力图贡献 Widget 的注册入口。
//

import SwiftUI
import WidgetKit

/// 对应参考图中的小尺寸方形草坪与中尺寸横向草坪。
struct StarcatContributionHeatmapWidget: Widget {
    private let kind = "com.starcat.widget.contribution-heatmap"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StarcatContributionProvider()) { entry in
            StarcatContributionHeatmapWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("widget.contribution.heatmap.displayName")
        .description("widget.contribution.heatmap.description")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
