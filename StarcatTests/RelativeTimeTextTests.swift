//
//  RelativeTimeTextTests.swift
//  StarcatTests
//
//  验证用户可见相对时间的近实时边界，避免 UI 出现“0 秒后”。
//

import Foundation
import Testing
@testable import Starcat

// 此 Suite 会临时改写 UserDefaults.standard 的显示语言。必须独占执行，避免同时运行的
// UI/Agent 测试读到中间态语言并把本地化文案误判为功能失败。
@Suite("RelativeTimeText", .serialized)
struct RelativeTimeTextTests {

    private let locale = Locale(identifier: "zh-Hans")

    @Test("已发生事件：当前、轻微未来、60 秒内过去都显示刚刚")
    func pastEventNearNowUsesJustNow() throws {
        try withLocaleOverride("zh-Hans") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)

            #expect(RelativeTimeText.pastEvent(now, relativeTo: now, locale: locale) == "刚刚")
            #expect(RelativeTimeText.pastEvent(now.addingTimeInterval(0.4), relativeTo: now, locale: locale) == "刚刚")
            #expect(RelativeTimeText.pastEvent(now.addingTimeInterval(-30), relativeTo: now, locale: locale) == "刚刚")
        }
    }

    @Test("已发生事件：超过 60 秒后交给相对时间 formatter")
    func pastEventOlderThanThresholdUsesFormatter() throws {
        try withLocaleOverride("zh-Hans") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let text = RelativeTimeText.pastEvent(now.addingTimeInterval(-61), relativeTo: now, locale: locale)

            #expect(text != "刚刚")
            #expect(text.contains("前"))
            #expect(!text.contains("0 秒后"))
        }
    }

    @Test("未来 deadline：只兜底 0 秒边界，保留真实未来语义")
    func futureDeadlineKeepsFutureMeaningExceptZeroBoundary() throws {
        try withLocaleOverride("zh-Hans") {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let immediate = RelativeTimeText.futureDeadline(now.addingTimeInterval(0.2), relativeTo: now, locale: locale)
            let later = RelativeTimeText.futureDeadline(now.addingTimeInterval(30), relativeTo: now, locale: locale)

            #expect(immediate == "刚刚")
            #expect(later != "刚刚")
            #expect(later.contains("后"))
            #expect(!later.contains("0 秒后"))
        }
    }

    /// 临时切换 LocaleStore 的持久化 key，让 `String.l10n("relative.justNow")`
    /// 在测试中稳定返回中文。结束后恢复原值，避免污染其它测试。
    private func withLocaleOverride<T>(_ raw: String, _ body: () throws -> T) throws -> T {
        let defaults = UserDefaults.standard
        let old = defaults.string(forKey: "AppLocaleOverride")
        defaults.set(raw, forKey: "AppLocaleOverride")
        defer {
            if let old {
                defaults.set(old, forKey: "AppLocaleOverride")
            } else {
                defaults.removeObject(forKey: "AppLocaleOverride")
            }
        }
        return try body()
    }
}
