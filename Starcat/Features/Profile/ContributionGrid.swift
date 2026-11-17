//
//  ContributionGrid.swift
//  Starcat
//
//  贡献草坪的日期、绘制与动画共用同一份坐标映射，避免近期视图只裁剪年度位图。
//

import Foundation

/// 侧栏显示范围；资料卡继续使用默认年度视图。
enum ContributionGraphRange: Equatable, Sendable {
    case year
    case recent

    var layout: SnakeFrameRenderer.Layout {
        switch self {
        case .year: .standard
        case .recent:
            SnakeFrameRenderer.Layout(
                cols: 15, rows: 2,
                cellWidth: 36, cellHeight: 36,
                cellSpacing: 6, cellCornerRadius: 6
            )
        }
    }
}

/// 保留真实日期和 GitHub 颜色档位；空位与真实的零贡献日必须能区分。
struct ContributionGrid: Sendable {
    let days: [[ContributionDay?]]
    let cols: Int
    let rows: Int
    let isPlaceholder: Bool

    /// 近期以缓存中最新一天为终点，按日历截取30天，不因漏日而把更早的数据补进来。
    init(weeks: [ContributionWeek]?, range: ContributionGraphRange = .year) {
        let layout = range.layout
        cols = layout.cols
        rows = layout.rows
        isPlaceholder = weeks == nil
        var mappedDays = Array(
            repeating: Array<ContributionDay?>(repeating: nil, count: rows),
            count: cols
        )
        let weeks = weeks ?? []
        switch range {
        case .year:
            let visibleWeeks = weeks.suffix(cols)
            let startColumn = cols - visibleWeeks.count
            for (index, week) in visibleWeeks.enumerated() {
                for day in week.contributionDays where (0..<rows).contains(day.weekday) {
                    mappedDays[startColumn + index][day.weekday] = day
                }
            }
        case .recent:
            let allDays = weeks.flatMap(\.contributionDays)
            if let latest = allDays.map(\.date).max().flatMap(Self.date),
               let first = Self.calendar.date(byAdding: .day, value: -29, to: latest) {
                for day in allDays {
                    guard let date = Self.date(day.date),
                          date >= first, date <= latest,
                          let index = Self.calendar.dateComponents([.day], from: first, to: date).day else {
                        continue
                    }
                    mappedDays[index % cols][index / cols] = day
                }
            }
        }
        days = mappedDays
    }

    private init(days: [[ContributionDay?]], rows: Int, isPlaceholder: Bool) {
        self.days = days
        cols = days.count
        self.rows = rows
        self.isPlaceholder = isPlaceholder
    }

    func day(at position: GridPosition) -> ContributionDay? {
        guard (0..<cols).contains(position.col), (0..<rows).contains(position.row) else { return nil }
        return days[position.col][position.row]
    }

    func level(at position: GridPosition) -> ContributionLevel {
        day(at: position)?.contributionLevel ?? .none
    }

    /// 动画只读颜色权重，不能重新按近期数据分桶，否则同一天切换范围后会变色。
    func weight(at position: GridPosition) -> Int {
        switch level(at: position) {
        case .none: 0
        case .firstQuartile: 1
        case .secondQuartile: 2
        case .thirdQuartile: 3
        case .fourthQuartile: 4
        }
    }

    var totalContributions: Int {
        days.flatMap { $0 }.compactMap { $0 }.reduce(0) { $0 + $1.contributionCount }
    }

    var allPositions: [GridPosition] {
        (0..<cols).flatMap { column in
            (0..<rows).map { GridPosition(col: column, row: $0) }
        }
    }

    /// 多蛇各自在自己的半区寻路，日期空位也保留原来的列位置。
    func columns(_ bounds: Range<Int>) -> ContributionGrid {
        ContributionGrid(days: Array(days[bounds]), rows: rows, isPlaceholder: isPlaceholder)
    }

    /// GitHub 返回的是日历日期；统一按 UTC 解释，避免本机时区把午夜移到前一天。
    static func date(_ value: String) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

/// 在年度容器内居中放置当前网格，绘制、描边和命中检测使用完全相同的缩放。
struct ContributionGraphGeometry {
    let layout: SnakeFrameRenderer.Layout
    let containerSize: CGSize

    private var scale: CGFloat {
        min(containerSize.width / layout.size.width, containerSize.height / layout.size.height)
    }

    var gridRect: CGRect {
        let size = CGSize(width: layout.size.width * scale, height: layout.size.height * scale)
        return CGRect(
            x: (containerSize.width - size.width) / 2,
            y: (containerSize.height - size.height) / 2,
            width: size.width, height: size.height
        )
    }

    func rect(at position: GridPosition) -> CGRect {
        CGRect(
            x: gridRect.minX + CGFloat(position.col) * (layout.cellWidth + layout.cellSpacing) * scale,
            y: gridRect.minY + CGFloat(position.row) * (layout.cellHeight + layout.cellSpacing) * scale,
            width: layout.cellWidth * scale,
            height: layout.cellHeight * scale
        )
    }

    /// 格子间隙不吸附到邻格；不存在的日期由调用方继续排除。
    func position(at point: CGPoint) -> GridPosition? {
        guard scale > 0, gridRect.contains(point) else { return nil }
        let position = GridPosition(
            col: Int((point.x - gridRect.minX) / ((layout.cellWidth + layout.cellSpacing) * scale)),
            row: Int((point.y - gridRect.minY) / ((layout.cellHeight + layout.cellSpacing) * scale))
        )
        guard position.col < layout.cols, position.row < layout.rows,
              rect(at: position).contains(point) else { return nil }
        return position
    }
}
