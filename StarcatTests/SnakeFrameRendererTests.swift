//
//  SnakeFrameRendererTests.swift
//  StarcatTests
//
//  验证贡献草坪动画的缓存底图合成与原始完整重绘保持像素级一致。
//  这条契约防止性能优化悄悄改变格子方向、主题颜色或动态覆盖层顺序。
//

import Foundation
import SwiftUI
import Testing
@testable import Starcat

struct SnakeFrameRendererTests {

    @Test("缓存底图合成与完整重绘像素一致")
    func cachedBaseGridMatchesFullRender() throws {
        let payload = ContributionCalendarPayload(
            totalContributions: 7,
            weeks: [
                ContributionWeek(contributionDays: [
                    ContributionDay(
                        date: "2026-09-01",
                        contributionCount: 2,
                        contributionLevel: .firstQuartile,
                        weekday: 1
                    ),
                    ContributionDay(
                        date: "2026-09-02",
                        contributionCount: 5,
                        contributionLevel: .thirdQuartile,
                        weekday: 2
                    )
                ]),
                ContributionWeek(contributionDays: [
                    ContributionDay(
                        date: "2026-09-03",
                        contributionCount: 0,
                        contributionLevel: .none,
                        weekday: 3
                    )
                ])
            ]
        )
        let frame = AnimationFrame(
            snakes: [[GridPosition(col: 51, row: 1), GridPosition(col: 51, row: 2)]],
            eatenCells: [GridPosition(col: 51, row: 2)],
            foodCells: [GridPosition(col: 52, row: 3)]
        )
        let time = Date(timeIntervalSinceReferenceDate: 123_456.25)

        let fullRender = try #require(SnakeFrameRenderer.render(
            payload: payload,
            frame: frame,
            colorScheme: .dark,
            time: time
        ))
        let baseGrid = try #require(SnakeFrameRenderer.renderBaseGrid(
            payload: payload,
            colorScheme: .dark
        ))
        let cachedRender = try #require(SnakeFrameRenderer.render(
            payload: payload,
            frame: frame,
            colorScheme: .dark,
            baseGrid: baseGrid,
            time: time
        ))

        #expect(cachedRender.width == fullRender.width)
        #expect(cachedRender.height == fullRender.height)
        let cachedPixels = try #require(pixelData(of: cachedRender))
        let fullPixels = try #require(pixelData(of: fullRender))
        #expect(cachedPixels == fullPixels)
    }

    /// 比较最终 RGBA 字节，而不是只比较 CGImage 身份或尺寸。
    @Test("玩法首帧就绪后才推进版本，切回关闭时立即提供静态草坪")
    @MainActor
    func styleChangesPublishReadyFrames() async throws {
        let service = SnakeRenderService()
        defer { service.stop() }
        service.configure(animator: nil, payload: nil, colorScheme: .dark)
        let staticRevision = service.readyRevision
        #expect(staticRevision > 0)
        #expect(service.frameImage != nil)

        let animator = try #require(SnakeAnimatorFactory.make(style: .zigzag, weeks: nil))
        service.configure(animator: animator, payload: nil, colorScheme: .dark)
        #expect(service.readyRevision == staticRevision, "后台首帧返回前，旧图片不能充当新玩法就绪")

        // 等真实渲染结果；截止时间只防测试挂起，不参与产品动画的时序。
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.readyRevision == staticRevision, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.readyRevision > staticRevision)
        #expect(service.frameImage != nil)

        let animatedRevision = service.readyRevision
        service.configure(animator: nil, payload: nil, colorScheme: .light)
        #expect(service.readyRevision > animatedRevision)
        let expectedGrid = try #require(SnakeFrameRenderer.renderBaseGrid(
            payload: nil,
            colorScheme: .light
        ))
        let displayedGrid = try #require(service.frameImage)
        #expect(pixelData(of: displayedGrid) == pixelData(of: expectedGrid))

        // 范围切换与悬停暂停都重配同一个服务，首帧必须来自当前尺寸和真实静态底图。
        service.configure(animator: animator, payload: nil, colorScheme: .dark)
        let recentRevision = service.readyRevision
        service.configure(animator: nil, payload: nil, colorScheme: .light, range: .recent)
        #expect(service.readyRevision > recentRevision)
        let recentGrid = try #require(service.frameImage)
        let expectedRecentGrid = try #require(SnakeFrameRenderer.renderBaseGrid(
            payload: nil, colorScheme: .light, range: .recent
        ))
        #expect(recentGrid.width == 624)
        #expect(recentGrid.height == 78)
        #expect(pixelData(of: recentGrid) == pixelData(of: expectedRecentGrid))
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.frameImage?.width == 624, "已取消的年度动画不能覆盖近期首帧")
    }

    @Test("近期网格缓存合成保持颜色和行列方向")
    func recentCachedBaseGridMatchesFullRender() throws {
        let payload = ContributionCalendarPayload(
            totalContributions: 5,
            weeks: [ContributionWeek(contributionDays: [
                ContributionDay(date: "2026-10-28", contributionCount: 2, contributionLevel: .firstQuartile, weekday: 3),
                ContributionDay(date: "2026-10-29", contributionCount: 3, contributionLevel: .thirdQuartile, weekday: 4)
            ])]
        )
        let frame = AnimationFrame(
            snakes: [[GridPosition(col: 14, row: 1)]],
            eatenCells: [GridPosition(col: 13, row: 1)],
            foodCells: [GridPosition(col: 0, row: 0)]
        )
        let time = Date(timeIntervalSinceReferenceDate: 123_456.25)
        let full = try #require(SnakeFrameRenderer.render(
            payload: payload, frame: frame, colorScheme: .light, range: .recent, time: time
        ))
        let base = try #require(SnakeFrameRenderer.renderBaseGrid(
            payload: payload, colorScheme: .light, range: .recent
        ))
        let cached = try #require(SnakeFrameRenderer.render(
            payload: payload, frame: frame, colorScheme: .light, range: .recent, baseGrid: base, time: time
        ))
        #expect(pixelData(of: full) == pixelData(of: cached))
    }

    private func pixelData(of image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
