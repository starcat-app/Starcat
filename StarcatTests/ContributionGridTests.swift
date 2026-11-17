//
//  ContributionGridTests.swift
//  StarcatTests
//
//  贡献草坪范围、日期命中及动画边界的回归契约，不依赖网络或桌面操作。
//

import Foundation
import Testing
@testable import Starcat

/// 两种显示范围必须使用同一份真实日期和颜色数据。
struct ContributionGridTests {
    @Test("最近30天按两行时间顺序排列，合计不包含更早日期")
    func recentDaysAndTotal() throws {
        let grid = ContributionGrid(weeks: fixtureWeeks(), range: .recent)
        #expect(grid.cols == 15)
        #expect(grid.rows == 2)
        #expect(grid.day(at: GridPosition(col: 0, row: 0))?.date == "2026-09-30")
        #expect(grid.day(at: GridPosition(col: 14, row: 0))?.date == "2026-10-14")
        #expect(grid.day(at: GridPosition(col: 0, row: 1))?.date == "2026-10-15")
        #expect(grid.day(at: GridPosition(col: 14, row: 1))?.date == "2026-10-29")
        #expect(grid.totalContributions == 735)

        let annual = ContributionGrid(weeks: fixtureWeeks())
        for position in grid.allPositions {
            let day = try #require(grid.day(at: position))
            let original = try #require(annual.allPositions.compactMap { annual.day(at: $0) }
                .first { $0.date == day.date })
            #expect(day.contributionCount == original.contributionCount)
            #expect(day.contributionLevel == original.contributionLevel)
        }
    }

    @Test("缺失日期保留空位，真实零贡献日仍可查询")
    func missingDaysAndZeroCounts() throws {
        let originalDays = fixtureWeeks().flatMap(\.contributionDays)
        let days = originalDays.filter { $0.date != "2026-10-15" }.map { day in
            ContributionDay(
                date: day.date,
                contributionCount: day.date == "2026-10-29" ? 0 : day.contributionCount,
                contributionLevel: day.date == "2026-10-29" ? .none : day.contributionLevel,
                weekday: day.weekday
            )
        }
        let grid = ContributionGrid(weeks: [ContributionWeek(contributionDays: days)], range: .recent)
        #expect(grid.day(at: GridPosition(col: 0, row: 1)) == nil)
        #expect(grid.day(at: GridPosition(col: 0, row: 0))?.date == "2026-09-30")
        let zeroDay = try #require(grid.day(at: GridPosition(col: 14, row: 1)))
        #expect(zeroDay.contributionCount == 0)
        #expect(grid.day(at: GridPosition(col: -1, row: 0)) == nil)
    }

    @Test("年度不足一周时保持星期与右对齐，近期不足30天时最新日期仍在右下")
    func partialCalendars() {
        let day = ContributionDay(
            date: "2026-10-29", contributionCount: 0, contributionLevel: .none, weekday: 4
        )
        let weeks = [ContributionWeek(contributionDays: [day])]
        let annual = ContributionGrid(weeks: weeks)
        #expect(annual.day(at: GridPosition(col: 52, row: 4)) == day)
        #expect(annual.day(at: GridPosition(col: 52, row: 5)) == nil)
        #expect(annual.day(at: GridPosition(col: 51, row: 4)) == nil)
        let recent = ContributionGrid(weeks: weeks, range: .recent)
        #expect(recent.day(at: GridPosition(col: 14, row: 1)) == day)
        #expect(recent.day(at: GridPosition(col: 13, row: 1)) == nil)
        #expect(!recent.isPlaceholder)
        #expect(ContributionGrid(weeks: nil, range: .recent).isPlaceholder)
    }

    @Test("缩放后日期命中准确，间隙与居中留白不命中", arguments: [ContributionGraphRange.year, .recent])
    func scaledHitTesting(range: ContributionGraphRange) {
        for width: CGFloat in [212, 292, 440] {
            let geometry = ContributionGraphGeometry(
                layout: range.layout,
                containerSize: CGSize(width: width, height: width * 110 / 634)
            )
            let grid = ContributionGrid(weeks: nil, range: range)
            for position in grid.allPositions {
                let rect = geometry.rect(at: position)
                #expect(geometry.position(at: CGPoint(x: rect.midX, y: rect.midY)) == position)
            }
            let first = geometry.rect(at: GridPosition(col: 0, row: 0))
            let next = geometry.rect(at: GridPosition(col: 1, row: 0))
            #expect(geometry.position(at: CGPoint(x: (first.maxX + next.minX) / 2, y: first.midY)) == nil)
            #expect(geometry.position(at: CGPoint(x: -1, y: 0)) == nil)
            if range == .recent {
                #expect(abs(first.width - first.height) < 0.001)
                #expect(geometry.gridRect.minY > 0)
                #expect(geometry.position(at: CGPoint(x: width / 2, y: 0)) == nil)
            }
        }
    }

    @Test("全部动画玩法在近期15×2网格内运行", arguments: SnakeStyle.allCases.filter { $0 != .off })
    func recentAnimationBounds(style: SnakeStyle) throws {
        let animator = try #require(SnakeAnimatorFactory.make(
            style: style, weeks: fixtureWeeks(), range: .recent
        ))
        #expect(animator.totalSteps > 0)
        var visited = Set<GridPosition>()
        for step in 0..<animator.totalSteps {
            let frame = animator.frame(at: step)
            visited.formUnion(frame.snakes.flatMap { $0 })
            visited.formUnion(frame.eatenCells)
            visited.formUnion(frame.foodCells)
        }
        #expect(visited.allSatisfy { (0..<15).contains($0.col) && (0..<2).contains($0.row) })
        if style != .foodChase {
            #expect(visited.count == 30)
        }
    }

    /// 连续40天跨月数据；最近30天的计数应为10...39，颜色直接使用接口档位。
    private func fixtureWeeks() -> [ContributionWeek] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let first = ContributionGrid.date("2026-09-20")!
        let levels: [ContributionLevel] = [.none, .firstQuartile, .secondQuartile, .thirdQuartile, .fourthQuartile]
        let days = (0..<40).map { index in
            ContributionDay(
                date: formatter.string(from: first.addingTimeInterval(Double(index) * 86_400)),
                contributionCount: index, contributionLevel: levels[index % levels.count],
                weekday: index % 7
            )
        }
        return stride(from: 0, to: days.count, by: 7).map { start in
            ContributionWeek(contributionDays: Array(days[start..<min(start + 7, days.count)]))
        }
    }
}
