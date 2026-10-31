//
//  DailyRadarDateFormatting.swift
//  Starcat
//
//  日报展示业务日期，不随用户所在时区改变；格式仍采用用户界面 Locale。
//

import Foundation

enum DailyRadarDateFormatting {
    static func label(_ businessDate: String, locale: Locale) -> String {
        guard let date = date(fromBusinessDate: businessDate) else { return businessDate }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        return formatter.string(from: date)
    }

    /// 日报日期是服务端业务字符串；解析失败时返回 nil，由调用方保留无效输入原样展示。
    static func date(fromBusinessDate businessDate: String) -> Date? {
        let parts = businessDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar(for: Locale(identifier: "en_US_POSIX")).date(from: components)
    }

    /// 月历展示仍固定业务时区，避免用户系统时区把日期挪到相邻一天。
    static func calendar(for locale: Locale) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar.firstWeekday = 2
        return calendar
    }

    static func businessDate(from date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

}
