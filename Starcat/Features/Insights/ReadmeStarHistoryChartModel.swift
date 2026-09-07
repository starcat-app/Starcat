//
//  ReadmeStarHistoryChartModel.swift
//  Starcat
//
//  README 历史卡片的整刻度与 90 天指标。只消费完整读模型，不改写历史数据。
//  绘图抽稀、创建日装饰点都不能成为统计依据；缺少覆盖时宁可留空，也不补造零值。
//

import Foundation

/// 四个整刻度区间；50,511 对应 0 / 15K / 30K / 45K / 60K。
struct ReadmeStarHistoryAxis: Equatable {
    let step: Double
    var maximum: Double { step * 4 }
    var ticks: [Double] { (0...4).map { Double($0) * step } }

    init(peak: Int) {
        let target = max(1, Double(peak) / 4)
        let magnitude = pow(10, floor(log10(target)))
        // 1.5 与 7.5 让四分区间也能得到 60K / 300K 等自然上限。
        let candidates = [1.0, 1.5, 2, 2.5, 3, 4, 5, 7.5, 10]
        let multiplier = candidates.first { $0 * magnitude >= target } ?? 10
        step = max(1, ceil(multiplier * magnitude))
    }
}

/// 四卡中的增长读数。精度说明只进入悬停提示，不能隐藏负增长或把除零显示为无穷大。
struct ReadmeStarHistoryMetrics {
    let ageDays: Int?
    let growth: Int?
    let growthRate: Double?
    let sinceCreated: Bool
    let periodDays: Int?
    let isEstimated: Bool

    /// 与新增数共用同一统计窗口；不足一天时留空，不能用强制补成一天的分母夸大速度。
    var dailyAverage: Double? {
        guard let growth, let periodDays, periodDays > 0 else { return nil }
        return Double(growth) / Double(periodDays)
    }

    init(snapshot: StarHistorySnapshot, createdAt: Date?, now: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        ageDays = createdAt.flatMap { created -> Int? in
            guard created <= now else { return nil }
            return calendar.dateComponents([.day], from: calendar.startOfDay(for: created),
                                           to: calendar.startOfDay(for: now)).day
        }

        let points = snapshot.points.filter { $0.count >= 0 }.sorted { $0.date < $1.date }
        guard let latest = points.last else {
            growth = nil; growthRate = nil; sinceCreated = false
            periodDays = nil; isEstimated = true
            return
        }
        let cutoff = latest.date.addingTimeInterval(-90 * 86_400)
        let recentCreation = createdAt.flatMap { $0 > cutoff && $0 <= latest.date ? $0 : nil }
        let createdInsideWindow = recentCreation != nil
        sinceCreated = createdInsideWindow
        let start = recentCreation ?? cutoff
        periodDays = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                            to: calendar.startOfDay(for: latest.date)).day
        let baseline = points.last { $0.date <= cutoff }
        let startingCount = createdInsideWindow ? 0 : baseline?.count
        // 只在仓库确实于窗口内创建时采用 0；老仓缺少期初历史时不能假定 0。
        guard start < latest.date,
              let baselineCount = startingCount,
              snapshot.coverageStart.map({ $0 <= cutoff }) != false || createdInsideWindow
        else {
            growth = nil; growthRate = nil; isEstimated = true
            return
        }
        growth = latest.count - baselineCount
        growthRate = baselineCount > 0 ? Double(latest.count - baselineCount) / Double(baselineCount) : nil
        // 稀疏本地快照不能证明目标日的精确值，向前沿用时仍标记估算。
        isEstimated = latest.precision != .snapshot || (!createdInsideWindow && (
            baseline?.precision != .snapshot || baseline?.date != cutoff
        ))
    }
}
