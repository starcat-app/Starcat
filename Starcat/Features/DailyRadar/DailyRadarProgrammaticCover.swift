//
//  DailyRadarProgrammaticCover.swift
//  Starcat
//
//  每日热点程序化封面：AI 生成封面（hero_url）未下发或下载失败时的本地兜底。
//
//  设计（2026-11-01 dong4j 定调「千变万化、越随机越好、越抽象越好」）：
//  放弃具象母题（终端/机器人等固定形状），改为【生成艺术组合系统】——
//  8 种抽象风格原语（流线 / 粒子场 / 弧环 / 辐射束 / 山脊线 / 波纹网格 / 碎片 / 色带）
//  按 seed 随机选 1 主 1~2 次叠加，每张图的构图、密度、配色、焦点全部由
//  确定性随机数流抽出。同报告永远同一画面（跨启动、跨用户一致），
//  报告之间近乎无限变化；分类辨识只保留色相基座（12 分类色相 + seed 偏移）。
//
//  关键约束：
//  - 确定性：Canvas 闭包每帧重跑，随机数必须从 seed 重建同序列——用
//    splitmix64 PRNG，绝不能用 SystemRandomNumberGenerator。
//  - 无符号下溢：PRNG 内部显式 &+ &*；seed 派生做减法一律先转 Int
//    （2026-11-01 已踩：UInt64 余数直接减常数 SIGTRAP 崩溃）。
//  - 文字安全区（textSafeLeading）：featured 大卡左侧叠标题/摘要，
//    焦点与焦点型原语（粒子/环/辐射）整体右移；其余场景居中。
//  - 性能预算：单张 ≤ 400 个绘制元素，Canvas 一次构建 Path 批量 stroke/fill，
//    列表滚动多卡同时绘制无压力；矢量适配任意窗口宽度与界面缩放。
//  - 类型检查器：原语方法内长算术链拆局部变量，避免 "unable to type-check"。
//

import SwiftUI

// MARK: - 确定性随机

/// splitmix64：从 seed 展开确定性随机流。Canvas 每帧用同一 seed 重建，
/// 重放同一序列，保证逐帧一致、跨启动一致。
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// [0, 1)
    mutating func double() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// [a, b)
    mutating func range(_ a: Double, _ b: Double) -> Double {
        a + double() * (b - a)
    }

    /// [0, n)
    mutating func int(_ n: Int) -> Int {
        Int(next() % UInt64(max(n, 1)))
    }

    mutating func bool(probability: Double) -> Bool {
        double() < probability
    }

    mutating func pick<T>(_ options: [T]) -> T {
        options[int(options.count)]
    }
}

// MARK: - 配色

/// 单张封面的配色方案：从分类色相基座出发，seed 决定偏移与第二色相。
private struct CoverPalette {
    let hueA: Double
    let hueB: Double
    let hueC: Double

    /// 主渐变色（t: 0→1 在第一、第二色相间插值）。
    func color(at t: Double) -> Color {
        let clamped = min(max(t, 0), 1)
        let hue = hueA + (hueB - hueA) * clamped
        let brightness = 0.62 + clamped * 0.30
        return Color(hue: hue, saturation: 0.78, brightness: brightness)
    }

    var backgroundTop: Color {
        Color(hue: hueC, saturation: 0.44, brightness: 0.15)
    }

    var backgroundBottom: Color {
        Color(hue: hueC + 0.05, saturation: 0.52, brightness: 0.08)
    }
}

// MARK: - 视图

struct DailyRadarProgrammaticCover: View {
    let category: String?
    /// 稳定 seed：调用方传报告 id（含期次日期），驱动全部差异的唯一来源。
    let seed: String
    /// 左侧文字安全区占比（0~0.4）：featured 大卡叠标题/摘要时传入，
    /// 焦点与焦点型原语右移；其余场景保持 0（居中）。
    var textSafeLeading: CGFloat = 0

    var body: some View {
        Canvas { context, size in
            let canvasRect = CGRect(origin: .zero, size: size)
            var rng = SeededGenerator(seed: Self.stableHash(seed))
            let palette = Self.makePalette(category: category, rng: &rng)
            let subjectX = Double(textSafeLeading) + (1 - Double(textSafeLeading)) / 2

            Self.drawBackground(context, size: size, palette: palette, rng: &rng)
            Self.drawUnderlay(context, canvasRect: canvasRect, rng: &rng, palette: palette)

            // 主原语压轴绘制；末位 = 主（全强度），其余陪衬压暗。
            let primitives = Self.pickPrimitives(rng: &rng)
            for (index, primitive) in primitives.enumerated() {
                let isMain = index == primitives.count - 1
                let intensity = isMain ? 1.0 : 0.42
                Self.drawPrimitive(primitive, context: context, rect: canvasRect,
                                   rng: &rng, palette: palette,
                                   subjectX: subjectX, intensity: intensity)
            }

            Self.drawSparks(context, rect: canvasRect, rng: &rng,
                            palette: palette, subjectX: subjectX)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 组合与配色

    private static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 5381
        for scalar in value.unicodeScalars {
            hash = (hash &* 33) &+ UInt64(scalar.value)
        }
        return hash
    }

    /// 分类色相基座（品牌来源对齐官方色）；seed 决定偏移与第二/背景色相。
    private static func baseHue(for category: String?) -> Double {
        switch category {
        case "ai-cli": return 0.52
        case "ai-agents": return 0.30
        case "ai-infra": return 0.72
        case "ai-web": return 0.58
        case "ai-trending": return 0.93
        case "ai-hn": return 0.07
        case "ai-ph": return 0.03
        case "ai-arxiv": return 0.99
        case "ai-hf": return 0.13
        case "ai-community": return 0.40
        case "ai-weekly": return 0.78
        case "ai-monthly": return 0.62
        default: return 0.58
        }
    }

    private static func makePalette(category: String?, rng: inout SeededGenerator) -> CoverPalette {
        let shift = (rng.double() - 0.5) * 0.09
        let hueA = baseHue(for: category) + shift
        let hueB = hueA + rng.range(-0.20, 0.20)
        let hueC = hueA + rng.range(-0.08, 0.10)
        return CoverPalette(hueA: hueA, hueB: hueB, hueC: hueC)
    }

    /// 主 1 + 次 1~2：从 8 原语池抽，互不重复。主原语放在数组末尾（最后绘制、
    /// 压在陪衬之上）。8×7×6 组合 × 各原语连续参数 → 近乎无限。
    private static func pickPrimitives(rng: inout SeededGenerator) -> [CoverPrimitive] {
        let pool: [CoverPrimitive] = [.flowLines, .particles, .rings, .ridgeLines,
                                      .waveGrid, .rays, .shards, .bands]
        let main = rng.pick(pool)
        var underlayers: [CoverPrimitive] = []
        let extra = 1 + rng.int(2)
        while underlayers.count < extra {
            let candidate = rng.pick(pool)
            if candidate != main, !underlayers.contains(candidate) {
                underlayers.append(candidate)
            }
        }
        return underlayers + [main]
    }

    // MARK: - 背景与整体层

    /// 背景渐变：深色双停靠，角度由 rng 抽取。
    private static func drawBackground(_ ctx: GraphicsContext, size: CGSize,
                                       palette: CoverPalette, rng: inout SeededGenerator) {
        let bgAngle = rng.double() * 2 * .pi
        let halfW = size.width / 2
        let halfH = size.height / 2
        let start = CGPoint(x: halfW - cos(bgAngle) * halfW, y: halfH - sin(bgAngle) * halfH)
        let end = CGPoint(x: size.width - start.x, y: size.height - start.y)
        let gradient = Gradient(colors: [palette.backgroundTop, palette.backgroundBottom])
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(gradient, startPoint: start, endPoint: end))
    }

    /// 底层大形状：约 60% 报告出现一个极低透明度大圆盘或斜带，给画面铺底层次。
    private static func drawUnderlay(_ ctx: GraphicsContext, canvasRect: CGRect,
                                     rng: inout SeededGenerator, palette: CoverPalette) {
        guard rng.bool(probability: 0.6) else { return }
        let center = CGPoint(x: canvasRect.width * rng.range(0.25, 0.75),
                             y: canvasRect.height * rng.range(0.25, 0.75))
        let radius = min(canvasRect.width, canvasRect.height) * rng.range(0.55, 0.95)
        if rng.bool(probability: 0.5) {
            let rect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(palette.color(at: rng.double()).opacity(0.05)))
        } else {
            var band = ctx
            band.translateBy(x: center.x, y: center.y)
            band.rotate(by: .radians(rng.range(-0.5, 0.5)))
            let width = radius * 2
            let height = min(canvasRect.width, canvasRect.height) * rng.range(0.18, 0.4)
            band.fill(Path(CGRect(x: -width / 2, y: -height / 2, width: width, height: height)),
                      with: .color(palette.color(at: rng.double()).opacity(0.05)))
        }
    }

    /// 前景亮点点缀：4~16 枚小亮点（白/主色），给抽象构图收焦点。
    private static func drawSparks(_ ctx: GraphicsContext, rect: CGRect,
                                   rng: inout SeededGenerator, palette: CoverPalette,
                                   subjectX: Double) {
        let count = 4 + rng.int(13)
        for _ in 0..<count {
            let nearFocus = rng.bool(probability: 0.55)
            let baseX = nearFocus ? subjectX : 0.5
            let x = rect.width * (baseX + (rng.double() - 0.5) * 0.7)
            let y = rect.height * rng.range(0.08, 0.92)
            let dot = rect.height * rng.range(0.004, 0.011)
            let color: Color = rng.bool(probability: 0.4) ? .white : palette.color(at: rng.double())
            ctx.fill(Path(ellipseIn: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2)),
                     with: .color(color.opacity(rng.range(0.5, 0.95))))
        }
    }

    // MARK: - 原语分发

    private static func drawPrimitive(_ primitive: CoverPrimitive, context: GraphicsContext,
                                      rect: CGRect, rng: inout SeededGenerator,
                                      palette: CoverPalette, subjectX: Double, intensity: Double) {
        var ctx = context
        switch primitive {
        case .flowLines:
            drawFlowLines(&ctx, rect: rect, rng: &rng, palette: palette, intensity: intensity)
        case .particles:
            drawParticles(&ctx, rect: rect, rng: &rng, palette: palette, subjectX: subjectX, intensity: intensity)
        case .rings:
            drawRings(&ctx, rect: rect, rng: &rng, palette: palette, subjectX: subjectX, intensity: intensity)
        case .ridgeLines:
            drawRidgeLines(&ctx, rect: rect, rng: &rng, palette: palette, intensity: intensity)
        case .waveGrid:
            drawWaveGrid(&ctx, rect: rect, rng: &rng, palette: palette, intensity: intensity)
        case .rays:
            drawRays(&ctx, rect: rect, rng: &rng, palette: palette, subjectX: subjectX, intensity: intensity)
        case .shards:
            drawShards(&ctx, rect: rect, rng: &rng, palette: palette, subjectX: subjectX, intensity: intensity)
        case .bands:
            drawBands(&ctx, rect: rect, rng: &rng, palette: palette, subjectX: subjectX, intensity: intensity)
        }
    }

    // MARK: - 风格原语

    /// 参数化流线：横向贝塞尔束，条数/波幅/频率/斜率/抖动全随机。
    private static func drawFlowLines(_ ctx: inout GraphicsContext, rect: CGRect,
                                      rng: inout SeededGenerator, palette: CoverPalette,
                                      intensity: Double) {
        let count = 8 + rng.int(14)
        let amplitude = rect.height * rng.range(0.06, 0.22)
        let frequency = rng.range(1.2, 3.4)
        let phase = rng.double() * 2 * .pi
        let tilt = rng.range(-0.22, 0.22)
        let baseWidth = rng.range(0.8, 2.6)
        for index in 0..<count {
            let t = Double(index) / Double(max(count - 1, 1))
            let baseline = rect.minY + rect.height * (0.12 + t * 0.76) + rect.width * tilt * (t - 0.5)
            var path = Path()
            let segments = 6 + rng.int(4)
            var previous = CGPoint(x: rect.minX,
                                   y: baseline + sin(phase + t * 2.2) * amplitude)
            path.move(to: previous)
            for segment in 1...segments {
                let x = rect.minX + rect.width * Double(segment) / Double(segments)
                let wave = sin(Double(segment) / Double(segments) * frequency * 2 * .pi + phase + t * 2.2) * amplitude
                let jitter = (rng.double() - 0.5) * amplitude * 0.35
                let current = CGPoint(x: x, y: baseline + wave + jitter)
                let midX = (previous.x + current.x) / 2
                path.addQuadCurve(to: current, control: CGPoint(x: midX, y: previous.y))
                previous = current
            }
            let color = palette.color(at: t)
            ctx.stroke(path,
                       with: .color(color.opacity(rng.range(0.28, 0.85) * intensity)),
                       lineWidth: baseWidth * rng.range(0.6, 1.5))
        }
    }

    /// 粒子场：高斯散布 / 环带 / 正弦带三种分布随机一种，围绕焦点。
    private static func drawParticles(_ ctx: inout GraphicsContext, rect: CGRect,
                                      rng: inout SeededGenerator, palette: CoverPalette,
                                      subjectX: Double, intensity: Double) {
        let count = 60 + rng.int(160)
        let focus = CGPoint(x: rect.width * subjectX, y: rect.height * rng.range(0.35, 0.65))
        let distribution = rng.int(3)
        let spread = min(rect.width, rect.height) * rng.range(0.30, 0.65)
        let bandPhase = rng.double() * 2 * .pi
        let bandFreq = rng.range(1.5, 3.5)
        let ringRadius = spread * rng.range(0.5, 0.9)
        for _ in 0..<count {
            var x: Double
            var y: Double
            switch distribution {
            case 0:
                x = focus.x + (rng.double() + rng.double() - 1) * spread
                y = focus.y + (rng.double() + rng.double() - 1) * spread
            case 1:
                let angle = rng.double() * 2 * .pi
                let radius = ringRadius * rng.range(0.82, 1.18)
                x = focus.x + cos(angle) * radius
                y = focus.y + sin(angle) * radius * rng.range(0.75, 1.0)
            default:
                let bandY = rect.height * rng.range(0.2, 0.8)
                x = rect.width * rng.range(0.05, 0.95)
                y = bandY + sin(x / rect.width * bandFreq * 2 * .pi + bandPhase) * spread * 0.3
            }
            let dot = rect.height * rng.range(0.003, 0.010)
            let distance = hypot(x - focus.x, y - focus.y) / spread
            let fade = max(0.25, 1 - distance * 0.7)
            let color: Color = rng.bool(probability: 0.7) ? palette.color(at: rng.double()) : .white
            ctx.fill(Path(ellipseIn: CGRect(x: x - dot, y: y - dot, width: dot * 2, height: dot * 2)),
                     with: .color(color.opacity(rng.range(0.3, 0.9) * fade * intensity)))
        }
    }

    /// 弧环：以焦点为圆心的缺口弧环组，半径/跨度/相位逐环随机。
    private static func drawRings(_ ctx: inout GraphicsContext, rect: CGRect,
                                  rng: inout SeededGenerator, palette: CoverPalette,
                                  subjectX: Double, intensity: Double) {
        let count = 4 + rng.int(6)
        let center = CGPoint(x: rect.width * (subjectX + (rng.double() - 0.5) * 0.12),
                             y: rect.height * rng.range(0.38, 0.62))
        let baseRadius = min(rect.width, rect.height) * rng.range(0.06, 0.14)
        let step = min(rect.width, rect.height) * rng.range(0.05, 0.10)
        let lineWidth = rng.range(1.0, 3.2)
        for index in 0..<count {
            let radius = baseRadius + Double(index) * step
            let start = rng.double() * 2 * .pi
            let span = rng.range(0.6, 1.9) * .pi
            var arc = Path()
            arc.addArc(center: center, radius: radius,
                       startAngle: .radians(start), endAngle: .radians(start + span),
                       clockwise: false)
            let color = index % 2 == 0 ? palette.color(at: Double(index) / Double(count)) : palette.color(at: 1)
            ctx.stroke(arc, with: .color(color.opacity(rng.range(0.25, 0.8) * intensity)),
                       lineWidth: lineWidth * rng.range(0.6, 1.4))
        }
    }

    /// 山脊线：平滑噪声驱动的横向折线束，自下而上逐层抬升（等高线地形感）。
    private static func drawRidgeLines(_ ctx: inout GraphicsContext, rect: CGRect,
                                       rng: inout SeededGenerator, palette: CoverPalette,
                                       intensity: Double) {
        let rows = 5 + rng.int(7)
        let points = 8 + rng.int(7)
        let amplitude = rect.height * rng.range(0.05, 0.16)
        let freqA = rng.range(1.0, 2.6)
        let freqB = rng.range(3.0, 6.5)
        let phase = rng.double() * 2 * .pi
        let lineWidth = rng.range(1.0, 2.4)
        for row in 0..<rows {
            let t = Double(row) / Double(max(rows - 1, 1))
            let baseline = rect.maxY - rect.height * (0.10 + t * 0.72)
            var path = Path()
            for point in 0...points {
                let x = rect.minX + rect.width * Double(point) / Double(points)
                let u = Double(point) / Double(points)
                let noise = sin(u * freqA * 2 * .pi + phase + t * 1.4) * amplitude
                    + sin(u * freqB * 2 * .pi + phase * 1.7) * amplitude * 0.45
                let location = CGPoint(x: x, y: baseline - noise)
                if point == 0 {
                    path.move(to: location)
                } else {
                    path.addLine(to: location)
                }
            }
            ctx.stroke(path, with: .color(palette.color(at: t).opacity(rng.range(0.3, 0.8) * intensity)),
                       lineWidth: lineWidth * rng.range(0.6, 1.3))
        }
    }

    /// 波纹网格：正弦形变横线束，频率/相位/幅度随机，可选竖线。
    private static func drawWaveGrid(_ ctx: inout GraphicsContext, rect: CGRect,
                                     rng: inout SeededGenerator, palette: CoverPalette,
                                     intensity: Double) {
        let lines = 7 + rng.int(12)
        let points = 22 + rng.int(18)
        let amplitude = rect.height * rng.range(0.04, 0.14)
        let frequency = rng.range(1.0, 4.0)
        let phase = rng.double() * 2 * .pi
        let lineWidth = rng.range(0.8, 2.0)
        let withVertical = rng.bool(probability: 0.35)
        for line in 0..<lines {
            let t = Double(line) / Double(max(lines - 1, 1))
            let baseline = rect.minY + rect.height * (0.14 + t * 0.72)
            var path = Path()
            for point in 0...points {
                let x = rect.minX + rect.width * Double(point) / Double(points)
                let y = baseline + sin(x / rect.width * frequency * 2 * .pi + phase + t * 2.0) * amplitude
                let location = CGPoint(x: x, y: y)
                if point == 0 {
                    path.move(to: location)
                } else {
                    path.addLine(to: location)
                }
            }
            ctx.stroke(path, with: .color(palette.color(at: t).opacity(rng.range(0.22, 0.7) * intensity)),
                       lineWidth: lineWidth)
        }
        if withVertical {
            let verticals = 4 + rng.int(8)
            for column in 0..<verticals {
                let x = rect.minX + rect.width * Double(column + 1) / Double(verticals + 1)
                var path = Path()
                path.move(to: CGPoint(x: x, y: rect.minY + rect.height * 0.12))
                path.addLine(to: CGPoint(x: x, y: rect.maxY - rect.height * 0.12))
                ctx.stroke(path, with: .color(palette.color(at: rng.double()).opacity(0.18 * intensity)),
                           lineWidth: lineWidth * 0.7)
            }
        }
    }

    /// 辐射束：以焦点为中心的放射线段，角度均布 + 抖动，长短疏密随机。
    private static func drawRays(_ ctx: inout GraphicsContext, rect: CGRect,
                                 rng: inout SeededGenerator, palette: CoverPalette,
                                 subjectX: Double, intensity: Double) {
        let count = 14 + rng.int(22)
        let center = CGPoint(x: rect.width * subjectX, y: rect.height * rng.range(0.4, 0.6))
        let inner = min(rect.width, rect.height) * rng.range(0.04, 0.12)
        let maxLength = min(rect.width, rect.height) * rng.range(0.35, 0.7)
        let sweep = rng.bool(probability: 0.5) ? 2 * .pi : rng.range(0.9, 2.1) * .pi
        let startAngle = rng.double() * 2 * .pi
        let lineWidth = rng.range(0.8, 2.2)
        for index in 0..<count {
            let angle = startAngle + Double(index) / Double(count) * sweep + (rng.double() - 0.5) * 0.08
            let length = maxLength * rng.range(0.3, 1.0)
            let from = CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner)
            let to = CGPoint(x: center.x + cos(angle) * (inner + length),
                             y: center.y + sin(angle) * (inner + length))
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            ctx.stroke(path, with: .color(palette.color(at: rng.double()).opacity(rng.range(0.2, 0.7) * intensity)),
                       lineWidth: lineWidth * rng.range(0.6, 1.3))
        }
    }

    /// 碎片：随机弧段与短斜线散布，位置/角度/长度/粗细全随机。
    private static func drawShards(_ ctx: inout GraphicsContext, rect: CGRect,
                                   rng: inout SeededGenerator, palette: CoverPalette,
                                   subjectX: Double, intensity: Double) {
        let count = 10 + rng.int(13)
        for _ in 0..<count {
            let nearFocus = rng.bool(probability: 0.5)
            let baseX = nearFocus ? subjectX : 0.5
            let center = CGPoint(x: rect.width * (baseX + (rng.double() - 0.5) * 0.6),
                                 y: rect.height * rng.range(0.1, 0.9))
            let isArc = rng.bool(probability: 0.45)
            let color = palette.color(at: rng.double())
            let opacity = rng.range(0.18, 0.6) * intensity
            if isArc {
                let radius = min(rect.width, rect.height) * rng.range(0.04, 0.16)
                let start = rng.double() * 2 * .pi
                let span = rng.range(0.3, 1.3) * .pi
                var arc = Path()
                arc.addArc(center: center, radius: radius,
                           startAngle: .radians(start), endAngle: .radians(start + span),
                           clockwise: rng.bool(probability: 0.5))
                ctx.stroke(arc, with: .color(color.opacity(opacity)), lineWidth: rng.range(1.0, 3.0))
            } else {
                let angle = rng.double() * 2 * .pi
                let length = min(rect.width, rect.height) * rng.range(0.05, 0.2)
                var line = Path()
                line.move(to: CGPoint(x: center.x - cos(angle) * length / 2,
                                      y: center.y - sin(angle) * length / 2))
                line.addLine(to: CGPoint(x: center.x + cos(angle) * length / 2,
                                         y: center.y + sin(angle) * length / 2))
                ctx.stroke(line, with: .color(color.opacity(opacity)),
                           lineWidth: rng.range(1.0, 3.0))
            }
        }
    }

    /// 斜向色带：3~7 条平行低透明度宽带铺底，整体角度与间距随机。
    private static func drawBands(_ ctx: inout GraphicsContext, rect: CGRect,
                                  rng: inout SeededGenerator, palette: CoverPalette,
                                  subjectX: Double, intensity: Double) {
        let count = 3 + rng.int(5)
        let angle = rng.range(-0.6, 0.6)
        let pivot = CGPoint(x: rect.width * subjectX, y: rect.height / 2)
        let long = hypot(rect.width, rect.height)
        for index in 0..<count {
            let t = Double(index) / Double(max(count - 1, 1))
            let height = rect.height * rng.range(0.08, 0.26)
            let offset = (t - 0.5) * rect.width * rng.range(0.8, 1.4)
            var band = ctx
            band.translateBy(x: pivot.x + offset, y: pivot.y)
            band.rotate(by: .radians(angle))
            band.fill(Path(CGRect(x: -long / 2, y: -height / 2, width: long, height: height)),
                      with: .color(palette.color(at: t).opacity(rng.range(0.05, 0.14) * intensity)))
        }
    }
}

// MARK: - 原语枚举

private enum CoverPrimitive {
    case flowLines
    case particles
    case rings
    case ridgeLines
    case waveGrid
    case rays
    case shards
    case bands
}
