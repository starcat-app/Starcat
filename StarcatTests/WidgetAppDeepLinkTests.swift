//
//  WidgetAppDeepLinkTests.swift
//  StarcatTests
//
//  Widget 空态内部路由测试：覆盖生成、解析和非法 URL 拒绝。
//

import Foundation
import Testing
@testable import Starcat

@Suite("WidgetAppDeepLink")
struct WidgetAppDeepLinkTests {

    @Test("生成并解析主窗口、Release 时间线与我的洞察路由")
    func roundTripsSupportedDestinations() {
        let main = WidgetAppDeepLink(destination: .main)
        let releases = WidgetAppDeepLink(destination: .releaseTimeline)
        let insights = WidgetAppDeepLink(destination: .insights)

        #expect(main.url.absoluteString == "starcat://app/open?v=1")
        #expect(releases.url.absoluteString == "starcat://app/releases?v=1")
        #expect(insights.url.absoluteString == "starcat://app/insights?v=1")
        #expect(WidgetAppDeepLink(url: main.url) == main)
        #expect(WidgetAppDeepLink(url: releases.url) == releases)
        #expect(WidgetAppDeepLink(url: insights.url) == insights)
    }

    @Test("拒绝裸 scheme、错误 host/path/version 与重复参数")
    func rejectsInvalidRoutes() throws {
        let rawURLs = [
            "starcat://",
            "https://app/open?v=1",
            "starcat://other/open?v=1",
            "starcat://app/unknown?v=1",
            "starcat://app/open",
            "starcat://app/open?v=2",
            "starcat://app/open?v=1&v=1",
            "starcat://app/open?v=1&next=https://example.com",
            "starcat://app/open/extra?v=1",
        ]

        for rawURL in rawURLs {
            let url = try #require(URL(string: rawURL))
            #expect(WidgetAppDeepLink(url: url) == nil)
        }
    }
}
