//
//  StarcatContributionRadarChart.swift
//  StarcatWidgets
//
//  GitHub 贡献五维统计的静态雷达图。
//

import SwiftUI

/// 使用对数尺度平衡 Commit 与 Issue、Review 等数量级差异，避免小维度完全贴在中心。
struct StarcatContributionRadarChart: View {
    @Environment(\.colorScheme) private var colorScheme

    let stats: WidgetContributionStats

    private let axes: [(label: LocalizedStringKey, angle: Double)] = [
        ("widget.contribution.radar.commit", -.pi / 2),
        ("widget.contribution.radar.issue", -.pi / 2 + 2 * .pi / 5),
        ("widget.contribution.radar.pullRequest", -.pi / 2 + 4 * .pi / 5),
        ("widget.contribution.radar.review", -.pi / 2 + 6 * .pi / 5),
        ("widget.contribution.radar.repository", -.pi / 2 + 8 * .pi / 5)
    ]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2 + 2)
            let radius = side * 0.29

            ZStack {
                Canvas { context, _ in
                    drawGrid(context: &context, center: center, radius: radius)
                    drawValues(context: &context, center: center, radius: radius)
                }

                ForEach(axes.indices, id: \.self) { index in
                    let axis = axes[index]
                    let labelRadius = radius + 15
                    Text(axis.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .position(
                            x: center.x + labelRadius * CGFloat(cos(axis.angle)),
                            y: center.y + labelRadius * CGFloat(sin(axis.angle))
                        )
                }
            }
        }
        // 五个轴值由卡片根视图一次性汇总，避免 VoiceOver 在装饰图形间跳转。
        .accessibilityHidden(true)
    }

    private func drawGrid(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat
    ) {
        let style = StrokeStyle(
            lineWidth: 0.8,
            lineCap: .round,
            lineJoin: .round,
            dash: [3, 3]
        )
        let gridColor = Color.secondary.opacity(colorScheme == .dark ? 0.42 : 0.32)

        for level in 1...4 {
            let levelRadius = radius * CGFloat(level) / 4
            context.stroke(
                polygon(center: center, radius: levelRadius, fractions: nil),
                with: .color(gridColor),
                style: style
            )
        }

        for axis in axes {
            var spoke = Path()
            spoke.move(to: center)
            spoke.addLine(
                to: CGPoint(
                    x: center.x + radius * CGFloat(cos(axis.angle)),
                    y: center.y + radius * CGFloat(sin(axis.angle))
                )
            )
            context.stroke(spoke, with: .color(gridColor), style: style)
        }
    }

    private func drawValues(
        context: inout GraphicsContext,
        center: CGPoint,
        radius: CGFloat
    ) {
        let fractions = [
            scaleFraction(stats.commits),
            scaleFraction(stats.issues),
            scaleFraction(stats.pullRequests),
            scaleFraction(stats.reviews),
            scaleFraction(stats.repositories)
        ]
        guard fractions.contains(where: { $0 > 0 }) else { return }

        let path = polygon(center: center, radius: radius, fractions: fractions)
        let accent = colorScheme == .dark
            ? Color(red: 0.22, green: 0.83, blue: 0.33)
            : Color(red: 0.19, green: 0.63, blue: 0.31)
        context.fill(path, with: .color(accent.opacity(colorScheme == .dark ? 0.42 : 0.30)))
        context.stroke(
            path,
            with: .color(accent),
            style: StrokeStyle(lineWidth: 2.2, lineJoin: .round)
        )
    }

    private func polygon(
        center: CGPoint,
        radius: CGFloat,
        fractions: [CGFloat]?
    ) -> Path {
        var path = Path()
        for index in axes.indices {
            let fraction = fractions?[index] ?? 1
            let point = CGPoint(
                x: center.x + radius * fraction * CGFloat(cos(axes[index].angle)),
                y: center.y + radius * fraction * CGFloat(sin(axes[index].angle))
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }

    /// 1、10、100、1K、10K 分别落在五个等距层级。
    private func scaleFraction(_ value: Int) -> CGFloat {
        guard value > 0 else { return 0 }
        let logarithm = min(max(log10(Double(value)), 0), 4)
        return CGFloat((logarithm + 1) / 5)
    }
}
