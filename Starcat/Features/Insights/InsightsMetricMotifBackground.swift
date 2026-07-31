//
//  InsightsMetricMotifBackground.swift
//  Starcat
//
//  洞察 KPI / 资产清理 / Star 趋势等卡片右下角的示意装饰图。
//
//  关键约束：
//  - 由 metric id + value 稳定生成，刷新后形状不乱跳；
//  - 只做视觉层次，**不是**真实时间序列，禁止据此解读趋势；
//  - 故意弱化透明度，不进无障碍树。
//

import SwiftUI

/// 装饰图样：柱 / 带状 / 面积 / 阶梯柱。
enum InsightsMetricMotifKind: Sendable {
    case bars
    /// 细柱底托 + 折线 + 端点，避免单条曲线过于单调。
    case ribbon
    case area
    case steps

    static func kind(forMetricID id: String) -> Self {
        switch id {
        case "projects", "dormant", "starGrowth30":
            return .bars
        case "new", "starCurrent":
            return .ribbon
        case "using", "unavailable":
            return .area
        default:
            // organized / archived / starGrowthYear 等
            return .steps
        }
    }
}

/// 右下角示意「口袋」尺寸：标准用于我的洞察 KPI / 资产清理；compact 用于 Star 趋势三卡。
enum InsightsMetricMotifPocketSize: Sendable {
    case standard
    case compact

    var widthFraction: CGFloat {
        switch self {
        case .standard: return 0.38
        case .compact: return 0.30
        }
    }

    var heightFraction: CGFloat {
        switch self {
        case .standard: return 0.42
        case .compact: return 0.36
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .standard: return 72
        case .compact: return 48
        }
    }

    var maxWidth: CGFloat {
        switch self {
        case .standard: return 120
        case .compact: return 78
        }
    }

    var minHeight: CGFloat {
        switch self {
        case .standard: return 40
        case .compact: return 26
        }
    }

    var maxHeight: CGFloat {
        switch self {
        case .standard: return 56
        case .compact: return 36
        }
    }

    var trailingPadding: CGFloat {
        switch self {
        case .standard: return 10
        case .compact: return 6
        }
    }

    var bottomPadding: CGFloat {
        switch self {
        case .standard: return 8
        case .compact: return 5
        }
    }
}

/// 把示意装饰图固定在容器右下角，避免铺满整卡压住文字。
struct InsightsMetricMotifCorner: View {
    let metricID: String
    let value: Int
    let tint: Color
    var pocket: InsightsMetricMotifPocketSize = .standard

    var body: some View {
        GeometryReader { geo in
            InsightsMetricMotifBackground(
                metricID: metricID,
                value: value,
                tint: tint
            )
            .frame(
                width: min(max(geo.size.width * pocket.widthFraction, pocket.minWidth), pocket.maxWidth),
                height: min(max(geo.size.height * pocket.heightFraction, pocket.minHeight), pocket.maxHeight)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, pocket.trailingPadding)
            .padding(.bottom, pocket.bottomPadding)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Canvas 绘制的示意装饰图本体。
struct InsightsMetricMotifBackground: View {
    let metricID: String
    let value: Int
    let tint: Color

    var body: some View {
        let kind = InsightsMetricMotifKind.kind(forMetricID: metricID)
        let sampleCount: Int = {
            switch kind {
            case .ribbon, .area: return 12
            case .bars, .steps: return 9
            }
        }()
        let samples = Self.samples(id: metricID, value: value, count: sampleCount)

        Canvas { context, size in
            guard size.width > 1, size.height > 1 else { return }
            switch kind {
            case .bars:
                Self.drawBars(context: context, size: size, samples: samples, tint: tint)
            case .ribbon:
                Self.drawRibbon(context: context, size: size, samples: samples, tint: tint)
            case .area:
                Self.drawLine(context: context, size: size, samples: samples, tint: tint, filled: true)
            case .steps:
                Self.drawSteps(context: context, size: size, samples: samples, tint: tint)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 稳定伪随机采样；value 只做轻微振幅偏置，避免「图跟着涨跌」被误读成趋势。
    private static func samples(id: String, value: Int, count: Int) -> [Double] {
        var seed = UInt64(bitPattern: Int64(value & 0x7fff_ffff))
        for byte in id.utf8 {
            seed = seed &* 1_664_525 &+ UInt64(byte)
        }
        let bias = min(0.2, log10(Double(max(value, 1)) + 1) / 20)
        var points: [Double] = []
        points.reserveCapacity(count)
        for _ in 0..<count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let unit = Double(seed % 10_000) / 10_000
            points.append(0.22 + unit * 0.55 + bias)
        }
        return points
    }

    private static func drawBars(
        context: GraphicsContext,
        size: CGSize,
        samples: [Double],
        tint: Color
    ) {
        let gap = max(1.5, size.width * 0.03)
        let totalGap = gap * Double(max(samples.count - 1, 0))
        let barWidth = max(2, (size.width - totalGap) / Double(samples.count))
        for (index, sample) in samples.enumerated() {
            let height = size.height * min(max(sample, 0.08), 1)
            let x = Double(index) * (barWidth + gap)
            let rect = CGRect(
                x: x,
                y: size.height - height,
                width: barWidth,
                height: height
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: 1.5, style: .continuous),
                with: .color(tint.opacity(0.11))
            )
        }
    }

    /// 矮柱托底 + 折线 + 稀疏圆点，比单线更有层次。
    private static func drawRibbon(
        context: GraphicsContext,
        size: CGSize,
        samples: [Double],
        tint: Color
    ) {
        guard samples.count >= 2 else { return }

        let gap = max(1.2, size.width * 0.028)
        let totalGap = gap * Double(max(samples.count - 1, 0))
        let barWidth = max(1.5, (size.width - totalGap) / Double(samples.count))
        for (index, sample) in samples.enumerated() {
            let height = size.height * min(max(sample * 0.55, 0.06), 0.72)
            let x = Double(index) * (barWidth + gap)
            let rect = CGRect(
                x: x,
                y: size.height - height,
                width: barWidth * 0.7,
                height: height
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: 1, style: .continuous),
                with: .color(tint.opacity(0.08))
            )
        }

        var line = Path()
        var points: [CGPoint] = []
        points.reserveCapacity(samples.count)
        for (index, sample) in samples.enumerated() {
            let x = size.width * Double(index) / Double(samples.count - 1)
            let y = size.height * (1 - min(max(sample, 0.08), 0.95))
            let point = CGPoint(x: x, y: y)
            points.append(point)
            if index == 0 {
                line.move(to: point)
            } else {
                line.addLine(to: point)
            }
        }
        context.stroke(
            line,
            with: .color(tint.opacity(0.16)),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        )

        for (index, point) in points.enumerated() where index.isMultiple(of: 2) {
            let dot = Path(
                ellipseIn: CGRect(x: point.x - 1.4, y: point.y - 1.4, width: 2.8, height: 2.8)
            )
            context.fill(dot, with: .color(tint.opacity(0.18)))
        }
    }

    private static func drawLine(
        context: GraphicsContext,
        size: CGSize,
        samples: [Double],
        tint: Color,
        filled: Bool
    ) {
        guard samples.count >= 2 else { return }
        var line = Path()
        for (index, sample) in samples.enumerated() {
            let x = size.width * Double(index) / Double(samples.count - 1)
            let y = size.height * (1 - min(max(sample, 0.05), 1))
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                line.move(to: point)
            } else {
                line.addLine(to: point)
            }
        }

        if filled {
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(tint.opacity(0.05)))
        }

        context.stroke(
            line,
            with: .color(tint.opacity(0.15)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }

    private static func drawSteps(
        context: GraphicsContext,
        size: CGSize,
        samples: [Double],
        tint: Color
    ) {
        let gap = max(1.5, size.width * 0.04)
        let totalGap = gap * Double(max(samples.count - 1, 0))
        let barWidth = max(2, (size.width - totalGap) / Double(samples.count))
        for (index, sample) in samples.enumerated() {
            let step = index.isMultiple(of: 2) ? 0.82 : 1
            let height = size.height * min(max(sample * step, 0.08), 1)
            let x = Double(index) * (barWidth + gap)
            let rect = CGRect(
                x: x,
                y: size.height - height,
                width: barWidth * 0.85,
                height: height
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: 1, style: .continuous),
                with: .color(tint.opacity(0.10))
            )
        }
    }
}
