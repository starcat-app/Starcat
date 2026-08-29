//
//  StarHistoryShareCaptureTests.swift
//  StarcatTests
//
//  锁定 Star 趋势导出态要藏哪些 chrome，避免截图把操作按钮或帮助链接带出去。
//

import Testing
@testable import Starcat

@Suite("Star history share capture chrome")
struct StarHistoryShareCaptureTests {

    @Test("屏幕态保留分享、刷新和限制说明，不重复仓库身份")
    func onScreenShowsInteractiveChrome() {
        #expect(StarHistoryShareCaptureChrome.showsActionButtons(false))
        #expect(StarHistoryShareCaptureChrome.showsChartSelection(false))
        #expect(!StarHistoryShareCaptureChrome.showsRepositoryIdentity(false))
        #expect(
            StarHistoryShareCaptureChrome.showsRestrictionLink(false, allowedByPolicy: true)
        )
    }

    @Test("导出态藏掉操作按钮、悬停读数和帮助链接，并带上仓库身份")
    func captureHidesInteractiveChrome() {
        #expect(!StarHistoryShareCaptureChrome.showsActionButtons(true))
        #expect(!StarHistoryShareCaptureChrome.showsChartSelection(true))
        #expect(StarHistoryShareCaptureChrome.showsRepositoryIdentity(true))
        #expect(
            !StarHistoryShareCaptureChrome.showsRestrictionLink(true, allowedByPolicy: true)
        )
    }

    @Test("策略本身不展示时，屏幕态也不画限制链接")
    func restrictionLinkStillRespectsPolicy() {
        #expect(
            !StarHistoryShareCaptureChrome.showsRestrictionLink(false, allowedByPolicy: false)
        )
    }
}
