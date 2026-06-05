//
//  GreedySnakeAnimator.swift
//  Starcat
//
//  贪吃蛇玩法 A：snk 同款贪心吃绿。
//
//  设计动机
//  ────────
//  - snk 原版（Platane/snk）的卖点：蛇路径由用户贡献分布决定，
//    每个用户、每一周看到的形态都不一样——这才是"草坪+蛇"组合的灵魂。
//  - snk 用迭代加深 + 启发式找"最优"路径（NP-hard 的近似），实现复杂。
//  - 我们用一个"贪心 + BFS 寻路"的轻量近似：
//      1. 把所有"绿格"按 (level desc, 距离 asc) 排成目标队列；
//      2. 蛇从 (0, midRow) 出发，每次找队首未吃的目标，BFS 算最短路径过去；
//      3. 沿途经过的所有格子都被"吃掉"（不只是目标格）；
//      4. 绿格吃完后，剩余空格（NONE）按 zigzag 兜底扫完，凑成一轮完整动画。
//
//  视觉效果
//  ────────
//  - 蛇会"嗅着"绿格走，先冲向最密集的绿格区域吃完，再去吃零散的绿格
//  - 因为每用户的贡献分布不同，路径每天看起来都不一样——这就是 snk 的灵魂
//  - 比 zigzag 多了"目的性"，蛇头有"思考"感
//
//  复杂度
//  ──────
//  - 预计算 O(N × BFS_avg) ≈ O(371 × 371) ≈ 14 万次操作，单次 init <50ms（实测 macOS Pro）
//  - 运行时 O(1)（PathBased 滑窗）
//

import Foundation

final class GreedySnakeAnimator: PathBasedSnakeAnimator {

    /// - Parameters:
    ///   - cols: 列数（标准 53）
    ///   - rows: 行数（标准 7）
    ///   - weeks: GitHub 贡献周；nil 时退化为 zigzag（无 level 信息可贪）。
    init(cols: Int, rows: Int, weeks: [ContributionWeek]?) {
        let grid = ContributionGrid(weeks: weeks, cols: cols, rows: rows)
        let path = Self.buildGreedyPath(grid: grid)
        // 贪心路径更长（含 BFS 绕路），节奏稍快避免一轮太久；80ms × ~500 步 ≈ 40s
        super.init(path: path, snakeLength: 5, stepDuration: 0.08, pauseDuration: 1.5)
    }

    /// 贪心构建路径。
    ///
    /// 算法步骤：
    /// 1. 把所有 weight > 0 的格子按 (-weight, manhattan from current head) 排序成目标队列；
    /// 2. 蛇头从 (col=0, row=3) 起（左侧中间，离左上左下都不远）；
    /// 3. 取队首未访问目标，BFS 算最短路径，沿途格子全部加入 path 并标为 visited；
    /// 4. 重复直到队列空或所有格子访问完；
    /// 5. 剩余未访问格子按 zigzag 兜底扫完。
    ///
    /// 关键约束：BFS 不避开蛇身（蛇身只是路径上滑窗，不会"挡路"），
    /// 这与真·贪吃蛇（FoodChase）不同——那里蛇身是物理障碍。
    static func buildGreedyPath(grid: ContributionGrid) -> [GridPosition] {
        let cols = grid.cols
        let rows = grid.rows
        var visited = Set<GridPosition>()
        var path: [GridPosition] = []
        path.reserveCapacity(cols * rows + 50)

        // 起点：左侧中间（snk 风格起点）
        var head = GridPosition(col: 0, row: rows / 2)
        path.append(head)
        visited.insert(head)

        // 收集所有绿格作为优先目标
        var greenTargets = grid.allPositions.filter { grid.weight(at: $0) > 0 }

        // 重复贪心：每轮重排（按当前 head 距离），取队首
        while !greenTargets.isEmpty {
            // 过滤掉已访问的（沿途 BFS 顺带吃掉了）
            greenTargets.removeAll { visited.contains($0) }
            if greenTargets.isEmpty { break }

            // 排序键：(weight desc, manhattan asc)——优先吃高级别绿，平级取最近
            greenTargets.sort { a, b in
                let wa = grid.weight(at: a)
                let wb = grid.weight(at: b)
                if wa != wb { return wa > wb }
                return a.manhattan(to: head) < b.manhattan(to: head)
            }
            guard let target = greenTargets.first else { break }

            // BFS 找最短路径（不避障，因为路径型 animator 蛇身只是滑窗）
            guard let segment = bfsPath(from: head, to: target, cols: cols, rows: rows) else {
                // 理论不可能（4 连通网格永远可达），保险跳过
                greenTargets.removeFirst()
                continue
            }

            // 把 segment（不含起点 head，因为已经在 path 末尾）追加
            for pos in segment.dropFirst() {
                path.append(pos)
                visited.insert(pos)
            }
            head = target
        }

        // 兜底：剩余未访问的 NONE 格按"最近邻"扫尾——比 zigzag 跳跃感小
        // 但为了避免再做一遍贪心调度，简化为按列优先扫剩余
        for col in 0..<cols {
            for row in 0..<rows {
                let pos = GridPosition(col: col, row: row)
                if visited.contains(pos) { continue }
                // BFS 从当前 head 走过去（中间会经过已访问格子，但 path 是允许重复的滑窗）
                if let segment = bfsPath(from: head, to: pos, cols: cols, rows: rows) {
                    for next in segment.dropFirst() {
                        path.append(next)
                        visited.insert(next)
                    }
                    head = pos
                }
            }
        }

        return path
    }

    /// 4 连通 BFS 最短路径。返回 [from, ..., to]；不可达返回 nil。
    ///
    /// 不避障——本 animator 的"蛇身"是路径上的滑窗，物理上不阻挡寻路。
    /// FoodChase 那种"真·蛇"才需要避障版本（见 `FoodChaseSnakeAnimator.bfsPathAvoiding`）。
    static func bfsPath(from start: GridPosition,
                        to goal: GridPosition,
                        cols: Int,
                        rows: Int) -> [GridPosition]? {
        if start == goal { return [start] }
        var came: [GridPosition: GridPosition] = [:]
        var visited = Set<GridPosition>([start])
        var queue: [GridPosition] = [start]
        queue.reserveCapacity(cols * rows)
        var qIdx = 0
        while qIdx < queue.count {
            let cur = queue[qIdx]; qIdx += 1
            if cur == goal { break }
            for n in cur.neighbors4 {
                guard n.col >= 0, n.col < cols, n.row >= 0, n.row < rows else { continue }
                if visited.contains(n) { continue }
                visited.insert(n)
                came[n] = cur
                queue.append(n)
            }
        }
        guard came[goal] != nil || start == goal else { return nil }
        // 回溯
        var path: [GridPosition] = [goal]
        var cur = goal
        while let prev = came[cur] {
            path.append(prev)
            cur = prev
        }
        return path.reversed()
    }
}
