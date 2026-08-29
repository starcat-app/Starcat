//
//  StarHistoryCurveBuilder.swift
//  Starcat
//
//  把 history-api 返回的原始日事件校准成洞察图表点。
//
//  为什么放在客户端：
//  - Starcat 本地已有 Repo.starsCount（详情页 hero 同源），不必再让服务端打 GitHub；
//  - 算法与 starcat-history-api/internal/series.Normalize + SelectRange 对齐，
//    保证第三方走旧接口、Starcat 走 events 接口时口径一致。
//

import Foundation

enum StarHistoryCurveBuilder {
    static let defaultMaximumPoints = 400

    struct DailyEvent: Equatable, Sendable {
        let date: Date
        let count: Int
    }

    /// 将 WatchEvent 日计数按当前星标数校准成单调估算曲线。
    /// 最后一个点强制等于 `currentStars`，与服务端 Normalize 行为一致。
    static func normalize(
        events: [DailyEvent],
        currentStars: Int,
        fetchedAt: Date
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
                    source: .ghArchive,
                    precision: .estimated,
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

    /// 与服务端 SelectRange 对齐：3m 按日、1y 按 ISO 周、all 按月；超上限等距抽稀。
    static func selectRange(
        _ points: [StarHistoryPoint],
        range: StarHistoryRange,
        now: Date = Date(),
        maximum: Int = defaultMaximumPoints
    ) -> [StarHistoryPoint] {
        let limit = maximum > 0 ? maximum : defaultMaximumPoints
        let sorted = points.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else { return [] }

        let calendar = Calendar(identifier: .iso8601)
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let cutoff: Date?
        let bucket: (Date) -> String
        switch range {
        case .threeMonths:
            cutoff = utcCalendar.date(byAdding: .month, value: -3, to: startOfUTCDay(now, calendar: utcCalendar))
            bucket = { StarHistoryDateCodec.dayString(from: $0) }
        case .oneYear:
            cutoff = utcCalendar.date(byAdding: .year, value: -1, to: startOfUTCDay(now, calendar: utcCalendar))
            bucket = { date in
                let week = utcCalendar.component(.weekOfYear, from: date)
                let year = utcCalendar.component(.yearForWeekOfYear, from: date)
                return String(format: "%04d-W%02d", year, week)
            }
        case .all:
            cutoff = nil
            bucket = { date in
                let comps = utcCalendar.dateComponents([.year, .month], from: date)
                return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            }
        }

        var grouped: [StarHistoryPoint] = []
        var lastBucket = ""
        for point in sorted {
            if let cutoff, point.date < cutoff {
                continue
            }
            let key = bucket(point.date)
            if key == lastBucket, !grouped.isEmpty {
                grouped[grouped.count - 1] = point
            } else {
                grouped.append(point)
                lastBucket = key
            }
        }

        guard grouped.count > limit else { return grouped }
        var result: [StarHistoryPoint] = []
        result.reserveCapacity(limit)
        for index in 0..<limit {
            let sourceIndex = index * (grouped.count - 1) / (limit - 1)
            result.append(grouped[sourceIndex])
        }
        return result
    }

    private static func startOfUTCDay(_ date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: comps) ?? date
    }
}
