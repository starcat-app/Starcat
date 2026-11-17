//
//  ContributionGridTests.swift
//  StarcatTests
//
//  贡献草坪范围、日期命中及动画边界的回归契约，不依赖网络或桌面操作。
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Starcat

/// 不同显示范围必须使用同一份真实日期和颜色数据。
struct ContributionGridTests {
    @Test("范围按年度、30、60、90天循环")
    func rangeCycle() {
        var range = ContributionGraphRange.year
        var visited: [ContributionGraphRange] = []
        for _ in 0..<4 {
            visited.append(range)
            range = range.next
        }
        #expect(visited == [.year, .recent30, .recent60, .recent90])
        #expect(range == .year)
    }

    @Test("最近30天按两行时间顺序排列，合计不包含更早日期")
    func recentDaysAndTotal() throws {
        let grid = ContributionGrid(weeks: fixtureWeeks(), range: .recent30)
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

    @Test("60和90天跨年截取保持日历顺序、合计与年度颜色", arguments: [
        ContributionGraphRange.recent60, .recent90
    ])
    func longerRecentRanges(range: ContributionGraphRange) throws {
        let weeks = fixtureWeeks(count: 120)
        let grid = ContributionGrid(weeks: weeks, range: range)
        let dayCount = try #require(range.dayCount)
        #expect(grid.cols == (range == .recent60 ? 20 : 23))
        #expect(grid.rows == (range == .recent60 ? 3 : 4))
        #expect(grid.day(at: GridPosition(col: 0, row: 0))?.date
            == (range == .recent60 ? "2026-11-19" : "2026-10-20"))
        let lastPosition = GridPosition(col: (dayCount - 1) % grid.cols, row: (dayCount - 1) / grid.cols)
        #expect(grid.day(at: lastPosition)?.date == "2027-01-17")
        #expect(grid.totalContributions == (range == .recent60 ? 5_370 : 6_705))

        let originalDays = weeks.flatMap(\.contributionDays)
        for index in 0..<dayCount {
            let position = GridPosition(col: index % grid.cols, row: index / grid.cols)
            #expect(grid.day(at: position) == originalDays[120 - dayCount + index])
        }
        #expect(grid.allPositions.filter { grid.day(at: $0) == nil }.count == grid.cols * grid.rows - dayCount)
        if range == .recent90 {
            #expect(grid.day(at: GridPosition(col: 21, row: 3)) == nil)
            #expect(grid.day(at: GridPosition(col: 22, row: 3)) == nil)
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
        let grid = ContributionGrid(weeks: [ContributionWeek(contributionDays: days)], range: .recent30)
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
        let recent = ContributionGrid(weeks: weeks, range: .recent30)
        #expect(recent.day(at: GridPosition(col: 14, row: 1)) == day)
        #expect(recent.day(at: GridPosition(col: 13, row: 1)) == nil)
        #expect(!recent.isPlaceholder)
        #expect(ContributionGrid(weeks: nil, range: .recent30).isPlaceholder)
    }

    @Test("缩放后日期命中准确，间隙与居中留白不命中", arguments: ContributionGraphRange.allCases)
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
            if range != .year {
                #expect(abs(first.width - first.height) < 0.001)
                #expect(geometry.gridRect.minY > 0)
                #expect(geometry.position(at: CGPoint(x: width / 2, y: 0)) == nil)
            }
        }
    }

    @Test("悬停跨格间隙保留上一日，进入下一格更新，离开草坪清空", arguments: ContributionGraphRange.allCases)
    func continuousInspection(range: ContributionGraphRange) throws {
        let grid = ContributionGrid(weeks: fixtureWeeks(count: 120), range: range)
        let geometry = ContributionGraphGeometry(
            layout: range.layout, containerSize: CGSize(width: 232, height: 232 * 110 / 634)
        )
        let positions = grid.allPositions.filter { grid.day(at: $0) != nil }
        let firstPosition = try #require(positions.first)
        let nextPosition = try #require(positions.dropFirst().first)
        let first = geometry.rect(at: firstPosition)
        let next = geometry.rect(at: nextPosition)
        let center = CGPoint(x: first.midX, y: first.midY)
        #expect(geometry.inspectionPosition(at: center, in: grid, previous: nil) == firstPosition)
        // allPositions 按列枚举，取同一列相邻两行中间的空隙。
        let gap = CGPoint(x: first.midX, y: (first.maxY + next.minY) / 2)
        #expect(geometry.position(at: gap) == nil)
        #expect(geometry.inspectionPosition(at: gap, in: grid, previous: nil) == nil)
        #expect(geometry.inspectionPosition(at: gap, in: grid, previous: firstPosition) == firstPosition)
        #expect(geometry.inspectionPosition(
            at: CGPoint(x: next.midX, y: next.midY), in: grid, previous: firstPosition
        ) == nextPosition)
        #expect(geometry.inspectionPosition(
            at: CGPoint(x: -1, y: first.midY), in: grid, previous: nextPosition
        ) == nil)
    }

    @Test("提示位于光标右下方，并正确换算窗口向上为正的坐标", arguments: [true, false])
    func tooltipFollowsPointer(isFlipped: Bool) {
        let bounds = CGRect(x: 40, y: 30, width: 1_000, height: 700)
        let point = CGPoint(x: 300, y: 350)
        let size = CGSize(width: 256, height: 84)
        let frame = ContributionTooltipGeometry.frame(
            at: point, size: size, within: bounds, isFlipped: isFlipped
        )
        #expect(frame.minX == point.x + 16)
        #expect(isFlipped ? frame.minY == point.y + 20 : frame.maxY == point.y - 20)
        #expect(frame.size == size)
        #expect(!frame.contains(point))

        let nextPoint = CGPoint(x: point.x + 3, y: point.y + 2)
        let nextFrame = ContributionTooltipGeometry.frame(
            at: nextPoint, size: size, within: bounds, isFlipped: isFlipped
        )
        #expect(nextFrame.minX - frame.minX == 3)
        #expect(nextFrame.minY - frame.minY == 2)
    }

    @Test("提示在窗口边缘避让，字号放大后仍不覆盖光标", arguments: [true, false])
    func tooltipAvoidsWindowEdges(isFlipped: Bool) {
        let bounds = CGRect(x: 40, y: 30, width: 640, height: 480)
        for width: CGFloat in [256, 316] {
            for pointerX: CGFloat in [50, 360, 670] {
                for pointerY: CGFloat in [40, 270, 500] {
                    let point = CGPoint(x: pointerX, y: pointerY)
                    let frame = ContributionTooltipGeometry.frame(
                        at: point, size: CGSize(width: width, height: 100),
                        within: bounds, isFlipped: isFlipped
                    )
                    #expect(bounds.insetBy(dx: 8, dy: 8).contains(frame))
                    #expect(!frame.contains(point))
                    if pointerX == 670 {
                        #expect(frame.maxX == point.x - 16)
                    }
                }
            }
        }
    }

    @Test("数字占位按全年最高值变化，超过三位时包含千位分隔符", arguments: [
        (0, "0"), (9, "9"), (10, "10"), (99, "99"), (100, "100"),
        (999, "999"), (1_000, "1,000"), (1_250, "1,250"), (10_000, "10,000")
    ])
    func tooltipCountCapacity(testCase: (maximum: Int, expected: String)) {
        let day = ContributionDay(
            date: "2026-11-18", contributionCount: 0, contributionLevel: .none, weekday: 3
        )
        let peak = ContributionDay(
            date: "2026-01-09", contributionCount: testCase.maximum,
            contributionLevel: .fourthQuartile, weekday: 5
        )
        let metrics = ContributionTooltipMetrics(
            day: day, weeks: [ContributionWeek(contributionDays: [peak, day])],
            locale: Locale(identifier: "en-US")
        )
        #expect(metrics.countPlaceholder == testCase.expected)
        #expect(metrics.countText == "0")
    }

    @Test("近期范围之外的年度峰值仍决定数字占位", arguments: ContributionGraphRange.allCases)
    func tooltipUsesAnnualMaximum(range: ContributionGraphRange) throws {
        let weeks = fixtureWeeks(count: 120).map { week in
            ContributionWeek(contributionDays: week.contributionDays.map { day in
                ContributionDay(
                    date: day.date,
                    contributionCount: day.date == "2026-09-20" ? 1_250 : 5,
                    contributionLevel: day.contributionLevel, weekday: day.weekday
                )
            })
        }
        let grid = ContributionGrid(weeks: weeks, range: range)
        let day = try #require(grid.allPositions.compactMap { grid.day(at: $0) }
            .first { $0.contributionCount == 5 })
        if range != .year {
            #expect(grid.allPositions.compactMap { grid.day(at: $0) }
                .allSatisfy { $0.contributionCount == 5 })
        }
        let metrics = ContributionTooltipMetrics(day: day, weeks: weeks, locale: Locale(identifier: "en-US"))
        #expect(metrics.countPlaceholder == "1,250")
        #expect(metrics.countText == "5")
    }

    @Test("中文日期月日补齐两位，星期与日期分别展示")
    func tooltipPaddedDate() {
        let day = ContributionDay(
            date: "2026-01-09", contributionCount: 9, contributionLevel: .firstQuartile, weekday: 5
        )
        let metrics = ContributionTooltipMetrics(
            day: day, weeks: [ContributionWeek(contributionDays: [day])],
            locale: Locale(identifier: "zh-Hans")
        )
        #expect(metrics.dateText == "2026年01月09日")
        #expect(metrics.weekdayText == "周五")
        #expect(metrics.countText == "9")
        #expect(metrics.weekdayPlaceholders.contains(metrics.weekdayText))
    }

    @Test("各语言与字号下，跨日期、星期和数字位数的卡片尺寸保持不变",
          arguments: AppLocale.allCases.filter { $0 != .system }.map(\.rawValue))
    @MainActor
    func tooltipSizeIsStable(language: String) {
        let samples = [
            ("2026-01-09", 0), ("2026-01-10", 1), ("2026-02-01", 9),
            ("2026-09-11", 18), ("2026-10-23", 99), ("2026-11-16", 100),
            ("2026-11-17", 999), ("2026-11-18", 1_000), ("2026-12-24", 1_250),
            ("2027-01-01", 1)
        ].map { date, count in
            ContributionDay(date: date, contributionCount: count, contributionLevel: .firstQuartile, weekday: 0)
        }
        let weeks = [ContributionWeek(contributionDays: samples)]
        let locale = Locale(identifier: language)
        for scale in [InterfaceScale.standard, .large] {
            var referenceSize: CGSize?
            for day in samples {
                let metrics = ContributionTooltipMetrics(day: day, weeks: weeks, locale: locale)
                let host = NSHostingView(rootView: ContributionTooltipCard(metrics: metrics, color: .green)
                    .environment(\.locale, locale)
                    .environment(\.starcatInterfaceScale, scale))
                // 只测离屏布局，不创建窗口或操作桌面；直接验证真正参与窗口定位的 fittingSize。
                let size = host.fittingSize
                #expect(size.width > 0 && size.height > 0)
                if let referenceSize {
                    #expect(abs(size.width - referenceSize.width) < 0.001)
                    #expect(abs(size.height - referenceSize.height) < 0.001)
                } else {
                    referenceSize = size
                }
            }
        }
    }

    @Test("英文长单位下，星期仍与卡片右侧内边距对齐",
          arguments: ["2026-09-12", "2026-09-16"])
    @MainActor
    func tooltipWeekdayIsRightAligned(date: String) throws {
        let day = ContributionDay(
            date: date, contributionCount: 45, contributionLevel: .firstQuartile, weekday: 0
        )
        let peak = ContributionDay(
            date: "2026-01-09", contributionCount: 1_250,
            contributionLevel: .fourthQuartile, weekday: 5
        )
        let locale = Locale(identifier: "en-US")
        let metrics = ContributionTooltipMetrics(
            day: day, weeks: [ContributionWeek(contributionDays: [peak, day])], locale: locale
        )
        for scale in [InterfaceScale.standard, .large] {
            let renderer = ImageRenderer(content: ContributionTooltipCard(metrics: metrics, color: .green)
                .environment(\.locale, locale)
                .environment(\.colorScheme, .light)
                .environment(\.starcatInterfaceScale, scale))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
            let inset = Int(scale.scaled(12) * renderer.scale)
            let headerBottom = Int(scale.scaled(28) * renderer.scale)
            let contentRight = bitmap.pixelsWide - inset
            // 离屏检查日期行的真实文字边界；卡片总宽不变并不能证明星期已经右对齐。
            let textRight = try #require((inset..<contentRight).reversed().first { pixelX in
                (inset..<headerBottom).contains { pixelY in
                    guard let color = bitmap.colorAt(x: pixelX, y: pixelY)?.usingColorSpace(.deviceRGB) else {
                        return false
                    }
                    return color.alphaComponent > 0.9
                        && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.75
                }
            })
            #expect(CGFloat(contentRight - textRight) / renderer.scale <= 3)
        }
    }

    @Test("全部动画玩法在各档近期网格内运行",
          arguments: SnakeStyle.allCases.filter { $0 != .off },
          ContributionGraphRange.allCases.filter { $0 != .year })
    func recentAnimationBounds(style: SnakeStyle, range: ContributionGraphRange) throws {
        let animator = try #require(SnakeAnimatorFactory.make(
            style: style, weeks: fixtureWeeks(count: 120), range: range
        ))
        #expect(animator.totalSteps > 0)
        var visited = Set<GridPosition>()
        for step in 0..<animator.totalSteps {
            let frame = animator.frame(at: step)
            visited.formUnion(frame.snakes.flatMap { $0 })
            visited.formUnion(frame.eatenCells)
            visited.formUnion(frame.foodCells)
        }
        #expect(visited.allSatisfy {
            (0..<range.layout.cols).contains($0.col) && (0..<range.layout.rows).contains($0.row)
        })
        if style != .foodChase {
            #expect(visited.count == range.layout.cols * range.layout.rows)
        }
    }

    /// 默认40天跨月数据，120天用例跨年；颜色直接使用接口档位。
    private func fixtureWeeks(count: Int = 40) -> [ContributionWeek] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let first = ContributionGrid.date("2026-09-20")!
        let levels: [ContributionLevel] = [.none, .firstQuartile, .secondQuartile, .thirdQuartile, .fourthQuartile]
        let days = (0..<count).map { index in
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
