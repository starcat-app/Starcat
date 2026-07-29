//
//  WidgetTimelineRefreshPolicy.swift
//  Starcat
//
//  App 与 Widget Extension 共用的纯 Timeline 刷新时间策略。
//
//  纯 Foundation 实现让测试无需链接 WidgetKit，也能直接验证 ready / 非 ready
//  和本地日期边界；系统仍可自行延后实际刷新时间。
//

import Foundation

enum WidgetTimelineKind: Equatable, Sendable {
    case standard
    case rediscovery
}

enum WidgetTimelineRefreshPolicy {
    private static let readyRefreshInterval: TimeInterval = 30 * 60
    private static let recoveryRefreshInterval: TimeInterval = 60 * 60

    static func nextRefresh(
        after date: Date,
        isReady: Bool,
        kind: WidgetTimelineKind,
        calendar: Calendar = .current
    ) -> Date {
        guard isReady else {
            return date.addingTimeInterval(recoveryRefreshInterval)
        }

        switch kind {
        case .standard:
            return date.addingTimeInterval(readyRefreshInterval)
        case .rediscovery:
            // 00:05 而不是午夜整点，避开系统日期切换和其它日任务的集中刷新窗口。
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date),
                  let nextStart = calendar.date(
                      bySettingHour: 0,
                      minute: 5,
                      second: 0,
                      of: tomorrow
                  ) else {
                return date.addingTimeInterval(readyRefreshInterval)
            }
            return nextStart
        }
    }
}
