//
//  RateLimitInfo.swift
//  Starcat
//
//  GitHub Rate Limit 响应头解析。
//
//  GitHub 在每个 API 响应里附带：
//    X-RateLimit-Limit: 5000
//    X-RateLimit-Remaining: 4999
//    X-RateLimit-Reset: 1700000000     # Unix 秒
//    X-RateLimit-Resource: core | search | graphql ...
//
//  我们关心 remaining 和 reset，用于决定是否退避以及何时重试。
//

import Foundation

/// Rate Limit 快照。
struct RateLimitInfo: Equatable {
    /// 当前窗口配额。
    let limit: Int?
    /// 剩余次数。
    let remaining: Int?
    /// 重置时间。
    let reset: Date?

    /// 距离 reset 还有多少秒；reset 在过去或缺失时返回 0。
    func retryAfter(reference now: Date = Date()) -> TimeInterval {
        guard let reset else { return 0 }
        return max(0, reset.timeIntervalSince(now))
    }

    /// 从 HTTPURLResponse 解析。
    static func parse(_ response: HTTPURLResponse) -> RateLimitInfo {
        let limit = response.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap(Int.init)
        let remaining = response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init)
        let resetEpoch = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
        let resetDate = resetEpoch.map { Date(timeIntervalSince1970: $0) }
        return RateLimitInfo(limit: limit, remaining: remaining, reset: resetDate)
    }

    /// 当前是否已耗尽配额。
    var isExhausted: Bool {
        remaining == 0
    }
}
