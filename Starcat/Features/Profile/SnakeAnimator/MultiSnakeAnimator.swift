//
//  MultiSnakeAnimator.swift
//  Starcat
//
//  贪吃蛇玩法 E：2 条蛇并发。
//
//  设计动机
//  ────────
//  - 单蛇玩法看久了仍嫌"孤独"；2 条蛇分别从草坪两端出发同时吃，视觉冲击 +1。
//  - 把 53×7 网格按列分成左半（cols 0..<27）+ 右半（cols 27..<53），
//    每条蛇在自己半边独立用 greedy 算法吃，互不干涉、零碰撞逻辑。
//
//  实现细节
//  ────────
//  - 两条蛇的路径独立预计算（GreedySnakeAnimator 复用），步数可能不同。
//  - totalSteps = max(leftSteps, rightSteps)；较短一边走完后定在最后一帧（不退场）。
//  - frame(at:) 合并两条蛇的快照：snakes = [leftBody, rightBody]，
//    eatenCells = leftEaten ∪ rightEaten。
//

import Foundation

final class MultiSnakeAnimator: SnakeAnimator, Sendable {

    private let leftAnimator: PathBasedSnakeAnimator
    private let rightAnimator: PathBasedSnakeAnimator

    let totalSteps: Int
    let stepDuration: TimeInterval = 0.08
    let pauseDuration: TimeInterval = 1.5

    init(cols: Int, rows: Int, weeks: [ContributionWeek]?) {
        // 按列对半分。奇数列时左多右少（左拿 27、右拿 26）
        let leftCols = cols / 2 + (cols % 2)
        let rightCols = cols - leftCols

        // 左半草坪
        let leftWeeks = Self.sliceWeeks(weeks, fromCol: 0, count: leftCols, totalCols: cols)
        let leftGrid = ContributionGrid(weeks: leftWeeks, cols: leftCols, rows: rows)
        let leftPath = GreedySnakeAnimator.buildGreedyPath(grid: leftGrid)
        self.leftAnimator = PathBasedSnakeAnimator(path: leftPath, snakeLength: 4,
                                                   stepDuration: 0.08, pauseDuration: 0)

        // 右半草坪：路径用右半 grid 算，但坐标要平移回原网格（col += leftCols）
        let rightWeeks = Self.sliceWeeks(weeks, fromCol: leftCols, count: rightCols, totalCols: cols)
        let rightGrid = ContributionGrid(weeks: rightWeeks, cols: rightCols, rows: rows)
        let rightPathLocal = GreedySnakeAnimator.buildGreedyPath(grid: rightGrid)
        // 反向：右蛇从右往左吃（视觉对称感强）
        let rightPath = rightPathLocal.reversed().map {
            GridPosition(col: $0.col + leftCols, row: $0.row)
        }
        self.rightAnimator = PathBasedSnakeAnimator(path: rightPath, snakeLength: 4,
                                                    stepDuration: 0.08, pauseDuration: 0)

        self.totalSteps = max(leftAnimator.totalSteps, rightAnimator.totalSteps)
    }

    func frame(at step: Int) -> AnimationFrame {
        let leftStep = min(step, leftAnimator.totalSteps - 1)
        let rightStep = min(step, rightAnimator.totalSteps - 1)
        let leftFrame = leftAnimator.frame(at: leftStep)
        let rightFrame = rightAnimator.frame(at: rightStep)
        return AnimationFrame(
            snakes: leftFrame.snakes + rightFrame.snakes,
            eatenCells: leftFrame.eatenCells.union(rightFrame.eatenCells),
            foodCells: []
        )
    }

    /// 把原 weeks 数组按"右对齐"裁剪出 [fromCol, fromCol+count) 列。
    ///
    /// 注意：GitHub 的 weeks 数组是按时间正序，且 startColumn = max(0, totalCols - weeks.count)。
    /// 我们要把"网格列 fromCol..<fromCol+count" 对应回 weeks 数组的索引。
    static func sliceWeeks(_ weeks: [ContributionWeek]?,
                           fromCol: Int,
                           count: Int,
                           totalCols: Int) -> [ContributionWeek]? {
        guard let weeks else { return nil }
        let startColumn = max(0, totalCols - weeks.count)
        // 目标网格列 fromCol..<fromCol+count 对应到 weeks 索引：
        // weeksIdx = gridCol - startColumn
        let lo = max(0, fromCol - startColumn)
        let hi = max(lo, min(weeks.count, fromCol + count - startColumn))
        if lo >= hi { return [] }
        return Array(weeks[lo..<hi])
    }
}
