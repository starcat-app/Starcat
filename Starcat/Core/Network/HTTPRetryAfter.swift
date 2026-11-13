//
//  HTTPRetryAfter.swift
//  Starcat
//
//  统一解析 Retry-After，避免搜索客户端遗漏 HTTP 日期而立即重复请求。
//

import Foundation

/// HTTP 的等待时间可以是秒数或绝对日期；调用方保留各自的限流策略。
enum HTTPRetryAfter {
    /// 显式时钟使 HTTP 日期可测试；无效或非有限值不进入计时器。
    static func seconds(from value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) {
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
