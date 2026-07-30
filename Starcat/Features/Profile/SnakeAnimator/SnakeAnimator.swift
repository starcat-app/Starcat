//
//  SnakeAnimator.swift
//  Starcat
//
//  贪吃蛇动画统一协议 + 数据结构 + 工厂。
//  HOM-SNAKE-MODES 2026-06-05 引入：把原 ContributionGraphView 内的 zigzag 单一玩法
//  抽成可插拔的策略，支持 dong4j 在 Settings 页面切换 6 种风格。
//
//  设计动机
//  ────────
//  - 原实现把 snakePath / snakePathIndex 硬编码在 View 里，且只能 zigzag。
//  - 扩展 5 种新玩法（A 贪心 / B 多模式轮换 / C 追食物 / D Hilbert / E 多蛇）
//    需要一个统一抽象，否则 View 会膨胀到几百行 if/else。
//  - 抽象点：所有玩法都能表达成"按 step 索引取当前帧（蛇身段 + 已吃格 + 食物）"，
//    路径型（A/B/D/E）按 step 滑窗取 snakeLength 节，状态机型（C）预生成帧数组。
//
//  关键约束
//  ────────
//  - `final class` 让动画器持有可变内部状态（如缓存路径、预生成帧），
//    协议要求 `AnyObject` 是为了让 View 用 `@State var animator: (any SnakeAnimator)?`
//    或直接 `(any SnakeAnimator)` 持有不带泛型负担。
//  - `frame(at:)` 必须 O(1) — 30FPS × 371 格不能容忍每帧 O(N) 扫描。
//  - 协议本身不依赖 SwiftUI 类型，方便单测（Frame 是纯值类型）。
//

import Foundation

// MARK: - 网格坐标

/// 草坪格子坐标。col ∈ [0, 53)，row ∈ [0, 7)。
///
/// 用 struct 而非 tuple 是为了：① `Hashable` 自动合成可放 Set；
/// ② 在 path 数组中比 `(Int, Int)` tuple 类型签名更清晰。
struct GridPosition: Hashable, Equatable {
    let col: Int
    let row: Int

    /// 曼哈顿距离（4 向邻接寻路常用）。
    func manhattan(to other: GridPosition) -> Int {
        abs(col - other.col) + abs(row - other.row)
    }

    /// 4 向邻居坐标（不做边界裁剪——调用方按 cols/rows 自行过滤）。
    var neighbors4: [GridPosition] {
        [
            GridPosition(col: col + 1, row: row),
            GridPosition(col: col - 1, row: row),
            GridPosition(col: col, row: row + 1),
            GridPosition(col: col, row: row - 1)
        ]
    }
}

// MARK: - 动画帧

/// 单帧渲染快照。所有玩法对外暴露的"当前要画什么"。
///
/// - `snakes`: 每条蛇 = 蛇头在前的坐标数组。多条蛇并发的玩法（E）会有多个元素。
/// - `eatenCells`: 已被吃掉的格子（渲染为 NONE 色）；FoodChase 这种"每轮重置"
///   的玩法只在当前游戏内填充，新一轮开始时由 animator 自己返回空集。
/// - `foodCells`: 当前的"食物"格子（仅 FoodChase 用，其他玩法返回空集）。
///   渲染层会画一个脉冲高亮，与普通绿格区分。
struct AnimationFrame {
    let snakes: [[GridPosition]]
    let eatenCells: Set<GridPosition>
    let foodCells: Set<GridPosition>

    static let empty = AnimationFrame(snakes: [], eatenCells: [], foodCells: [])
}

// MARK: - 协议

/// 贪吃蛇动画器协议。
///
/// 实现方需保证：
/// 1. `totalSteps > 0`；为 0 时调用方应直接走"静态草坪"路径（如 reduceMotion）。
/// 2. `frame(at: step)` 对 `step ∈ [0, totalSteps)` 安全；越界由调用方负责截断。
/// 3. 同一 step 多次调用返回相同 frame（idempotent，便于 TimelineView 重复重绘）。
protocol SnakeAnimator: AnyObject {
    /// 一轮动画总步数；决定 TimelineView 的循环周期 = `totalSteps × stepDuration + pauseDuration`。
    var totalSteps: Int { get }

    /// 每步停留时间。各玩法可以自己选；常见 80~150ms。
    var stepDuration: TimeInterval { get }

    /// 一轮结束后的暂停时间（让用户看到"完整草坪"或"通关"形态）。0 = 不暂停。
    var pauseDuration: TimeInterval { get }

    /// 取第 `step` 帧的渲染快照。step ∈ [0, totalSteps)。
    func frame(at step: Int) -> AnimationFrame
}

// MARK: - 时间到 step 的转换辅助

extension SnakeAnimator {

    /// 把绝对时间映射到当前 step。
    ///
    /// 返回 `nil` 表示当前处于"轮间暂停"——View 应渲染"完整草坪"且不画蛇。
    /// 否则返回 `step ∈ [0, totalSteps)`。
    ///
    /// 实现：`truncatingRemainder` 实现循环；timeline 起始锚定
    /// `timeIntervalSinceReferenceDate` 是稳定值，组件多次重建仍能"接着上次走"。
    func currentStep(at date: Date) -> Int? {
        guard totalSteps > 0 else { return nil }
        let activeDuration = Double(totalSteps) * stepDuration
        let totalDuration = activeDuration + pauseDuration
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: totalDuration)
        if phase >= activeDuration { return nil }
        return min(Int(phase / stepDuration), totalSteps - 1)
    }
}

// MARK: - 路径型基类

/// 路径型动画器共享逻辑。
///
/// "路径型" = 一条预定路径 + 固定 snakeLength，蛇身在路径上滑窗。
/// A 贪心 / D Hilbert 都是单条路径直接套用；B 多模式轮换通过组合多个路径实现；
/// E 多蛇并发通过组合多个"独立路径"实现。
///
/// 子类只需提供 `buildPath()` 返回路径数组即可。
class PathBasedSnakeAnimator: SnakeAnimator {

    /// 蛇身长度。默认 5 节（与原 zigzag 同款）。
    let snakeLength: Int
    let stepDuration: TimeInterval
    let pauseDuration: TimeInterval

    /// 预计算的蛇头路径。子类在 init 时填充。
    let path: [GridPosition]

    var totalSteps: Int { path.count }

    /// - Parameters:
    ///   - path: 蛇头按时间顺序走过的坐标序列。
    ///   - snakeLength: 蛇身节数。
    ///   - stepDuration: 每步停留时间。
    ///   - pauseDuration: 轮间暂停时间。
    init(path: [GridPosition],
         snakeLength: Int = 5,
         stepDuration: TimeInterval = 0.08,
         pauseDuration: TimeInterval = 1.5) {
        self.path = path
        self.snakeLength = snakeLength
        self.stepDuration = stepDuration
        self.pauseDuration = pauseDuration
    }

    func frame(at step: Int) -> AnimationFrame {
        guard !path.isEmpty, step >= 0 else { return .empty }
        let headIdx = min(step, path.count - 1)
        let tailIdx = max(0, headIdx - snakeLength + 1)

        // 蛇身：头在前；用 reversed() 把"路径上从早到晚"翻转成"从蛇头到蛇尾"。
        let body = (tailIdx...headIdx).reversed().map { path[$0] }

        // 已吃格：path[0...headIdx] 全部计入。用 Set 而非数组方便 O(1) 渲染端查询。
        let eaten = Set(path[0...headIdx])

        return AnimationFrame(snakes: [body], eatenCells: eaten, foodCells: [])
    }
}

// MARK: - 玩法枚举 + 工厂

/// 贪吃蛇玩法（与 AppSettings.snakeStyle 一一对应）。
///
/// 命名前缀对齐 i18n：`settings.snakeStyle.{rawValue}`，新增 case 时同步补 String Catalog。
enum SnakeStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    /// 关闭动画——只看静态草坪。给前庭敏感 / 极简用户用。
    case off
    /// 原 zigzag 横扫——最朴素，蛇路径与用户数据完全无关。
    case zigzag
    /// A. snk 同款贪心——优先吃高级别绿格，蛇路径随用户贡献分布每天不同。
    case greedy
    /// B. 多模式轮换——zigzag / 螺旋 / 对角 / Gilbert 每轮换姿势。
    case multiMode
    /// C. 真·贪吃蛇——追单个食物，吃到 +1 节，越玩越长。
    case foodChase
    /// D. Gilbert 矩形 Hilbert 曲线——蛇像走迷宫一样绕。
    case hilbert
    /// E. 多蛇并发——2 条蛇从左右两侧出发，各吃自己半边。
    case multiSnake

    var id: String { rawValue }

    /// 默认关闭，避免装饰性动画在用户未主动选择前持续占用注意力。
    static let `default`: SnakeStyle = .off

    /// 本地化键。
    var displayNameKey: String { "settings.snakeStyle.\(rawValue)" }

    /// SF Symbol。Settings 页的 Picker label 用得上。
    var systemImage: String {
        switch self {
        case .off:        return "moon.zzz"
        case .zigzag:     return "arrow.left.and.right"
        case .greedy:     return "leaf.fill"
        case .multiMode:  return "shuffle"
        case .foodChase:  return "fork.knife"
        case .hilbert:    return "scribble.variable"
        case .multiSnake: return "rectangle.split.2x1"
        }
    }
}

/// 给定 style + 草坪数据，构造对应的 animator。
///
/// 把"选哪种 animator"这件事集中在工厂里，View 不需要 switch；
/// 新增玩法时只要补一个 case + 一个 builder 即可。
///
/// 返回 nil 表示当前 style 不需要动画（如 `.off`）。
enum SnakeAnimatorFactory {

    /// 标准草坪尺寸（53 周 × 7 天）。所有 animator 共用，集中在工厂里避免散落。
    static let cols: Int = 53
    static let rows: Int = 7

    /// - Parameters:
    ///   - style: 用户在 Settings 里选的玩法。
    ///   - weeks: GitHub 返回的贡献周数组；某些玩法（greedy / foodChase）需要依
    ///     contributionLevel 决策路径，其他玩法可以忽略。允许 nil（数据未到时）。
    static func make(style: SnakeStyle,
                     weeks: [ContributionWeek]?) -> SnakeAnimator? {
        switch style {
        case .off:
            return nil
        case .zigzag:
            return ZigzagSnakeAnimator(cols: cols, rows: rows)
        case .greedy:
            return GreedySnakeAnimator(cols: cols, rows: rows, weeks: weeks)
        case .multiMode:
            return MultiModeSnakeAnimator(cols: cols, rows: rows, weeks: weeks)
        case .foodChase:
            return FoodChaseSnakeAnimator(cols: cols, rows: rows, weeks: weeks)
        case .hilbert:
            return HilbertSnakeAnimator(cols: cols, rows: rows)
        case .multiSnake:
            return MultiSnakeAnimator(cols: cols, rows: rows, weeks: weeks)
        }
    }
}

// MARK: - 共享工具

/// 草坪数据辅助查询。各 animator 复用，避免重复写 `weeks[col].contributionDays[row]` 嵌套。
struct ContributionGrid {

    /// 53 × 7 二维 level 矩阵；缺失格子（账号较新或不满 53 周）按 `.none` 处理。
    /// `grid[col][row]` 直接取，0 ≤ col < cols，0 ≤ row < rows。
    let grid: [[ContributionLevel]]
    let cols: Int
    let rows: Int

    init(weeks: [ContributionWeek]?, cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        var g = Array(repeating: Array(repeating: ContributionLevel.none, count: rows), count: cols)
        guard let weeks else {
            self.grid = g
            return
        }
        // weeks 可能不足 cols 周：按右对齐填充（GitHub 主页一致，最旧在左、最新在右）。
        let startColumn = max(0, cols - weeks.count)
        for (weekIdx, week) in weeks.enumerated() {
            let col = startColumn + weekIdx
            guard col < cols else { break }
            for day in week.contributionDays where day.weekday >= 0 && day.weekday < rows {
                g[col][day.weekday] = day.contributionLevel
            }
        }
        self.grid = g
    }

    func level(at pos: GridPosition) -> ContributionLevel {
        guard pos.col >= 0, pos.col < cols, pos.row >= 0, pos.row < rows else { return .none }
        return grid[pos.col][pos.row]
    }

    /// level 的数字权重：none=0, FQ=1, ..., 4Q=4。用于贪心排序。
    func weight(at pos: GridPosition) -> Int {
        switch level(at: pos) {
        case .none:           return 0
        case .firstQuartile:  return 1
        case .secondQuartile: return 2
        case .thirdQuartile:  return 3
        case .fourthQuartile: return 4
        }
    }

    /// 全部格子坐标。
    var allPositions: [GridPosition] {
        var out: [GridPosition] = []
        out.reserveCapacity(cols * rows)
        for c in 0..<cols { for r in 0..<rows { out.append(GridPosition(col: c, row: r)) } }
        return out
    }
}
