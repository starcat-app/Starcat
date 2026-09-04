//
//  SnakeFrameRenderer.swift
//  Starcat
//
//  贡献草坪 + 贪吃蛇的 CGContext 后台渲染器。
//
//  原 `TimelineView(.animation)` + `Canvas` 的 `GraphicsContext` 只能在主线程绘制，
//  切换模块/分类时主线程被 body 重算 + 视图树构建占用，蛇身动画就掉帧。
//  这里改用 Core Graphics 的 `CGContext`，让每帧 371 格的重绘在后台 actor 完成，
//  主线程只做 `Image(cgImage:)` 显示，从而把动画的「重活」移出主线程。
//
//  所有绘制函数都是纯函数（不依赖 @MainActor），可在任意后台线程 / actor 调用。
//

import SwiftUI
import AppKit

/// 贡献草坪 + 贪吃蛇一帧的 CGContext 渲染器。
enum SnakeFrameRenderer {

    /// 草坪布局常量。与 `ContributionGraphView` 的 cell 常量保持一致。
    struct Layout {
        let cols: Int
        let rows: Int
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        let cellSpacing: CGFloat
        let cellCornerRadius: CGFloat

        var size: CGSize {
            CGSize(
                width: CGFloat(cols) * cellWidth + CGFloat(cols - 1) * cellSpacing,
                height: CGFloat(rows) * cellHeight + CGFloat(rows - 1) * cellSpacing
            )
        }

        static let standard = Layout(
            cols: 53, rows: 7,
            cellWidth: 10, cellHeight: 14,
            cellSpacing: 2, cellCornerRadius: 2
        )
    }

    /// 渲染一帧为 CGImage（后台线程安全）。返回 nil 表示尺寸非法。
    static func render(
        payload: ContributionCalendarPayload?,
        frame: AnimationFrame,
        colorScheme: ColorScheme,
        layout: Layout = .standard,
        time: Date = Date()
    ) -> CGImage? {
        let size = layout.size
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard width > 0, height > 0,
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // 翻转 y 轴：CGContext 原点在左下、y 向上，而草坪 row 0 应显示在顶部。
        // 翻转后 row 0 落在 y=0（顶部），与 SwiftUI Canvas 行为一致。
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        let palette = ContributionPalette.palette(for: colorScheme)

        drawGrid(ctx: ctx, payload: payload, frame: frame, palette: palette, layout: layout)
        drawSnakes(ctx: ctx, frame: frame, palette: palette, layout: layout)
        drawFood(ctx: ctx, frame: frame, time: time, layout: layout)

        return ctx.makeImage()
    }

    // MARK: - 草坪

    private static func drawGrid(
        ctx: CGContext,
        payload: ContributionCalendarPayload?,
        frame: AnimationFrame,
        palette: ContributionPalette,
        layout: Layout
    ) {
        guard let weeks = payload?.weeks else {
            drawPlaceholderGrid(ctx: ctx, palette: palette, layout: layout)
            return
        }
        let startColumn = max(0, layout.cols - weeks.count)
        for (weekIdx, week) in weeks.enumerated() {
            let col = startColumn + weekIdx
            let x = CGFloat(col) * (layout.cellWidth + layout.cellSpacing)
            for day in week.contributionDays {
                let row = day.weekday
                let y = CGFloat(row) * (layout.cellHeight + layout.cellSpacing)
                let rect = CGRect(x: x, y: y, width: layout.cellWidth, height: layout.cellHeight)
                let pos = GridPosition(col: col, row: row)
                let level = frame.eatenCells.contains(pos) ? ContributionLevel.none : day.contributionLevel
                fillRoundedRect(ctx, rect, corner: layout.cellCornerRadius, color: palette.color(for: level).cg)
            }
        }
    }

    private static func drawPlaceholderGrid(
        ctx: CGContext,
        palette: ContributionPalette,
        layout: Layout
    ) {
        let color = palette.color(for: .none).cg
        for col in 0..<layout.cols {
            for row in 0..<layout.rows {
                let x = CGFloat(col) * (layout.cellWidth + layout.cellSpacing)
                let y = CGFloat(row) * (layout.cellHeight + layout.cellSpacing)
                let rect = CGRect(x: x, y: y, width: layout.cellWidth, height: layout.cellHeight)
                fillRoundedRect(ctx, rect, corner: layout.cellCornerRadius, color: color)
            }
        }
    }

    // MARK: - 蛇身

    private static func drawSnakes(
        ctx: CGContext,
        frame: AnimationFrame,
        palette: ContributionPalette,
        layout: Layout,
        maxRenderedSegments: Int = 16
    ) {
        guard !frame.snakes.isEmpty else { return }
        let snakeColor = palette.color(for: .fourthQuartile)
        for body in frame.snakes {
            let segCount = min(body.count, maxRenderedSegments)
            for i in 0..<segCount {
                let pos = body[i]
                let baseX = CGFloat(pos.col) * (layout.cellWidth + layout.cellSpacing)
                let baseY = CGFloat(pos.row) * (layout.cellHeight + layout.cellSpacing)

                // alpha 阶梯：head 1.0；之后每节线性衰减至 0.2。
                let alpha: CGFloat = (i == 0) ? 1.0
                    : max(0.2, 0.85 - CGFloat(i - 1) * (0.65 / CGFloat(max(1, segCount - 1))))

                // 蛇头放大到 1.2x，向中心展开。
                let inflate: CGFloat = (i == 0) ? 0.2 : 0.0
                let segW = layout.cellWidth * (1.0 + inflate)
                let segH = layout.cellHeight * (1.0 + inflate)
                let rect = CGRect(
                    x: baseX - (segW - layout.cellWidth) / 2,
                    y: baseY - (segH - layout.cellHeight) / 2,
                    width: segW,
                    height: segH
                )
                let segCorner = layout.cellCornerRadius * (1.0 + inflate)
                fillRoundedRect(ctx, rect, corner: segCorner, color: snakeColor.cg.withAlpha(alpha))
            }
        }
    }

    // MARK: - 食物

    private static func drawFood(
        ctx: CGContext,
        frame: AnimationFrame,
        time: Date,
        layout: Layout
    ) {
        guard !frame.foodCells.isEmpty else { return }
        // 1Hz 呼吸：sin(2π·t) 映射到 [0.4, 1.0]。
        let phase = time.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
        let pulse = 0.7 + 0.3 * sin(phase * 2 * .pi)
        let foodColor = NSColor(srgbRed: 1.0, green: 0.69, blue: 0.18, alpha: 1.0)

        for pos in frame.foodCells {
            let baseX = CGFloat(pos.col) * (layout.cellWidth + layout.cellSpacing)
            let baseY = CGFloat(pos.row) * (layout.cellHeight + layout.cellSpacing)
            let rect = CGRect(x: baseX, y: baseY, width: layout.cellWidth, height: layout.cellHeight)
            fillRoundedRect(
                ctx, rect, corner: layout.cellCornerRadius,
                color: foodColor.withAlphaComponent(0.58 + 0.22 * pulse).cgColor
            )

            let lineWidth = max(0.75, 1.0)
            let insetRect = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path = CGPath(
                roundedRect: insetRect,
                cornerWidth: max(0, layout.cellCornerRadius - lineWidth / 2),
                cornerHeight: max(0, layout.cellCornerRadius - lineWidth / 2),
                transform: nil
            )
            ctx.addPath(path)
            ctx.setStrokeColor(foodColor.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.strokePath()
        }
    }

    // MARK: - Helpers

    private static func fillRoundedRect(
        _ ctx: CGContext,
        _ rect: CGRect,
        corner: CGFloat,
        color: CGColor
    ) {
        let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }
}

// MARK: - Color / CGColor 转换

private extension Color {
    /// SwiftUI Color → CGColor（sRGB 优先，失败回退 NSColor.cgColor）。
    var cg: CGColor {
        NSColor(self).usingColorSpace(.sRGB)?.cgColor ?? NSColor(self).cgColor
    }
}

private extension CGColor {
    /// 返回带指定 alpha 的 CGColor。
    func withAlpha(_ alpha: CGFloat) -> CGColor {
        copy(alpha: alpha) ?? self
    }
}
