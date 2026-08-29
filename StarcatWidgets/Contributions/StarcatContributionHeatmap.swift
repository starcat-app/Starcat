//
//  StarcatContributionHeatmap.swift
//  StarcatWidgets
//
//  GitHub 贡献 Widget 共用的静态周历热力图。
//

import SwiftUI

/// 按 GitHub 周边界绘制贡献格，并针对系统浅色、深色背景使用独立五档色板。
struct StarcatContributionHeatmap: View {
    @Environment(\.colorScheme) private var colorScheme

    let weeks: [WidgetContributionWeek]
    let weekCount: Int

    var body: some View {
        GeometryReader { proxy in
            let displayedWeeks = Array(weeks.suffix(weekCount))
            let spacing: CGFloat = weekCount <= 7 ? 5 : 4
            let cellSize = max(
                3,
                min(
                    (proxy.size.width - spacing * CGFloat(max(0, weekCount - 1)))
                        / CGFloat(max(1, weekCount)),
                    (proxy.size.height - spacing * 6) / 7
                )
            )

            HStack(alignment: .top, spacing: spacing) {
                ForEach(Array(displayedWeeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { weekday in
                            if let day = week.days.first(where: { $0.weekday == weekday }) {
                                RoundedRectangle(cornerRadius: max(2, cellSize * 0.22))
                                    .fill(color(for: day.level))
                                    .frame(width: cellSize, height: cellSize)
                            } else {
                                Color.clear
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .center
            )
        }
        // 逐格朗读会制造最多 126 个无效焦点，卡片根视图提供汇总描述即可。
        .accessibilityHidden(true)
    }

    /// 图表填充色可以使用固定数据色；文字和图标仍严格使用系统语义色。
    private func color(for level: WidgetContributionLevel) -> Color {
        switch (colorScheme, level) {
        case (.dark, .none):
            Color(red: 0.17, green: 0.18, blue: 0.19)
        case (.dark, .firstQuartile):
            Color(red: 0.05, green: 0.27, blue: 0.16)
        case (.dark, .secondQuartile):
            Color(red: 0.00, green: 0.43, blue: 0.20)
        case (.dark, .thirdQuartile):
            Color(red: 0.15, green: 0.65, blue: 0.25)
        case (.dark, .fourthQuartile):
            Color(red: 0.22, green: 0.83, blue: 0.33)
        case (_, .none):
            Color(red: 0.93, green: 0.94, blue: 0.95)
        case (_, .firstQuartile):
            Color(red: 0.61, green: 0.91, blue: 0.66)
        case (_, .secondQuartile):
            Color(red: 0.25, green: 0.77, blue: 0.39)
        case (_, .thirdQuartile):
            Color(red: 0.19, green: 0.63, blue: 0.31)
        case (_, .fourthQuartile):
            Color(red: 0.13, green: 0.43, blue: 0.22)
        }
    }
}
