//
//  StarHistoryAxisValueFormatter.swift
//  Starcat
//
//  Star 历史曲线纵轴的紧凑数值格式化策略。
//
//  关键约束：这里只压缩坐标轴标签以节省布局宽度；悬浮提示、统计卡片和
//  VoiceOver 仍使用完整数值，不能因为视觉简化而丢失精确信息。
//

import Foundation

enum StarHistoryAxisValueFormatter {
    /// 将坐标轴数值压缩为最多一位小数的 K / M 表示，同时遵循当前界面的小数分隔符。
    static func string(from value: Double, locale: Locale) -> String {
        let magnitude = abs(value)
        let divisor: Double
        let suffix: String

        switch magnitude {
        case 999_500...:
            // 提前把会四舍五入到 1,000K 的数值提升为 M，避免显示宽度反而变长。
            divisor = 1_000_000
            suffix = "M"
        case 1_000...:
            divisor = 1_000
            suffix = "K"
        default:
            return value.formatted(
                .number
                    .precision(.fractionLength(0))
                    .locale(locale)
            )
        }

        let compactValue = value / divisor
        let formatted = compactValue.formatted(
            .number
                .precision(.fractionLength(0...1))
                .locale(locale)
        )
        return formatted + suffix
    }
}
