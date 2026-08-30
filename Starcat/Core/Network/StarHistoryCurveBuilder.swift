//
//  StarHistoryCurveBuilder.swift
//  Starcat
//
//  把 history-api 返回的原始日事件校准成洞察图表点。
//
//  为什么放在客户端：
//  - Starcat 本地已有 Repo.starsCount（详情页 hero 同源），不必再让服务端打 GitHub；
//  - 校准公式与 starcat-history-api/internal/series.Normalize 对齐；范围选择由
//    Starcat 的完整日级 canonical cache 独立负责，不受第三方兼容接口点数上限影响。
//

import Foundation

enum StarHistoryCurveBuilder {
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

    /// 把远端重建历史与本机精确快照收敛成一次性精度交接。
    ///
    /// 远端曲线使用“当前 Star 数”校准，如果继续让它穿过更早写入的本机快照，
    /// 两条时间序列会在同一日期范围反复交叉，形成不存在的下降虚线和尖峰。
    /// 因此这里使用第一个精确快照作为锚点：
    /// - 锚点之前保留远端形状，并按锚点值等比例重新校准；
    /// - 锚点开始只保留精确快照；
    /// - 没有精确快照时保持原远端序列。
    static func stitchToPreciseSnapshots(_ points: [StarHistoryPoint]) -> [StarHistoryPoint] {
        let sorted = points.sorted { $0.date < $1.date }
        let precise = sorted.filter { $0.precision == .snapshot }
        guard let anchor = precise.first else { return sorted }

        let historical = sorted.filter {
            $0.precision != .snapshot && $0.date < anchor.date
        }
        guard let historicalAnchor = historical.last else { return precise }

        let adjustedHistorical: [StarHistoryPoint]
        if historicalAnchor.count == 0 {
            // 远端锚点和精确锚点都为零时保留零值历史；否则没有可解释的比例可用。
            adjustedHistorical = anchor.count == 0 ? historical : []
        } else {
            adjustedHistorical = historical.map { point in
                let scaled = Int(
                    (Double(anchor.count) * Double(point.count) / Double(historicalAnchor.count))
                        .rounded()
                )
                return StarHistoryPoint(
                    date: point.date,
                    count: min(max(0, scaled), anchor.count),
                    source: point.source,
                    precision: point.precision,
                    fetchedAt: point.fetchedAt
                )
            }
        }
        return adjustedHistorical + precise
    }

    /// 3m 保留日级点；1y 只压缩远端估算点并保留全部精确快照；all 保留全部日级点。
    ///
    /// `/events` 最多每天一个点，当前十年覆盖约 3,900 点。`all` 不再按月丢点，
    /// 让“存在 WatchEvent 的日期就有图表点”成为稳定的数据契约。
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

            var lastRemoteByWeek: [String: StarHistoryPoint] = [:]
            var precise: [StarHistoryPoint] = []
            for point in filtered {
                if point.precision == .snapshot {
                    precise.append(point)
                    continue
                }
                let week = utcCalendar.component(.weekOfYear, from: point.date)
                let year = utcCalendar.component(.yearForWeekOfYear, from: point.date)
                lastRemoteByWeek[String(format: "%04d-W%02d", year, week)] = point
            }
            return (Array(lastRemoteByWeek.values) + precise)
                .sorted { $0.date < $1.date }
        case .all:
            return sorted
        }
    }

    private static func startOfUTCDay(_ date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return calendar.date(from: comps) ?? date
    }
}
