//
//  MultiModeSnakeAnimator.swift
//  Starcat
//
//  贪吃蛇玩法 B：多模式轮换。
//  每一轮从 [zigzag / spiral / diagonal / Gilbert] 4 种路径中按顺序切换，
//  让用户每次看草坪都能尝鲜不同形态。
//
//  设计动机
//  ────────
//  - 单一玩法看久了仍会枯燥；MultiMode 通过"换姿势"延长新鲜感。
//  - 实现上把 4 个 PathBased animator 拼接成一个总动画：
//    `totalSteps = sum(每个子动画的步数)`，frame(at:) 路由到对应子段。
//  - 轮间 pause 由子动画各自的 pauseDuration 处理；总 pauseDuration = 0 避免叠加 pause。
//

import Foundation

final class MultiModeSnakeAnimator: SnakeAnimator, Sendable {

    /// 子玩法序列。按数组顺序循环展示。
    private let subAnimators: [PathBasedSnakeAnimator]

    /// 各子动画起始 step（cumulative）。用于 O(log n) 二分定位 step → 子动画。
    /// `cumulativeStarts[i] = sum(subAnimators[0..<i].totalSteps + 1 (pause as 1 fake step))`
    /// 这里把每个子动画的 pause 转成 N 个"空 step"，让 frame(at:) 在 pause 段返回空 frame。
    private let cumulativeStarts: [Int]

    /// 每个子动画 pause 折算成多少 step（fake steps）。
    /// 用 stepDuration 反推：fakeSteps = pauseDuration / stepDuration（向上取整）。
    private let pauseStepsPerSub: [Int]

    /// 自身 stepDuration / pauseDuration：用第一个子动画的节奏作为参考。
    let stepDuration: TimeInterval
    let pauseDuration: TimeInterval = 0  // 轮间 pause 已折算到 fake step

    let totalSteps: Int

    init(cols: Int, rows: Int, weeks: [ContributionWeek]?) {
        // 4 种子玩法：zigzag / spiral / diagonal / Gilbert
        // 不放 greedy / foodChase / multiSnake——避免本玩法变成"all 玩法套娃"
        let zigzag = ZigzagSnakeAnimator(cols: cols, rows: rows)
        let spiral = SpiralSnakeAnimator(cols: cols, rows: rows)
        let diagonal = DiagonalSnakeAnimator(cols: cols, rows: rows)
        let gilbert = HilbertSnakeAnimator(cols: cols, rows: rows)
        let subs: [PathBasedSnakeAnimator] = [zigzag, spiral, diagonal, gilbert]
        self.subAnimators = subs

        // 节奏对齐：取所有子动画 stepDuration 的平均，简化时间换算
        // （子动画的 stepDuration 都接近，平均近似无损）
        let avgStep = subs.map(\.stepDuration).reduce(0, +) / Double(subs.count)
        self.stepDuration = avgStep

        // 每个子动画的 pause 折算成几个 fake step
        let pauseSteps = subs.map { Int(ceil($0.pauseDuration / avgStep)) }
        self.pauseStepsPerSub = pauseSteps

        // cumulative 起始位置：sub[i] 的 active 区间 = [starts[i], starts[i] + sub.totalSteps)
        // pause 区间 = [starts[i] + sub.totalSteps, starts[i+1])
        var starts: [Int] = []
        var acc = 0
        for i in 0..<subs.count {
            starts.append(acc)
            acc += subs[i].totalSteps + pauseSteps[i]
        }
        self.cumulativeStarts = starts
        self.totalSteps = acc

        // weeks 在本玩法未使用——刻意保留参数签名以便未来加入 greedy 变体
        _ = weeks
    }

    func frame(at step: Int) -> AnimationFrame {
        guard !subAnimators.isEmpty, totalSteps > 0 else { return .empty }
        let s = step.clamped(to: 0...(totalSteps - 1))

        // 二分定位子动画索引
        // 数组才 4 个，直接线性扫，没必要二分
        var idx = subAnimators.count - 1
        for i in 0..<cumulativeStarts.count {
            let next = (i + 1 < cumulativeStarts.count) ? cumulativeStarts[i + 1] : totalSteps
            if s < next { idx = i; break }
        }
        let localStep = s - cumulativeStarts[idx]
        let sub = subAnimators[idx]
        if localStep < sub.totalSteps {
            return sub.frame(at: localStep)
        } else {
            // pause 段：返回"全部已吃 + 空蛇"——让用户看到完整草坪的反相（也可以返回空 eaten）
            // 选择返回"上一帧"（蛇走完整圈，全格已吃）作为定格
            return sub.frame(at: sub.totalSteps - 1)
        }
    }
}

// MARK: - 子玩法：螺旋（spiral）

/// 矩形螺旋：从左上角开始顺时针向内绕圈，最后停在中心附近。
/// 视觉上像"卷起来"，非常对称美观。
final class SpiralSnakeAnimator: PathBasedSnakeAnimator {

    init(cols: Int, rows: Int) {
        super.init(path: Self.buildSpiralPath(cols: cols, rows: rows),
                   snakeLength: 5, stepDuration: 0.1, pauseDuration: 1.2)
    }

    /// 构造矩形螺旋。
    ///
    /// 算法：维护四个边界 (top, bottom, left, right)，按 →↓←↑ 循环，每走完一边收缩对应边界。
    static func buildSpiralPath(cols: Int, rows: Int) -> [GridPosition] {
        var out: [GridPosition] = []
        out.reserveCapacity(cols * rows)
        var top = 0, bottom = rows - 1, left = 0, right = cols - 1
        while top <= bottom && left <= right {
            // 右
            for c in left...right { out.append(GridPosition(col: c, row: top)) }
            top += 1
            // 下
            if top > bottom { break }
            for r in top...bottom { out.append(GridPosition(col: right, row: r)) }
            right -= 1
            // 左
            if left > right { break }
            for c in (left...right).reversed() { out.append(GridPosition(col: c, row: bottom)) }
            bottom -= 1
            // 上
            if top > bottom { break }
            for r in (top...bottom).reversed() { out.append(GridPosition(col: left, row: r)) }
            left += 1
        }
        return out
    }
}

// MARK: - 子玩法：对角（diagonal）

/// 对角线扫描：沿"反对角线"一条一条扫，整张图看起来像被斜着切开。
/// 对 53×7 这种扁矩形效果最明显——每条对角线只有 1~7 个格子，蛇会"飘"过去。
final class DiagonalSnakeAnimator: PathBasedSnakeAnimator {

    init(cols: Int, rows: Int) {
        super.init(path: Self.buildDiagonalPath(cols: cols, rows: rows),
                   snakeLength: 5, stepDuration: 0.07, pauseDuration: 1.2)
    }

    /// 反对角线扫描。
    ///
    /// 算法：以 d = col + row 为对角线编号（0 ~ cols+rows-2），
    /// 对每条对角线按 row 升序枚举（让蛇沿对角线"走斜线"而非"跳跃"）。
    /// 相邻对角线之间会有"跳格"——但视觉上看起来像"梳子梳过"，可接受。
    static func buildDiagonalPath(cols: Int, rows: Int) -> [GridPosition] {
        var out: [GridPosition] = []
        out.reserveCapacity(cols * rows)
        let maxD = cols + rows - 2
        for d in 0...maxD {
            // 蛇形：偶数对角线 row 升序（从右上到左下），奇数倒序（从左下到右上）
            // 让相邻对角线衔接处的跳跃距离最小
            let rowRange = (max(0, d - cols + 1))...(min(rows - 1, d))
            if rowRange.lowerBound > rowRange.upperBound { continue }
            let rows: [Int] = (d % 2 == 0)
                ? Array(rowRange)
                : Array(rowRange).reversed()
            for r in rows {
                let c = d - r
                out.append(GridPosition(col: c, row: r))
            }
        }
        return out
    }
}

// MARK: - Comparable.clamped(to:)

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
