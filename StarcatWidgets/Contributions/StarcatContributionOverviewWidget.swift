//
//  StarcatContributionOverviewWidget.swift
//  StarcatWidgets
//
//  热力图、三指标与雷达图组合 Widget 的注册入口。
//

import SwiftUI
import WidgetKit

/// 对应参考图底部的综合中尺寸贡献卡片。
struct StarcatContributionOverviewWidget: Widget {
    private let kind = "com.starcat.widget.contribution-overview"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StarcatContributionProvider()) { entry in
            StarcatContributionOverviewWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("widget.contribution.overview.displayName")
        .description("widget.contribution.overview.description")
        .supportedFamilies([.systemMedium])
    }
}
