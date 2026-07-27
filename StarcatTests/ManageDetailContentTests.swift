//
//  ManageDetailContentTests.swift
//  StarcatTests
//
//  验证主详情与独立详情共同复用的 README / 洞察模式切换契约。
//

import Testing
@testable import Starcat

@Suite("仓库详情模式切换")
struct ManageDetailContentTests {

    @Test("详情默认进入 README，避免首屏额外请求洞察")
    func defaultModeUsesReadme() {
        let mode = ManageDetailContentMode.readme

        #expect(mode == .readme)
        #expect(mode.transitionEffect == .cancelInsights)
    }

    @Test("进入洞察时重置 Hero 滚动位置")
    func insightsModeResetsScroll() {
        #expect(ManageDetailContentMode.insights.transitionEffect == .resetScroll)
    }

    @Test("返回 README 时取消洞察后台请求")
    func readmeModeCancelsInsights() {
        #expect(ManageDetailContentMode.readme.transitionEffect == .cancelInsights)
    }
}
