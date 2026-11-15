//
//  RecommendationHistoryDates.swift
//  Starcat
//
//  推荐时间是首次展示的事实，独立于 Star 时间与仓库更新日。侧栏显示最近五个自然日
//  内有记录的日期，更早日期可展开；总入口始终保留全部历史。
//

import Foundation

/// 日期筛选与反馈、搜索正交，不复用其它探索分类的语言或主题选择。
enum RecommendationHistoryDateScope: Hashable {
    case all
    case day(String)
    case unknown

    var identity: String {
        switch self {
        case .all: "all"
        case .day(let day): "day:\(day)"
        case .unknown: "unknown"
        }
    }

    func includes(_ entry: RecommendationHistoryEntry) -> Bool {
        switch self {
        case .all: true
        case .day(let day): entry.historyDay == day
        case .unknown: entry.historyDay == nil
        }
    }

    func title(locale: Locale) -> String {
        switch self {
        case .all: return String.l10n("recommendations.history.all")
        case .unknown: return String.l10n("recommendations.history.unknownDate")
        case .day(let day):
            return RecommendationHistoryDates.date(day)?.formatted(.dateTime.year().month().day().locale(locale)) ?? day
        }
    }
}

/// 只有存在历史的日期才占侧栏行，最近五天不被误解为只保留五天历史。
struct RecommendationHistoryDates {
    struct Group: Identifiable {
        let day: String
        let count: Int
        var id: String { day }
    }
    let recent: [Group]
    let older: [Group]
    let unknownCount: Int

    init(entries: [RecommendationHistoryEntry], now: Date = Date(), timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let cutoff = calendar.date(byAdding: .day, value: -4, to: calendar.startOfDay(for: now)) ?? now
        let oldestRecent = RecommendationHistoryRepository.sortDay(DailyRecommendationState.dayKey(cutoff, timeZone: timeZone))
        let today = RecommendationHistoryRepository.sortDay(DailyRecommendationState.dayKey(now, timeZone: timeZone))
        var counts: [String: Int] = [:]
        var unknown = 0
        for entry in entries {
            if let day = entry.historyDay(timeZone: timeZone) { counts[day, default: 0] += 1 }
            else { unknown += 1 }
        }
        let groups = counts.map { Group(day: $0.key, count: $0.value) }.sorted {
            RecommendationHistoryRepository.sortDay($0.day) > RecommendationHistoryRepository.sortDay($1.day)
        }
        recent = groups.filter {
            let value = RecommendationHistoryRepository.sortDay($0.day)
            return value >= oldestRecent && value <= today
        }
        let recentIDs = Set(recent.map(\.id))
        older = groups.filter { !recentIDs.contains($0.id) }
        unknownCount = unknown
    }

    /// 拒绝非法日期，不能把缺失或无效的旧时间编造成今天。
    static func date(_ day: String, timeZone: TimeZone = .current) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == parts[0], actual.month == parts[1], actual.day == parts[2] else { return nil }
        return date
    }
}

extension RecommendationHistoryEntry {
    /// day 保留推荐当时的日历分组；只有缺 day 时才从真实时间戳推导。
    var historyDay: String? {
        historyDay(timeZone: .current)
    }

    func historyDay(timeZone: TimeZone) -> String? {
        if let day = recommendedDay, let date = RecommendationHistoryDates.date(day, timeZone: timeZone) {
            return DailyRecommendationState.dayKey(date, timeZone: timeZone)
        }
        return recommendedAt.map { DailyRecommendationState.dayKey($0, timeZone: timeZone) }
    }
}
