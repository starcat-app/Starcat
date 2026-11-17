//
//  ContributionGrid.swift
//  Starcat
//
//  贡献草坪的日期、绘制与动画共用同一份坐标映射，避免近期视图只裁剪年度位图。
//

import Foundation

/// 侧栏显示范围；资料卡继续使用默认年度视图。
enum ContributionGraphRange: CaseIterable, Equatable, Sendable {
    case year
    case recent30
    case recent60
    case recent90

    var dayCount: Int? {
        switch self {
        case .year: nil
        case .recent30: 30
        case .recent60: 60
        case .recent90: 90
        }
    }

    var next: Self {
        switch self {
        case .year: .recent30
        case .recent30: .recent60
        case .recent60: .recent90
        case .recent90: .year
        }
    }

    var layout: SnakeFrameRenderer.Layout {
        switch self {
        case .year: return .standard
        case .recent30, .recent60, .recent90:
            // 用行数控制侧栏密度；90 天末尾两格留空，不引入范围外的日期。
            let columns = self == .recent30 ? 15 : self == .recent60 ? 20 : 23
            let rows = self == .recent30 ? 2 : self == .recent60 ? 3 : 4
            return SnakeFrameRenderer.Layout(
                cols: columns, rows: rows,
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

    /// 近期以缓存中最新一天为终点按日历截取，不因漏日而把更早的数据补进来。
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
        case .recent30, .recent60, .recent90:
            let allDays = weeks.flatMap(\.contributionDays)
            if let dayCount = range.dayCount,
               let latest = allDays.map(\.date).max().flatMap(Self.date),
               let first = Self.calendar.date(byAdding: .day, value: 1 - dayCount, to: latest) {
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

    /// 间隙保留上一日，离开网格才收起提示，避免横跨相邻格子时反复显隐。
    func inspectionPosition(
        at point: CGPoint,
        in grid: ContributionGrid,
        previous: GridPosition?
    ) -> GridPosition? {
        guard gridRect.contains(point) else { return nil }
        if let position = position(at: point), grid.day(at: position) != nil {
            return position
        }
        return previous
    }
}

/// 提示卡的文字与占位共用同一套格式，不能随当前悬停日期或显示范围改变尺寸。
struct ContributionTooltipMetrics {
    let dateText: String
    let weekdayText: String
    let countText: String
    let datePlaceholder: String
    let weekdayPlaceholders: [String]
    let countPlaceholder: String

    /// 始终接收完整年度数据；最大值格式化后的分隔符也必须计入数字区宽度。
    init(day: ContributionDay, weeks: [ContributionWeek]?, locale: Locale) {
        let maximumCount = weeks?.lazy.flatMap(\.contributionDays).map(\.contributionCount).max() ?? 0
        countText = day.contributionCount.formatted(.number.locale(locale))
        countPlaceholder = maximumCount.formatted(.number.locale(locale))

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if locale.language.languageCode?.identifier == "zh" {
            formatter.dateFormat = "yyyy年MM月dd日"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("yyyyMMdd")
        }
        let date = ContributionGrid.date(day.date)
        dateText = date.map(formatter.string(from:)) ?? day.date
        // 四位年与两位月日配合等宽数字，跨月、跨年时仍使用同一宽度。
        datePlaceholder = formatter.string(from: ContributionGrid.date("2000-12-24")!)
        weekdayPlaceholders = formatter.shortWeekdaySymbols
        formatter.dateFormat = "EEE"
        weekdayText = date.map(formatter.string(from:)) ?? ""
    }
}

/// 提示默认位于光标右下方；只在窗口边缘翻转方向，保证当前光标仍在卡片之外。
struct ContributionTooltipGeometry {
    /// AppKit 的窗口父层通常向上为正，不能直接套用 SwiftUI 向下为正的偏移。
    static func frame(
        at point: CGPoint,
        size: CGSize,
        within bounds: CGRect,
        isFlipped: Bool
    ) -> CGRect {
        let available = bounds.insetBy(dx: 8, dy: 8)
        let width = min(size.width, available.width)
        let height = min(size.height, available.height)
        var originX = point.x + 16
        if originX + width > available.maxX {
            originX = point.x - 16 - width
        }
        var originY = isFlipped ? point.y + 20 : point.y - 20 - height
        if isFlipped, originY + height > available.maxY {
            originY = point.y - 20 - height
        } else if !isFlipped, originY < available.minY {
            originY = point.y + 20
        }
        return CGRect(
            x: min(max(originX, available.minX), available.maxX - width),
            y: min(max(originY, available.minY), available.maxY - height),
            width: width, height: height
        )
    }
}
