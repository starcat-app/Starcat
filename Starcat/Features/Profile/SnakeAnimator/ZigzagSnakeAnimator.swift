//
//  ZigzagSnakeAnimator.swift
//  Starcat
//
//  贪吃蛇玩法 0：原 zigzag 横扫。
//  保留作为"最朴素、低性能、可预测"的兜底选项。
//
//  路径：列向横扫——偶数列从上到下（row 0 → 6），奇数列从下到上（row 6 → 0），
//  起点 (col=0, row=0)，终点 (col=cols-1, ?)，总步数 = cols × rows。
//
//  特性：
//  - 路径与用户数据完全无关（同样的 53×7 网格永远走同样的路径）
//  - 实现 ≈ 10 行，零运行时开销
//  - 视觉单调，但作为对照组让用户能体会到 greedy / hilbert 的差别
//

import Foundation

final class ZigzagSnakeAnimator: PathBasedSnakeAnimator {

    init(cols: Int, rows: Int) {
        super.init(path: Self.buildPath(cols: cols, rows: rows))
    }

    /// 构造 zigzag 路径。`static` 让相同 cols/rows 不重复算（虽然只算一次，无所谓）。
    static func buildPath(cols: Int, rows: Int) -> [GridPosition] {
        var path: [GridPosition] = []
        path.reserveCapacity(cols * rows)
        for col in 0..<cols {
            if col % 2 == 0 {
                for row in 0..<rows {
                    path.append(GridPosition(col: col, row: row))
                }
            } else {
                for row in (0..<rows).reversed() {
                    path.append(GridPosition(col: col, row: row))
                }
            }
        }
        return path
    }
}
