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
    private func pixelData(of image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
