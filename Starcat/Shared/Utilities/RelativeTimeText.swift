//
//  RelativeTimeText.swift
//  Starcat
//
//  用户可见的相对时间文案统一入口。
//
//  背景：
//  `RelativeDateTimeFormatter` / SwiftUI `.relative` 在时间戳非常接近当前时间时，
//  可能因为渲染时钟与写入时钟的细微差值输出“0 秒后”。这种文案对“上次刷新 /
//  上次同步 / 上次运行”没有产品意义，应该统一显示“刚刚”。
//
//  关键约束：
//  - 已发生的事件：60 秒内统一显示 `relative.justNow`，避免各入口各自写阈值。
//  - 未来 deadline：保留“X 秒后”的语义，只把 0 秒边界兜底成“刚刚”。
//  - formatter 必须显式注入 SwiftUI `\.locale`，否则会回到系统语言。
//

import Foundation

/// Starcat 内所有“相对当前时间”的用户文案 helper。
///
/// 这里不是日期解析器，只接收已经解析好的 `Date`；ISO8601 的兼容解析仍由各自
/// 调用点保留，因为不同 API 返回格式并不完全一致。
enum RelativeTimeText {

    /// 已发生事件的“刚刚”窗口。
    ///
    /// 60 秒内显示“刚刚”比“42 秒前”更符合刷新/同步类状态的用户心智；超过 60 秒后
    /// 再交给系统 formatter 输出分钟、小时、天等相对文案。
    private static let recentPastThreshold: TimeInterval = 60

    /// 未来 deadline 的 0 秒保护窗口。
    ///
    /// 真正的未来 deadline（如 rate limit retryAt）需要保留“30 秒后”，所以这里不能用
    /// 60 秒阈值，只兜住 formatter 会显示“0 秒后”的瞬时边界。
    private static let zeroBoundaryThreshold: TimeInterval = 1

    /// 格式化已发生事件，如“上次刷新”“上次同步”“发布时间”。
    ///
    /// - Parameters:
    ///   - date: 事件时间。
    ///   - now: 当前时间，默认 `Date()`；测试可注入固定时间。
    ///   - locale: SwiftUI 环境里的 locale，用于跟随 Starcat 内语言切换。
    ///   - unitsStyle: `RelativeDateTimeFormatter` 的单位风格。
    /// - Returns: 60 秒内或时间戳意外落到未来时返回“刚刚”，否则返回系统相对时间。
    static func pastEvent(
        _ date: Date,
        relativeTo now: Date = Date(),
        locale: Locale,
        unitsStyle: RelativeDateTimeFormatter.UnitsStyle = .short
    ) -> String {
        let delta = date.timeIntervalSince(now)
        if delta >= -recentPastThreshold {
            return String.l10n("relative.justNow")
        }
        return formatted(date, relativeTo: now, locale: locale, unitsStyle: unitsStyle)
    }

    /// 格式化未来 deadline，如“限流，X 后重试”。
    ///
    /// - Returns: 只在接近 0 秒时返回“刚刚”，其它未来时间仍保留“X 后”。
    static func futureDeadline(
        _ date: Date,
        relativeTo now: Date = Date(),
        locale: Locale,
        unitsStyle: RelativeDateTimeFormatter.UnitsStyle = .short
    ) -> String {
        let delta = date.timeIntervalSince(now)
        if abs(delta) < zeroBoundaryThreshold {
            return String.l10n("relative.justNow")
        }
        return formatted(date, relativeTo: now, locale: locale, unitsStyle: unitsStyle)
    }

    /// 某个未来 deadline 是否已经进入“马上可重试”的边界。
    ///
    /// 供调用方切换完整句式，避免出现“刚刚 后重试”这类拼接不自然的问题。
    static func isImmediateDeadline(_ date: Date, relativeTo now: Date = Date()) -> Bool {
        abs(date.timeIntervalSince(now)) < zeroBoundaryThreshold
    }

    private static func formatted(
        _ date: Date,
        relativeTo now: Date,
        locale: Locale,
        unitsStyle: RelativeDateTimeFormatter.UnitsStyle
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = unitsStyle
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
