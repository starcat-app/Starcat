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

    init(grid: ContributionGrid) {
        let cols = grid.cols
        // 按列对半分。奇数列时左多右少（左拿 27、右拿 26）
        let leftCols = cols / 2 + (cols % 2)
        let rightCols = cols - leftCols

        // 左半草坪
        let leftGrid = grid.columns(0..<leftCols)
        let leftPath = GreedySnakeAnimator.buildGreedyPath(grid: leftGrid)
        self.leftAnimator = PathBasedSnakeAnimator(path: leftPath, snakeLength: 4,
                                                   stepDuration: 0.08, pauseDuration: 0)

        // 右半草坪：路径用右半 grid 算，但坐标要平移回原网格（col += leftCols）
        let rightGrid = grid.columns(leftCols..<(leftCols + rightCols))
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

}
