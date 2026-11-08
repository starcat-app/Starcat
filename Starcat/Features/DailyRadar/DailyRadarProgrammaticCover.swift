//
//  DailyRadarProgrammaticCover.swift
//  Starcat
//
//  每日热点的本地生成艺术：六类构图分别组织空间、主体与细节，而非随机叠加原语。
//  仅封面内容区采用编辑式视觉；周边原生控件不受影响，不包含网络或模型调用。
//
//  关键约束：
//  - 每次绘制从报告身份重建随机流，禁止使用系统随机数或按帧变化的状态
//  - 几何与纹理分流，尺寸只裁减细节，不改变风格与配色
//  - 采样与图形数量都有上限，不启用动画、逐像素噪声或全画面模糊
//  - 主推卡图案连续铺满画布，通过末层渐变保护左侧文字，避免留出硬边黑块
//

import SwiftUI

/// 封面是无交互的静态 Canvas；同一份构图可适配卡片、缩略图和阅读页。
struct DailyRadarProgrammaticCover: View {
    let category: String?
    let seed: String
    var textSafeLeading: CGFloat = 0

    var body: some View {
        let composition = DailyRadarCoverComposition(category: category, seed: seed)
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let safe = DailyRadarCoverComposition.safeLeading(textSafeLeading)
            let rect = CGRect(origin: .zero, size: size)
            let detail = DailyRadarCoverComposition.detailLevel(for: size)
            var rng = SeededGenerator(seed: composition.geometrySeed)
            Self.drawBackground(context, rect: rect, composition: composition)
            // 主体只按整张封面裁剪，左侧保留图案并渐变压暗，避免安全区边缘出现断层
            var subject = context
            subject.clip(to: Path(rect))
            switch composition.style {
            case .terrain:
                Self.drawTerrain(subject, rect: rect, composition: composition, rng: &rng, detail: detail)
            case .network:
                Self.drawNetwork(subject, rect: rect, composition: composition, rng: &rng, detail: detail)
            case .orbital:
                Self.drawOrbital(subject, rect: rect, composition: composition, rng: &rng, detail: detail)
            case .architecture:
                Self.drawArchitecture(subject, rect: rect, composition: composition, rng: &rng, detail: detail)
            case .strata:
                Self.drawStrata(subject, rect: rect, composition: composition, rng: &rng, detail: detail)
            case .interference:
                Self.drawInterference(subject, rect: rect, composition: composition, rng: &rng, detail: detail)
            }
            Self.drawTexture(context, rect: rect, composition: composition, detail: detail)
            if safe > 0 {
                Self.drawTextProtection(context, rect: rect, safe: safe)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 共享的色彩、背景与文字保护

    /// 离散选取主色或强调色，不在 HSB 上跨色相长距离插值，以免补色间出现脏色。
    private static func ink(_ composition: DailyRadarCoverComposition, accent: Bool = false,
                            brightness: Double = 0.90) -> Color {
        Color(hue: accent ? composition.accentHue : composition.hue,
              saturation: accent ? 0.62 : 0.74, brightness: brightness)
    }

    /// 背景暗部与有色中间调加稀疏基准网格，为主体提供尺度参照。
    private static func drawBackground(_ ctx: GraphicsContext, rect: CGRect,
                                       composition c: DailyRadarCoverComposition) {
        let dark = Color(hue: c.backgroundHue, saturation: 0.48, brightness: 0.08)
        let mid = Color(hue: c.backgroundHue, saturation: 0.55, brightness: 0.23)
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [dark, mid, dark]),
            startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        var grid = Path()
        for column in 1..<13 {
            let x = rect.width * Double(column) / 13
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: rect.height))
        }
        for row in 1..<7 {
            let y = rect.height * Double(row) / 7
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: rect.width, y: y))
        }
        ctx.stroke(grid, with: .color(ink(c).opacity(0.075)), lineWidth: 0.5)
    }

    /// 微刻度采用独立随机流；没有逐像素采样，也不会干扰主体的随机序列。
    private static func drawTexture(_ ctx: GraphicsContext, rect: CGRect,
                                    composition c: DailyRadarCoverComposition, detail: Int) {
        var rng = SeededGenerator(seed: c.textureSeed)
        var marks = Path()
        for index in 0..<64 {
            let x = rect.width * rng.double()
            let y = rect.height * rng.double()
            if index % (3 - detail) != 0 { continue }
            marks.move(to: CGPoint(x: x - 1.5, y: y))
            marks.addLine(to: CGPoint(x: x + 1.5, y: y))
            if index % 4 == 0 {
                marks.move(to: CGPoint(x: x, y: y - 1.5))
                marks.addLine(to: CGPoint(x: x, y: y + 1.5))
            }
        }
        ctx.stroke(marks, with: .color(.white.opacity(0.16)), lineWidth: 0.6)
    }

    /// 遮罩最后绘制，左侧仍能辨认图案，渐变到主体时保留标题所需的对比度
    private static func drawTextProtection(_ ctx: GraphicsContext, rect: CGRect, safe: CGFloat) {
        let gradient = Gradient(stops: [
            .init(color: .black.opacity(0.60), location: 0),
            .init(color: .black.opacity(0.38), location: safe),
            .init(color: .clear, location: min(safe + 0.25, 1))
        ])
        ctx.fill(Path(rect), with: .linearGradient(
            gradient, startPoint: .zero, endPoint: CGPoint(x: rect.width, y: 0)))
    }

    // MARK: - 流场地形

    /// 多频场生成连续地形；先填后描逐层遮挡，形成山脊而非互不相关的波浪线。
    private static func drawTerrain(_ ctx: GraphicsContext, rect: CGRect,
                                    composition c: DailyRadarCoverComposition,
                                    rng: inout SeededGenerator, detail: Int) {
        let peak = rng.range(0.25, 0.75)
        let frequency = rng.range(1.1, 2.4)
        let amplitude = rng.range(0.12, 0.24)
        for row in 0..<34 {
            if row % (3 - detail) != 0 && row != 33 { continue }
            let t = Double(row) / 33
            var ridge = Path()
            for sample in 0...64 {
                let u = Double(sample) / 64
                let envelope = exp(-pow((u - peak) * 3.2, 2))
                let large = sin(u * frequency * 2 * .pi + c.phase + t * 1.6)
                let small = sin(u * 18 + c.phase * 0.7 + t * 5) * 0.23
                let height = (large + small) * amplitude * (0.4 + envelope)
                let point = CGPoint(x: rect.minX + u * rect.width,
                                    y: rect.height * (0.12 + t * 0.85 - height))
                if sample == 0 { ridge.move(to: point) } else { ridge.addLine(to: point) }
            }
            var fill = ridge
            fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 1.4))
            fill.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 1.4))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(ink(c, brightness: 0.12 + t * 0.16)))
            let accent = row % 7 == 0
            ctx.stroke(ridge, with: .color(ink(c, accent: accent).opacity(accent ? 0.90 : 0.48)),
                       lineWidth: accent ? 1.5 : 0.7)
        }
    }

    // MARK: - 节点网络

    /// 三个空间簇加局部邻接；先建立同一套节点，再按尺寸减少边，缩略图不随机换主体。
    private static func drawNetwork(_ ctx: GraphicsContext, rect: CGRect,
                                    composition c: DailyRadarCoverComposition,
                                    rng: inout SeededGenerator, detail: Int) {
        let centers = [
            CGPoint(x: 0.30, y: 0.30), CGPoint(x: 0.72, y: 0.46), CGPoint(x: 0.42, y: 0.78)
        ]
        var nodes: [CGPoint] = []
        for index in 0..<54 {
            let center = centers[index % centers.count]
            let angle = rng.range(0, 2 * .pi)
            let radius = sqrt(rng.double()) * 0.26
            nodes.append(CGPoint(x: rect.minX + (center.x + cos(angle) * radius) * rect.width,
                                 y: (center.y + sin(angle) * radius) * rect.height))
        }
        let reach = hypot(rect.width, rect.height) * 0.22
        for index in nodes.indices {
            // 每个节点只取最近的三条边，上限为 162 次连线，不做全连接图。
            let neighbors = nodes.indices.filter { $0 > index }
                .sorted { distance(nodes[index], nodes[$0]) < distance(nodes[index], nodes[$1]) }
                .prefix(3)
            for (rank, other) in neighbors.enumerated() {
                let length = distance(nodes[index], nodes[other])
                guard length < reach, rank <= detail else { continue }
                var edge = Path()
                edge.move(to: nodes[index])
                edge.addLine(to: nodes[other])
                let accent = index % 5 == 0
                ctx.stroke(edge, with: .color(ink(c, accent: accent).opacity(accent ? 0.64 : 0.25)),
                           lineWidth: accent ? 1.1 : 0.6)
            }
        }
        for index in nodes.indices {
            let hub = index % 9 == 0
            let radius: CGFloat = hub ? 4.5 : 1.6
            let node = CGRect(x: nodes[index].x - radius, y: nodes[index].y - radius,
                              width: radius * 2, height: radius * 2)
            ctx.fill(Path(ellipseIn: node), with: .color(ink(c, accent: hub)))
            if hub {
                ctx.stroke(Path(ellipseIn: node.insetBy(dx: -5, dy: -5)),
                           with: .color(ink(c, accent: true).opacity(0.35)), lineWidth: 0.8)
            }
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - 轨道结构

    /// 椭圆轨道包围实体核心；刻度、卫星与前后弧共同构成立体关系。
    private static func drawOrbital(_ ctx: GraphicsContext, rect: CGRect,
                                    composition c: DailyRadarCoverComposition,
                                    rng: inout SeededGenerator, detail: Int) {
        let center = CGPoint(x: rect.midX, y: rect.height * rng.range(0.42, 0.58))
        let unit = min(rect.width, rect.height)
        var space = ctx
        space.translateBy(x: center.x, y: center.y)
        space.rotate(by: .radians(c.tilt * 2 - 0.35))
        for orbit in 0..<10 {
            let radius = unit * (0.16 + Double(orbit) * 0.044)
            let flatten = 0.35 + Double(orbit % 3) * 0.13
            let ellipse = CGRect(x: -radius, y: -radius * flatten,
                                 width: radius * 2, height: radius * flatten * 2)
            let accent = orbit % 3 == 0
            space.stroke(Path(ellipseIn: ellipse),
                         with: .color(ink(c, accent: accent).opacity(accent ? 0.74 : 0.32)),
                         lineWidth: accent ? 1.5 : 0.7)
            let angle = c.phase + Double(orbit) * 1.7
            let satellite = CGPoint(x: cos(angle) * radius, y: sin(angle) * radius * flatten)
            space.fill(Path(ellipseIn: CGRect(x: satellite.x - 2, y: satellite.y - 2, width: 4, height: 4)),
                       with: .color(ink(c, accent: true)))
        }
        let core = CGRect(x: -unit * 0.13, y: -unit * 0.13, width: unit * 0.26, height: unit * 0.26)
        space.fill(Path(ellipseIn: core), with: .linearGradient(
            Gradient(colors: [ink(c, accent: true), ink(c, brightness: 0.28)]),
            startPoint: core.origin, endPoint: CGPoint(x: core.maxX, y: core.maxY)))
        // 前侧弧盖在核心上，表达穿插；外围刻度只负责细节，不改变轨道身份。
        var front = Path()
        front.addArc(center: .zero, radius: unit * 0.17, startAngle: .degrees(10),
                     endAngle: .degrees(160), clockwise: false)
        space.stroke(front, with: .color(ink(c).opacity(0.85)), lineWidth: 2.3)
        var ticks = Path()
        for index in stride(from: 0, to: 96, by: 3 - detail) {
            let angle = Double(index) / 96 * 2 * .pi
            let inner = unit * 0.57
            let outer = inner + unit * (index % 8 == 0 ? 0.035 : 0.012)
            ticks.move(to: CGPoint(x: cos(angle) * inner, y: sin(angle) * inner))
            ticks.addLine(to: CGPoint(x: cos(angle) * outer, y: sin(angle) * outer))
        }
        space.stroke(ticks, with: .color(ink(c, accent: true).opacity(0.45)), lineWidth: 0.8)
    }

    // MARK: - 透视建筑

    /// 抽象棱柱在等距投影下按远近绘制，三面明度与网格截面提供结构复杂度。
    private static func drawArchitecture(_ ctx: GraphicsContext, rect: CGRect,
                                         composition c: DailyRadarCoverComposition,
                                         rng: inout SeededGenerator, detail: Int) {
        let unit = min(rect.width / 7, rect.height / 5.5)
        let origin = CGPoint(x: rect.midX, y: rect.height * 0.55)
        func project(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
            CGPoint(x: origin.x + (x - y) * unit,
                    y: origin.y + (x + y) * unit * 0.42 - z * unit)
        }
        for diagonal in 0...8 {
            for x in 0...4 {
                let y = diagonal - x
                guard (0...4).contains(y) else { continue }
                let height = rng.range(0.3, 1.9)
                let px = Double(x) - 2
                let py = Double(y) - 2
                let a = project(px, py, height)
                let b = project(px + 0.8, py, height)
                let d = project(px, py + 0.8, height)
                let e = project(px + 0.8, py + 0.8, height)
                let bottomB = project(px + 0.8, py, 0)
                let bottomD = project(px, py + 0.8, 0)
                let bottomE = project(px + 0.8, py + 0.8, 0)
                let accent = (x + y) % 4 == 0
                let faces = [[b, e, bottomE, bottomB], [d, e, bottomE, bottomD], [a, b, e, d]]
                for (index, points) in faces.enumerated() {
                    let face = polygon(points)
                    let brightness = [0.27, 0.40, 0.72][index]
                    ctx.fill(face, with: .color(ink(c, accent: accent, brightness: brightness)))
                    ctx.stroke(face, with: .color(ink(c, accent: accent).opacity(0.66)), lineWidth: 0.7)
                }
                if detail > 0 {
                    var seams = Path()
                    for layer in 1...3 {
                        let z = height * Double(layer) / 4
                        seams.move(to: project(px + 0.8, py, z))
                        seams.addLine(to: project(px + 0.8, py + 0.8, z))
                        seams.addLine(to: project(px, py + 0.8, z))
                    }
                    ctx.stroke(seams, with: .color(ink(c, accent: accent).opacity(0.32)), lineWidth: 0.5)
                }
            }
        }
    }

    /// 面共享封闭路径，填充与描边不会因分别计算顶点出现细缝。
    private static func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    // MARK: - 层叠切片

    /// 扭转截面堆叠为雕塑体，低频形变使轮廓避免退化为同心圆环。
    private static func drawStrata(_ ctx: GraphicsContext, rect: CGRect,
                                   composition c: DailyRadarCoverComposition,
                                   rng: inout SeededGenerator, detail: Int) {
        let lobes = 3 + rng.int(4)
        let radius = min(rect.width * 0.37, rect.height * 0.32)
        for layer in 0..<32 {
            if layer % (3 - detail) != 0 && layer != 31 { continue }
            let t = Double(layer) / 31
            let center = CGPoint(x: rect.midX + sin(t * 2.8 + c.phase) * radius * 0.28,
                                 y: rect.height * (0.28 + t * 0.48))
            let scale = 0.64 + sin(t * .pi) * 0.40
            var points: [CGPoint] = []
            for sample in 0..<72 {
                let angle = Double(sample) / 72 * 2 * .pi
                let ripple = 1 + sin(angle * Double(lobes) + t * 4 + c.phase) * 0.15
                let x = cos(angle + c.tilt) * radius * scale * ripple
                let y = sin(angle) * radius * scale * ripple * 0.42
                points.append(CGPoint(x: center.x + x, y: center.y + y))
            }
            let contour = polygon(points)
            let accent = layer % 8 < 2
            ctx.fill(contour, with: .linearGradient(
                Gradient(colors: [ink(c, accent: accent, brightness: 0.20),
                                  ink(c, accent: accent, brightness: 0.44)]),
                startPoint: CGPoint(x: center.x - radius, y: center.y),
                endPoint: CGPoint(x: center.x + radius, y: center.y)))
            ctx.stroke(contour, with: .color(ink(c, accent: accent).opacity(0.85)), lineWidth: 0.85)
        }
    }

    // MARK: - 波面干涉

    /// 两组耦合波形形成交织曲面；主波带保留填充体积，交叉线承担次级结构。
    private static func drawInterference(_ ctx: GraphicsContext, rect: CGRect,
                                         composition c: DailyRadarCoverComposition,
                                         rng: inout SeededGenerator, detail: Int) {
        let frequency = rng.range(1.2, 2.6)
        let amplitude = rng.range(0.10, 0.19)
        for family in 0..<2 {
            for row in 0..<30 {
                if row % (3 - detail) != 0 { continue }
                let t = Double(row) / 29
                var wave = Path()
                var reverse: [CGPoint] = []
                for sample in 0...72 {
                    let u = Double(sample) / 72
                    let angle = u * frequency * 2 * .pi + c.phase + t * 3
                    let envelope = sin(u * .pi)
                    let displacement = sin(angle) * amplitude * envelope
                    let baseline = 0.16 + t * 0.68
                    let v = family == 0 ? baseline + displacement : 1 - baseline - displacement * 0.8
                    let point = CGPoint(x: rect.minX + rect.width * u,
                                        y: rect.height * (v + (u - 0.5) * c.tilt))
                    if sample == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
                    reverse.append(CGPoint(x: point.x, y: point.y + rect.height * 0.022))
                }
                if row % 6 == 0 {
                    var ribbon = wave
                    for point in reverse.reversed() { ribbon.addLine(to: point) }
                    ribbon.closeSubpath()
                    ctx.fill(ribbon, with: .color(ink(c, accent: family == 1).opacity(0.20)))
                }
                ctx.stroke(wave, with: .color(ink(c, accent: family == 1).opacity(family == 0 ? 0.66 : 0.46)),
                           lineWidth: row % 6 == 0 ? 1.5 : 0.65)
            }
        }
    }
}
