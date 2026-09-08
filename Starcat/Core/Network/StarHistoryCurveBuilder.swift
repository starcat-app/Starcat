//
//  StarHistoryCurveBuilder.swift
//  Starcat
//
//  把远端返回的原始日增量校准成洞察图表点。
//
//  为什么放在客户端：
//  - Starcat 本地已有 Repo.starsCount（详情页 hero 同源），不必再让服务端打 GitHub；
//  - GitHub 官方周级历史是唯一事实源，客户端只负责累计与范围抽样；
//  - 范围选择由 Starcat 的完整日级 canonical cache 独立负责。
//

import Foundation

enum StarHistoryCurveBuilder {
    struct DailyEvent: Equatable, Sendable {
        let date: Date
        let count: Int
    }

    /// 将日增量按当前星标数校准成单调曲线。
    /// 最后一个点强制等于 `currentStars`；来源和精度由调用方显式标记，
    /// 避免 GitHub 官方历史被误存为旧 GH Archive 估算数据。
    static func normalize(
        events: [DailyEvent],
        currentStars: Int,
        fetchedAt: Date,
        source: StarHistorySource = .githubHistory,
        precision: StarHistoryPrecision = .reconstructed
    ) throws -> [StarHistoryPoint] {
        guard currentStars >= 0 else {
            throw StarHistoryAPIError.decoding("current_stars must not be negative")
        }
        guard !events.isEmpty else { return [] }

        var total: UInt64 = 0
        for event in events {
            guard event.count > 0 else {
                throw StarHistoryAPIError.decoding("event count must be positive")
            }
            total += UInt64(event.count)
        }
        guard total > 0 else { return [] }

        var points: [StarHistoryPoint] = []
        points.reserveCapacity(events.count)
        var cumulative: UInt64 = 0
        var previous = 0
        for event in events {
            cumulative += UInt64(event.count)
            let numerator = UInt64(currentStars) * cumulative
            var estimated = Int((2 * numerator + total) / (2 * total))
            if estimated < previous {
                estimated = previous
            }
            if estimated > currentStars {
                estimated = currentStars
            }
            points.append(
                StarHistoryPoint(
                    date: event.date,
                    count: estimated,
                    source: source,
                    precision: precision,
                    fetchedAt: fetchedAt
                )
            )
            previous = estimated
        }
        if var last = points.last {
            last = StarHistoryPoint(
                date: last.date,
                count: currentStars,
                source: last.source,
                precision: last.precision,
                fetchedAt: last.fetchedAt
            )
            points[points.count - 1] = last
        }
        return points
    }

    /// 3m 保留日级点；1y 按周压缩官方点；all 保留全部日级点。
    ///
    /// 官方接口最多每天一个非零点。`all` 不再按月丢点，
    /// 让“官方周数据中存在的日期就有图表点”成为稳定数据契约。
    static func selectRange(
        _ points: [StarHistoryPoint],
        range: StarHistoryRange,
        now: Date = Date()
    ) -> [StarHistoryPoint] {
        let sorted = points.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return [] }

        let calendar = Calendar(identifier: .iso8601)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!

        switch range {
        case .threeMonths:
            guard let cutoff = utcCalendar.date(
                byAdding: .month,
                value: -3,
                to: startOfUTCDay(now, calendar: utcCalendar)
            ) else { return sorted }
            return sorted.filter { $0.date >= cutoff }
        case .oneYear:
            guard let cutoff = utcCalendar.date(
                byAdding: .year,
                value: -1,
                to: startOfUTCDay(now, calendar: utcCalendar)
            ) else { return sorted }
            let filtered = sorted.filter { $0.date >= cutoff }
            guard !filtered.isEmpty else { return [] }

            var lastPointByWeek: [String: StarHistoryPoint] = [:]
            for point in filtered {
                let week = utcCalendar.component(.weekOfYear, from: point.date)
                let year = utcCalendar.component(.yearForWeekOfYear, from: point.date)
                lastPointByWeek[String(format: "%04d-W%02d", year, week)] = point
            }
            return lastPointByWeek.values.sorted { $0.date < $1.date }
        case .all:
            return sorted
        }
    }

    private static func startOfUTCDay(_ date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: comps) ?? date
    }
}
