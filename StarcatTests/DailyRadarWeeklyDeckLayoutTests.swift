//
//  DailyRadarWeeklyDeckLayoutTests.swift
//  Starcat
//
//  验证周报叠卡的日期与鼠标锚点、首尾边界，不依赖实际应用窗口。
//

import XCTest
@testable import Starcat

/// 覆盖实际窄窗、桌面与界面缩放，防止独立等分日期导致封面再次错位。
final class DailyRadarWeeklyDeckLayoutTests: XCTestCase {
    /// 每张封面的中心同时是对应日期的命中中心，首末留白归最近一期。
    func testAllSixAnchorsSelectTheirOwnEdition() {
        for scale: CGFloat in [0.85, 1, 1.25, 1.5] {
            for width: CGFloat in [280, 346, 605, 960] {
                let layout = DailyRadarWeeklyDeckLayout(stageWidth: width * scale, scale: scale, count: 6)
                for index in 0..<6 {
                    XCTAssertEqual(layout.index(at: layout.center(at: index)), index)
                    XCTAssertGreaterThanOrEqual(layout.center(at: index) - layout.cardWidth / 2, 0)
                    XCTAssertLessThanOrEqual(layout.center(at: index) + layout.cardWidth / 2, layout.width)
                }
                XCTAssertEqual(layout.index(at: -10), 0)
                XCTAssertEqual(layout.index(at: layout.width + 10), 5)
                XCTAssertLessThan(layout.center(at: 0), layout.center(at: 5))
            }
        }
    }

    /// 相邻日期之间只在中点换期，抬升动画不参与鼠标坐标计算。
    func testHitBoundariesFollowAdjacentDateMidpoints() {
        let layout = DailyRadarWeeklyDeckLayout(stageWidth: 605, scale: 1, count: 6)
        for index in 0..<5 {
            let midpoint = (layout.center(at: index) + layout.center(at: index + 1)) / 2
            XCTAssertEqual(layout.index(at: midpoint - 0.1), index)
            XCTAssertEqual(layout.index(at: midpoint + 0.1), index + 1)
        }
    }

    /// 空数据占位和仅一期都居中；零宽布局不能出现除零或越界选期。
    func testSingleEditionAndEmptyPlaceholderStayCentered() {
        for count in [0, 1] {
            let layout = DailyRadarWeeklyDeckLayout(stageWidth: 300, scale: 1, count: count)
            XCTAssertEqual(layout.center(at: 0), 150)
            for x: CGFloat in [-10, 0, 150, 300, 310] {
                XCTAssertEqual(layout.index(at: x), 0)
            }
        }
        let collapsed = DailyRadarWeeklyDeckLayout(stageWidth: 0, scale: 1, count: 6)
        XCTAssertEqual(collapsed.cardWidth, 0)
        XCTAssertEqual(collapsed.index(at: 0), 0)
    }
}
