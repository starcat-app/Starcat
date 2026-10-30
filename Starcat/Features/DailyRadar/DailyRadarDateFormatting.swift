//
//  DailyRadarDateFormatting.swift
//  Starcat
//
//  日报展示业务日期，不随用户所在时区改变；格式仍采用用户界面 Locale。
//

import Foundation

enum DailyRadarDateFormatting {
    static func label(_ businessDate: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: businessDate) else { return businessDate }
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMMd")
        return formatter.string(from: date)
    }
}
