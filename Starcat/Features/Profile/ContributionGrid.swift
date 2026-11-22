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
    private let days: [ContributionCalendarPayload.Day]
    /// 只保存到同一份日数组的偏移。-1 是缺失日，不能用零贡献日补位。
    private let dayOffsets: ArraySlice<Int>
    let cols: Int
    let rows: Int
    let isPlaceholder: Bool

    /// 近期以缓存中最新一天为终点按日历截取，不因漏日而把更早的数据补进来。
    init(payload: ContributionCalendarPayload?, range: ContributionGraphRange = .year) {
        let layout = range.layout
        cols = layout.cols
        rows = layout.rows
        isPlaceholder = payload == nil
        let days = payload?.days ?? []
        self.days = days
        var offsets = Array(repeating: -1, count: cols * rows)
        if let payload {
            if let dayCount = range.dayCount, let latest = days.lazy.map(\.dayIndex).max() {
                let first = Int(latest) - dayCount + 1
                for index in days.indices {
                    let elapsed = Int(days[index].dayIndex) - first
                    guard (0..<dayCount).contains(elapsed) else { continue }
                    let column = elapsed % cols
                    let row = elapsed / cols
                    offsets[column * rows + row] = index
                }
            } else if range == .year {
                let visibleWeeks = min(cols, payload.weekCount)
                for offset in 0..<visibleWeeks {
                    let week = payload.weekCount - visibleWeeks + offset
                    let column = cols - visibleWeeks + offset
                    for index in payload.dayIndices(inWeek: week) {
                        offsets[column * rows + days[index].weekday] = index
                    }
                }
            }
        }
        dayOffsets = offsets[...]
    }

    private init(days: [ContributionCalendarPayload.Day], dayOffsets: ArraySlice<Int>, rows: Int, isPlaceholder: Bool) {
        self.days = days
        self.dayOffsets = dayOffsets
        cols = dayOffsets.count / rows
        self.rows = rows
        self.isPlaceholder = isPlaceholder
    }

    func cell(at position: GridPosition) -> ContributionCalendarPayload.Day? {
        guard (0..<cols).contains(position.col), (0..<rows).contains(position.row) else { return nil }
        let offset = dayOffsets[dayOffsets.startIndex + position.col * rows + position.row]
        return offset < 0 ? nil : days[offset]
    }

    /// 仅在查看单日详情时构造日期字符串。
    func day(at position: GridPosition) -> ContributionDay? {
        guard let cell = cell(at: position) else { return nil }
        return ContributionDay(
            date: cell.date, contributionCount: cell.contributionCount,
            contributionLevel: cell.contributionLevel, weekday: cell.weekday
        )
    }

    /// 动画只读颜色权重，不能重新按近期数据分桶，否则同一天切换范围后会变色。
    func weight(at position: GridPosition) -> Int {
        cell(at: position)?.weight ?? 0
    }

    var totalContributions: Int {
        dayOffsets.reduce(0) { $0 + ($1 < 0 ? 0 : days[$1].contributionCount) }
    }

    var dayCount: Int { dayOffsets.lazy.filter { $0 >= 0 }.count }

    var allPositions: [GridPosition] {
        (0..<cols).flatMap { column in
            (0..<rows).map { GridPosition(col: column, row: $0) }
        }
    }

    /// 多蛇各自在自己的半区寻路，日期空位也保留原来的列位置。
    func columns(_ bounds: Range<Int>) -> ContributionGrid {
        let start = dayOffsets.startIndex + bounds.lowerBound * rows
        let end = dayOffsets.startIndex + bounds.upperBound * rows
        return ContributionGrid(days: days, dayOffsets: dayOffsets[start..<end], rows: rows, isPlaceholder: isPlaceholder)
    }

    /// GitHub 返回的是日历日期；统一按 UTC 解释，避免本机时区把午夜移到前一天。
    static func date(_ value: String) -> Date? {
        ContributionCalendarPayload.Day.parseDate(value)
    }
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
        if let position = position(at: point), grid.cell(at: position) != nil {
            return position
        }
        return previous
    }
}

/// 提示卡的文字与占位共用同一套格式，不能随当前悬停日期或显示范围改变尺寸。
struct ContributionTooltipMetrics {
    struct DailyComparison {
        let dayCount: String
        let average: String
        let ratio: String?
    }

    let dateText: String
    let weekdayText: String
    let countText: String
    let countPlaceholder: String
    let comparison: DailyComparison?

    /// 始终接收完整年度数据；最大值格式化后的分隔符也必须计入数字区宽度。
    init(day: ContributionDay, maximumCount: Int, grid: ContributionGrid? = nil, locale: Locale) {
        countText = day.contributionCount.formatted(.number.locale(locale))
        countPlaceholder = maximumCount.formatted(.number.locale(locale))

        // 从当前显示范围取真实日历日期。零贡献日计入分母，布局补位不计入。
        let dayCount = grid?.dayCount ?? 0
        if let grid, dayCount > 0 {
            let average = Double(grid.totalContributions) / Double(dayCount)
            let decimal = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).locale(locale)
            comparison = DailyComparison(
                dayCount: dayCount.formatted(.number.locale(locale)),
                average: average.formatted(decimal),
                ratio: average > 0 ? (Double(day.contributionCount) / average).formatted(decimal) : nil
            )
        } else {
            comparison = nil
        }

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
        formatter.dateFormat = "EEE"
        weekdayText = date.map(formatter.string(from:)) ?? ""
    }
}

/// 在 AppKit 屏幕坐标中优先放到方格上方，屏幕边缘只平移卡身，箭头仍瞄准方格。
struct ContributionTooltipGeometry {
    static let arrowHeight: CGFloat = 7
    let frame: CGRect
    let arrowX: CGFloat
    let isAbove: Bool

    init?(cell: CGRect, size: CGSize, within bounds: CGRect) {
        let available = bounds.insetBy(dx: 8, dy: 8)
        guard size.width <= available.width else { return nil }

        let originX = min(max(cell.midX - size.width / 2, available.minX), available.maxX - size.width)
        let above = CGRect(origin: CGPoint(x: originX, y: cell.maxY + 4), size: size)
        let below = CGRect(origin: CGPoint(x: originX, y: cell.minY - 4 - size.height), size: size)
        if available.contains(above) {
            frame = above
            isAbove = true
        } else if available.contains(below) {
            frame = below
            isAbove = false
        } else {
            return nil
        }
        arrowX = min(max(cell.midX - frame.minX, 0), frame.width)
    }
}
