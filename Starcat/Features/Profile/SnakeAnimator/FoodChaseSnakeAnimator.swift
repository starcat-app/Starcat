//
//  FoodChaseSnakeAnimator.swift
//  Starcat
//
//  贪吃蛇玩法 C：真·贪吃蛇——追食物、吃到 +1 节、撞自己结束。
//
//  设计动机
//  ────────
//  - dong4j 想看到"真·贪吃蛇"玩法：有食物、有增长、有结局。
//  - 与其他 5 种"路径滑窗"型不同，本玩法是**状态机**：
//      蛇位置 + 食物位置 + 蛇身长度都是动态的，无法用单条静态路径表达。
//  - 实现策略：**预生成"录像帧"**——init 时把整局游戏离线模拟一遍，
//    存成 [AnimationFrame] 数组，运行时按 step 索引取帧，零运行时开销。
//
//  AI 决策
//  ───────
//  - 食物选择：从所有未被蛇身占据的格子里挑 weight 最高的；同 weight 取最近。
//    （绿格优先 → 蛇追绿格 → 视觉上"挑好的吃"，符合"吃绿草"语义）
//  - 寻路：BFS 最短路径，避开当前蛇身（真·贪吃蛇规则：撞自己 = 游戏结束）。
//  - 找不到路径（被自己围死）→ 游戏结束，蛇身缩成 1 节后整局重启。
//
//  上限
//  ────
//  - 最大帧数 800（≈ 10s @ 80ms/step）：贪吃蛇可能很长，限制避免内存爆炸。
//  - 蛇身最大长度 = grid 总格子数（理论极限 371，真打满几乎不可能）。
//

import Foundation

final class FoodChaseSnakeAnimator: SnakeAnimator, Sendable {

    let stepDuration: TimeInterval = 0.08
    /// pause = 0：每局结束直接重启，"无缝循环"贴近游戏体验。
    let pauseDuration: TimeInterval = 1.0

    private let frames: [AnimationFrame]
    var totalSteps: Int { frames.count }

    init(cols: Int, rows: Int, weeks: [ContributionWeek]?) {
        let grid = ContributionGrid(weeks: weeks, cols: cols, rows: rows)
        self.frames = Self.simulate(grid: grid, maxFrames: 800)
    }

    func frame(at step: Int) -> AnimationFrame {
        guard !frames.isEmpty else { return .empty }
        let idx = step.clamped(to: 0...(frames.count - 1))
        return frames[idx]
    }

    /// 离线模拟一局贪吃蛇并把每帧录下来。
    ///
    /// 状态机循环：
    /// 1. 蛇头在哪？吃到食物了吗？
    /// 2. 如果吃到 → 蛇身 +1，重新选食物
    /// 3. 否则 → BFS 找到食物的路径，沿路径前进一步
    /// 4. 撞墙/无路 → 录"蛇尾巴缩回去"动画 → 结束
    static func simulate(grid: ContributionGrid, maxFrames: Int) -> [AnimationFrame] {
        let cols = grid.cols
        let rows = grid.rows
        var frames: [AnimationFrame] = []
        frames.reserveCapacity(maxFrames)

        // 初始蛇：3 节，水平横躺在 row=3 中间
        var snake: [GridPosition] = [
            GridPosition(col: 2, row: rows / 2),  // head
            GridPosition(col: 1, row: rows / 2),
            GridPosition(col: 0, row: rows / 2)
        ]
        // 已吃过的格子（视觉上让吃过的格子在轮内保持"已吃"状态）
        var eaten: Set<GridPosition> = Set(snake)
        var food: GridPosition? = pickFood(grid: grid, occupied: Set(snake), eaten: eaten)

        var safetyCounter = 0
        while frames.count < maxFrames {
            safetyCounter += 1
            if safetyCounter > maxFrames * 3 { break }  // 防止逻辑 bug 死循环

            guard let target = food else {
                // 没食物可吃了 → 收尾：让蛇身一节一节缩短
                while snake.count > 1 && frames.count < maxFrames {
                    snake.removeLast()
                    frames.append(AnimationFrame(snakes: [snake], eatenCells: eaten, foodCells: []))
                }
                break
            }

            let head = snake[0]
            if head == target {
                // 已经到食物上（首帧巧合或上一步刚到）→ 蛇身 +1（不收尾巴）
                eaten.insert(head)
                food = pickFood(grid: grid, occupied: Set(snake), eaten: eaten)
                // 不录帧——直接进入下一轮"找路"
                continue
            }

            // BFS 找路径，避开当前蛇身（除蛇尾，因为下一帧蛇尾会移走腾出位置）
            let bodyAsObstacle = Set(snake.dropLast())
            guard let segment = bfsPathAvoiding(from: head, to: target,
                                                obstacles: bodyAsObstacle,
                                                cols: cols, rows: rows),
                  segment.count >= 2 else {
                // 被自己围死了 → 收尾
                while snake.count > 1 && frames.count < maxFrames {
                    snake.removeLast()
                    frames.append(AnimationFrame(snakes: [snake], eatenCells: eaten, foodCells: []))
                }
                break
            }

            // 前进一步：head 移到 segment[1]
            let nextHead = segment[1]
            snake.insert(nextHead, at: 0)
            eaten.insert(nextHead)

            if nextHead == target {
                // 吃到食物 → 不移除蛇尾（蛇身 +1）
                let foodSetForFrame: Set<GridPosition> = []
                frames.append(AnimationFrame(snakes: [snake], eatenCells: eaten, foodCells: foodSetForFrame))
                food = pickFood(grid: grid, occupied: Set(snake), eaten: eaten)
            } else {
                // 普通前进 → 移除蛇尾
                _ = snake.removeLast()
                let foodSetForFrame: Set<GridPosition> = food.map { [$0] } ?? []
                frames.append(AnimationFrame(snakes: [snake], eatenCells: eaten, foodCells: foodSetForFrame))
            }
        }

        // 如果一帧都没生成（理论上不会），兜底加一个空帧避免 totalSteps=0 让 view 异常
        if frames.isEmpty {
            frames.append(AnimationFrame(snakes: [snake], eatenCells: eaten, foodCells: []))
        }
        return frames
    }

    /// 选下一颗食物。
    ///
    /// 策略：
    /// 1. 过滤掉被蛇身占据的格子
    /// 2. 优先级：weight desc（更绿的格子先吃）
    /// 3. 相同 weight 取距离蛇头最近的（让游戏紧凑、画面集中）
    /// 4. 如果连未吃且未占的格子都没有了 → 允许重复吃（视觉上不"清空"，但有事可做）
    /// 5. 整张图全占满（蛇身 = grid）→ 返回 nil 触发收尾
    static func pickFood(grid: ContributionGrid,
                         occupied: Set<GridPosition>,
                         eaten: Set<GridPosition>) -> GridPosition? {
        // 第一优先：未占且未吃的绿格
        let candidates = grid.allPositions.filter {
            !occupied.contains($0) && !eaten.contains($0)
        }
        if let pick = pickBest(candidates: candidates, grid: grid) {
            return pick
        }
        // 第二优先：未占（允许已吃，让蛇再次"路过"激活）
        let fallback = grid.allPositions.filter { !occupied.contains($0) }
        return pickBest(candidates: fallback, grid: grid)
    }

    private static func pickBest(candidates: [GridPosition], grid: ContributionGrid) -> GridPosition? {
        guard !candidates.isEmpty else { return nil }
        // 优先 weight 最高
        let maxWeight = candidates.map { grid.weight(at: $0) }.max() ?? 0
        let topTier = candidates.filter { grid.weight(at: $0) == maxWeight }
        // 同档随机一个，避免每次都吃同一个让游戏"看不出随机感"
        return topTier.randomElement()
    }

    /// 避障 BFS。`obstacles` 中的格子不能经过。
    ///
    /// 与 `GreedySnakeAnimator.bfsPath` 的区别：贪心 animator 蛇身是滑窗（不会真的挡路），
    /// 这里 FoodChase 蛇身是物理障碍——撞了 = 死。
    static func bfsPathAvoiding(from start: GridPosition,
                                to goal: GridPosition,
                                obstacles: Set<GridPosition>,
                                cols: Int,
                                rows: Int) -> [GridPosition]? {
        if start == goal { return [start] }
        var came: [GridPosition: GridPosition] = [:]
        var visited: Set<GridPosition> = [start]
        var queue: [GridPosition] = [start]
        queue.reserveCapacity(cols * rows)
        var qIdx = 0
        while qIdx < queue.count {
            let cur = queue[qIdx]; qIdx += 1
            if cur == goal { break }
            for n in cur.neighbors4 {
                guard n.col >= 0, n.col < cols, n.row >= 0, n.row < rows else { continue }
                if visited.contains(n) { continue }
                if obstacles.contains(n) && n != goal { continue }
                visited.insert(n)
                came[n] = cur
                queue.append(n)
            }
        }
        guard came[goal] != nil else { return nil }
        var path: [GridPosition] = [goal]
        var cur = goal
        while let prev = came[cur] {
            path.append(prev)
            cur = prev
        }
        return path.reversed()
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
