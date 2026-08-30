//
//  StarHistoryStatistics.swift
//  Starcat
//
//  Star 历史增长指标的统一计算模型。
//
//  关键约束：
//  - 指标始终基于完整历史计算，不能随图表的 3 月 / 1 年 / 全部范围变化。
//  - 稀疏事件序列按累计值语义向前填充；目标日没有事件不等于没有统计数据。
//  - 仓库创建日晚于统计窗口起点时，以创建日 0 Stars 为真实基线。
//

import Foundation

struct StarHistoryStatistics: Equatable, Sendable {
    let growth30Days: Int?
    let growthOneYear: Int?
    let averageDailyGrowth30Days: Double?
    let averageMonthlyGrowthOneYear: Double?

    static let empty = StarHistoryStatistics(
        growth30Days: nil,
        growthOneYear: nil,
        averageDailyGrowth30Days: nil,
        averageMonthlyGrowthOneYear: nil
    )
}

enum StarHistoryStatisticsBuilder {
    private struct Window {
        let change: Int
        let elapsedDays: Double
    }

    private static let secondsPerDay: TimeInterval = 86_400

    static func build(
        points: [StarHistoryPoint],
        repositoryCreatedAt: Date?
    ) -> StarHistoryStatistics {
        let ordered = points.sorted { $0.date < $1.date }
        // 只有本机元数据快照时无法证明中间发生过什么，不能伪造历史增长。
        guard ordered.contains(where: { $0.source.isRemote }) else {
            return .empty
        }

        let thirtyDays = window(
            points: ordered,
            days: 30,
            repositoryCreatedAt: repositoryCreatedAt
        )
        let oneYear = window(
            points: ordered,
            days: 365,
            repositoryCreatedAt: repositoryCreatedAt
        )

        return StarHistoryStatistics(
            growth30Days: thirtyDays?.change,
            growthOneYear: oneYear?.change,
            averageDailyGrowth30Days: rate(for: thirtyDays, unitDays: 1),
            averageMonthlyGrowthOneYear: rate(for: oneYear, unitDays: 365.0 / 12.0)
        )
    }

    /// Star 历史点是累计值。目标日没有事件时，最后一个更早读数会自然延续到目标日；
    /// 若完整远端序列在目标日前没有任何点，则该日累计值仍为 0。
    private static func window(
        points: [StarHistoryPoint],
        days: Int,
        repositoryCreatedAt: Date?
    ) -> Window? {
        guard let latest = points.last else { return nil }

        let requestedStart = latest.date.addingTimeInterval(-TimeInterval(days) * secondsPerDay)
        let effectiveStart: Date
        let baselineCount: Int

        if let repositoryCreatedAt, repositoryCreatedAt > requestedStart {
            effectiveStart = repositoryCreatedAt
            baselineCount = 0
        } else {
            effectiveStart = requestedStart
            baselineCount = points.last(where: { $0.date <= requestedStart })?.count ?? 0
        }

        let elapsedDays = latest.date.timeIntervalSince(effectiveStart) / secondsPerDay
        guard elapsedDays > 0 else { return nil }
        return Window(change: latest.count - baselineCount, elapsedDays: elapsedDays)
    }

    private static func rate(for window: Window?, unitDays: Double) -> Double? {
        guard let window else { return nil }
        return Double(window.change) / window.elapsedDays * unitDays
    }
}
