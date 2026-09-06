//
//  HilbertSnakeAnimator.swift
//  Starcat
//
//  贪吃蛇玩法 D：Gilbert 矩形 Hilbert 曲线。
//
//  设计动机
//  ────────
//  - 经典 Hilbert 曲线只在 2ⁿ × 2ⁿ 网格上有定义，53×7 不满足。
//  - Gilbert 算法（Jakub Červený 提出的 "generalized Hilbert"）扩展到任意矩形，
//    保留 Hilbert 的两个核心性质：① 连续 4 连通（相邻 step 永远是邻格）
//                                     ② 局部性好（路径在空间上不大幅跳跃）。
//  - 视觉上像走迷宫，跟 zigzag 的"机械往返"完全不同。
//
//  实现参考：https://github.com/jakubcerveny/gilbert/blob/master/gilbert2d.py
//  这里用迭代版本（避免 Swift 深递归 + inout 数组的尴尬）。
//
//  关键约束
//  ────────
//  - 算法本身 O(N) 时间，N = cols × rows。
//  - 输出路径长度恰好 = cols × rows（每格访问一次，且仅一次）。
//

import Foundation

final class HilbertSnakeAnimator: PathBasedSnakeAnimator, @unchecked Sendable {

    init(cols: Int, rows: Int) {
        let path = Self.buildGilbertPath(width: cols, height: rows)
        // Hilbert 路径长度严格 cols × rows，比 greedy 短；节奏稍慢 100ms 让迷宫感更明显
        super.init(path: path, snakeLength: 5, stepDuration: 0.1, pauseDuration: 1.5)
    }

    /// 生成 Gilbert（generalized Hilbert）路径。
    ///
    /// 算法核心思想（与原版 Hilbert 一致）：把矩形递归分成两半，
    /// 每半内部走子曲线，半与半之间用边界格子连接。Gilbert 的特殊处理是：
    /// - 当 width >= height 时沿 width 方向分；反之沿 height
    /// - 子矩形宽度若是奇数会破坏 Hilbert 性质，需要把"奇数偏移"补给较大的一半
    static func buildGilbertPath(width: Int, height: Int) -> [GridPosition] {
        var out: [GridPosition] = []
        out.reserveCapacity(width * height)
        if width == 0 || height == 0 { return out }
        if width >= height {
            gilbert2d(x: 0, y: 0, ax: width, ay: 0, bx: 0, by: height, into: &out)
        } else {
            gilbert2d(x: 0, y: 0, ax: 0, ay: height, bx: width, by: 0, into: &out)
        }
        return out
    }

    /// 递归生成 Gilbert 曲线。
    ///
    /// 参数解释（沿用原算法符号）：
    /// - `(x, y)`：当前矩形左下角（Cartesian 风格；这里 y 是 row，直接对应 grid）
    /// - `(ax, ay)`：主轴向量（"水平边"方向 + 长度，可负）
    /// - `(bx, by)`：副轴向量（"垂直边"方向 + 长度，可负）
    /// - `out`：累计输出
    ///
    /// 写成 inout 函数而非返回值是因为：路径会很长（~371 格），
    /// 每层递归 return 数组然后 += 会有大量拷贝；inout append 是 O(1) 摊销。
    private static func gilbert2d(x: Int, y: Int,
                                  ax: Int, ay: Int,
                                  bx: Int, by: Int,
                                  into out: inout [GridPosition]) {
        let w = abs(ax) + abs(ay)
        let h = abs(bx) + abs(by)
        let (dax, day) = (sign(ax), sign(ay))
        let (dbx, dby) = (sign(bx), sign(by))

        // 单行：直接沿主轴扫
        if h == 1 {
            var cx = x; var cy = y
            for _ in 0..<w {
                out.append(GridPosition(col: cx, row: cy))
                cx += dax; cy += day
            }
            return
        }
        // 单列：沿副轴扫
        if w == 1 {
            var cx = x; var cy = y
            for _ in 0..<h {
                out.append(GridPosition(col: cx, row: cy))
                cx += dbx; cy += dby
            }
            return
        }

        // 二分：取一半的主轴长度
        var ax2 = ax / 2
        var ay2 = ay / 2
        var bx2 = bx / 2
        var by2 = by / 2
        let w2 = abs(ax2) + abs(ay2)
        let h2 = abs(bx2) + abs(by2)

        if 2 * w > 3 * h {
            // 主轴明显比副轴长 → 分 2 块（保持 Hilbert 性质需要 w2 偶数）
            if (w2 % 2) != 0 && w > 2 {
                ax2 += dax; ay2 += day
            }
            gilbert2d(x: x, y: y,
                      ax: ax2, ay: ay2,
                      bx: bx, by: by,
                      into: &out)
            gilbert2d(x: x + ax2, y: y + ay2,
                      ax: ax - ax2, ay: ay - ay2,
                      bx: bx, by: by,
                      into: &out)
        } else {
            // 否则分 3 块（左下 + 右下 + 上整条），原 Hilbert 标准分法
            if (h2 % 2) != 0 && h > 2 {
                bx2 += dbx; by2 += dby
            }
            // 左下块：副轴半 × 主轴半，方向转置
            gilbert2d(x: x, y: y,
                      ax: bx2, ay: by2,
                      bx: ax2, by: ay2,
                      into: &out)
            // 上块：主轴全 × 副轴另半
            gilbert2d(x: x + bx2, y: y + by2,
                      ax: ax, ay: ay,
                      bx: bx - bx2, by: by - by2,
                      into: &out)
            // 右下块：副轴负半 × 主轴负另半
            gilbert2d(x: x + (ax - dax) + (bx2 - dbx),
                      y: y + (ay - day) + (by2 - dby),
                      ax: -bx2, ay: -by2,
                      bx: -(ax - ax2), by: -(ay - ay2),
                      into: &out)
        }
    }

    private static func sign(_ x: Int) -> Int {
        if x > 0 { return 1 }
        if x < 0 { return -1 }
        return 0
    }
}
