//
//  WidgetTimelineRefreshPolicyTests.swift
//  StarcatTests
//
//  Widget Timeline 纯刷新策略测试，覆盖 ready、恢复态和本地次日边界。
//

import Foundation
import Testing
@testable import Starcat

@Suite("WidgetTimelineRefreshPolicy")
struct WidgetTimelineRefreshPolicyTests {

    @Test("ready 普通组件三十分钟后请求刷新")
    func schedulesStandardReadyRefresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let next = WidgetTimelineRefreshPolicy.nextRefresh(
            after: now,
            isReady: true,
            kind: .standard
        )

        #expect(next.timeIntervalSince(now) == 30 * 60)
    }

    @Test("所有非 ready 状态统一一小时后重试")
    func schedulesRecoveryRefresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        for kind in [WidgetTimelineKind.standard, .rediscovery] {
            let next = WidgetTimelineRefreshPolicy.nextRefresh(
                after: now,
                isReady: false,
                kind: kind
            )
            #expect(next.timeIntervalSince(now) == 60 * 60)
        }
    }

    @Test("ready 今日重逢在本地次日零点零五分刷新")
    func schedulesRediscoveryAtNextLocalDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 30,
                    hour: 23,
                    minute: 40
                )
            )
        )
        let expected = try #require(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 7,
                    day: 31,
                    hour: 0,
                    minute: 5
                )
            )
        )

        let next = WidgetTimelineRefreshPolicy.nextRefresh(
            after: now,
            isReady: true,
            kind: .rediscovery,
            calendar: calendar
        )

        #expect(next == expected)
    }
}
