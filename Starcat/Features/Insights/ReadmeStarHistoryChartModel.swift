//
//  ReadmeStarHistoryChartModel.swift
//  Starcat
//
//  README 历史卡片的整刻度、90 天指标与成长事件。只消费完整读模型，不改写历史数据。
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

/// 四卡中的增长读数。保留精度元数据，展示层不添加精度文案；不能隐藏负增长或把除零显示为无穷大。
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
        // 官方历史是稀疏事件序列；期初点非目标日时，增长值仍属向前沿用的估算。
        isEstimated = !createdInsideWindow && baseline?.date != cutoff
    }
}

/// 从完整历史提取成长事件；阈值只是事件名称，点的位置和读数始终来自原序列。
/// 创建日绘图补点不参与计算。事件随数据修订重新生成，不把估算日期固化成永久事实。
struct ReadmeStarJourney {
    enum Kind: String {
        case created, firstRecorded, milestone, bestDay, bestWeek, spike, current
    }

    struct Event: Identifiable {
        let kind: Kind
        let date: Date?
        let point: StarHistoryPoint?
        var threshold: Int? = nil
        var previous: StarHistoryPoint? = nil
        var growth: Int? = nil
        var windowStart: Date? = nil

        var id: String { kind == .milestone ? "milestone-\(threshold ?? 0)" : kind.rawValue }
        var priority: Double {
            switch kind {
            case .current: return 1_000
            case .created: return 900
            case .spike: return 100
            case .firstRecorded: return 76
            case .bestWeek: return 72
            case .bestDay: return 68
            case .milestone:
                let value = Double(max(1, threshold ?? 1))
                return abs(log10(value) - log10(value).rounded()) < 0.0001 ? 82 : 58
            }
        }
    }

    /// 按保留优先级排列；UI 取前 N 个后再按时间显示，缩窗与放宽不会改变事件口径。
    let rankedEvents: [Event]
    let chartEvents: [Event]
    let currentCount: Int

    init(snapshot: StarHistorySnapshot, repo: Repo) {
        let points = snapshot.points.filter { $0.count >= 0 }.sorted { $0.date < $1.date }
        let created = repo.createdAt.flatMap(ISO8601DateFormatter.githubDate(from:))
        let latest = points.last
        let count = latest?.count ?? max(0, repo.starsCount)
        currentCount = count
        let currentDate = latest?.date ?? repo.cachedAt.flatMap(ISO8601DateFormatter.githubDate(from:))
        var current = Event(kind: .current, date: currentDate, point: latest)
        var events: [Event] = []
        // 历史点按 UTC 日存储，创建时间却含时分秒；同一天不能因午夜点更早而丢失 Created。
        if let created, currentDate.map({ floor(created.timeIntervalSince1970 / 86_400) <= floor($0.timeIntervalSince1970 / 86_400) }) != false {
            events.append(Event(kind: .created, date: created, point: nil))
        }
        // 首条 GH Archive 记录即使校准后四舍五入为 0，也仍代表一个曾被记录的事件日。
        // 它不能证明整个项目的 First Star，因此文案明确为 First Recorded Star。
        if count > 0,
           let first = points.first(where: { $0.source == .githubHistory }),
           first.id != latest?.id {
            events.append(Event(kind: .firstRecorded, date: first.date, point: first))
        }
        for threshold in Self.thresholds(for: count) {
            // 首条记录已在阈值之上时，无法确定首次跨越；之后回落再越过也不能冒充首次。
            guard let first = points.first, first.count < threshold,
                  let index = points.indices.dropFirst().first(where: {
                points[$0 - 1].count < threshold && points[$0].count >= threshold
            }) else { continue }
            let point = points[index]
            // 同一点跨过多个阈值只保留最高一个；当前点也承担该里程碑，不生成重叠节点。
            if point.id == latest?.id {
                current.threshold = threshold
                current.previous = points[index - 1]
            } else {
                events.removeAll { $0.kind == .milestone && $0.point?.id == point.id }
                events.append(Event(kind: .milestone, date: point.date, point: point,
                                    threshold: threshold, previous: points[index - 1]))
            }
        }
        if let growth = Self.growthEvent(points: points, coverage: snapshot.coverage, total: count) {
            events.append(growth)
        }
        events.append(current)
        rankedEvents = Array(Self.ranked(events).prefix(7))
        let chartCandidates = events.filter {
            $0.kind == .current || $0.kind == .milestone || $0.kind == .spike
                || (count < 10 && $0.kind == .firstRecorded && ($0.point?.count ?? 0) > 0)
        }
        chartEvents = Array(Self.ranked(chartCandidates).prefix(4))
    }

    /// 数量级决定候选集合；是否达到仍检查历史，回落后的旧里程碑不会被误当成未来目标。
    private static func thresholds(for count: Int) -> [Int] {
        switch count {
        case ..<10: return [1, 3, 5, 10]
        case ..<100: return [10, 25, 50, 100]
        case ..<1_000: return [10, 100, 250, 500, 1_000]
        case ..<10_000: return [1_000, 2_500, 5_000, 10_000]
        case ..<100_000: return [1_000, 10_000, 25_000, 50_000, 100_000]
        default:
            let scale = pow(10, floor(log10(Double(count))))
            return [0.1, 1, 2.5, 5, 10].compactMap {
                let value = scale * $0
                return value < Double(Int.max) ? Int(value) : nil
            }
        }
    }

    /// 同等重要时优先填补时间空档；日期只影响选择，不决定横向像素距离。
    private static func ranked(_ events: [Event]) -> [Event] {
        var remaining = events
        var selected: [Event] = []
        let dates = events.compactMap(\.date)
        let duration = max(1, (dates.max() ?? .distantPast).timeIntervalSince(dates.min() ?? .distantPast))
        while !remaining.isEmpty {
            func score(_ event: Event) -> Double {
                guard let date = event.date, !selected.isEmpty else { return event.priority }
                let distance = selected.compactMap(\.date).map { abs(date.timeIntervalSince($0)) }.min() ?? 0
                return event.priority + min(1, distance / duration) * 32
            }
            let index = remaining.indices.max { score(remaining[$0]) < score(remaining[$1]) }!
            selected.append(remaining.remove(at: index))
        }
        return selected
    }

    /// 只计算同口径、可证明连续覆盖的段。GH Archive 缺事件日是零新增；快照缺日期则断段。
    /// 最佳周使用 7 个 UTC 日；Spike 还要求此前 28 日基线，不能把采样间距或来源交接当爆发。
    private static func growthEvent(points: [StarHistoryPoint], coverage: StarHistoryCoverage?, total: Int) -> Event? {
        func day(_ point: StarHistoryPoint) -> Int { Int(floor(point.date.timeIntervalSince1970 / 86_400)) }
        func connects(_ previous: StarHistoryPoint, _ next: StarHistoryPoint) -> Bool {
            guard previous.source == next.source, previous.precision == next.precision,
                  day(next) > day(previous) else { return false }
            guard previous.source == .githubHistory,
                  let coverage,
                  let start = coverage.start,
                  let end = coverage.dataThrough, previous.fetchedAt == coverage.generatedAt,
                  next.fetchedAt == coverage.generatedAt else { return false }
            return previous.date >= start && next.date <= end
        }
        var segments: [[StarHistoryPoint]] = []
        for point in points {
            if let previous = segments.last?.last, connects(previous, point) {
                segments[segments.count - 1].append(point)
            } else {
                segments.append([point])
            }
        }
        var bestDay: Event?, bestWeek: Event?, spike: Event?
        let dayMinimum = max(3, Int(ceil(Double(total) * 0.01)))
        let weekMinimum = max(5, Int(ceil(Double(total) * 0.02)))
        let spikeMinimum = max(10, Int(ceil(Double(total) * 0.05)))
        for segment in segments where segment.count > 1 {
            /// 稀疏事件段的累计值按日向前延续，不通过线性插值摊平增长。
            func value(at targetDay: Int) -> Int? {
                guard targetDay >= day(segment[0]) else { return nil }
                var low = 0, high = segment.count
                while low < high {
                    let middle = (low + high) / 2
                    if day(segment[middle]) <= targetDay { low = middle + 1 } else { high = middle }
                }
                return segment[low - 1].count
            }
            for index in segment.indices.dropFirst() {
                let point = segment[index], end = day(point)
                let daily = point.count - segment[index - 1].count
                if daily >= dayMinimum, daily > (bestDay?.growth ?? 0) {
                    bestDay = Event(kind: .bestDay, date: point.date, point: point, growth: daily,
                                    windowStart: Date(timeIntervalSince1970: Double(end - 1) * 86_400))
                }
                guard let baseline = value(at: end - 7) else { continue }
                let weekly = point.count - baseline
                if weekly >= weekMinimum, weekly > (bestWeek?.growth ?? 0) {
                    bestWeek = Event(kind: .bestWeek, date: point.date, point: point, growth: weekly,
                                     windowStart: Date(timeIntervalSince1970: Double(end - 7) * 86_400))
                }
                if let earlier = value(at: end - 35), weekly >= spikeMinimum,
                   Double(weekly) >= Double(max(0, baseline - earlier)) / 4 * 3,
                   weekly > (spike?.growth ?? 0) {
                    spike = Event(kind: .spike, date: point.date, point: point, growth: weekly,
                                  windowStart: Date(timeIntervalSince1970: Double(end - 7) * 86_400))
                }
            }
        }
        if let spike { return spike }
        // 增长几乎集中在一天时，Best Day 比把同一次增长包装成 Best Week 更有解释力。
        if let bestWeek, Double(bestWeek.growth ?? 0) >= Double(bestDay?.growth ?? 0) * 1.5 { return bestWeek }
        return bestDay
    }
}
