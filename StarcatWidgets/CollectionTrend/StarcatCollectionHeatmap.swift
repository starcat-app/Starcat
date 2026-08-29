//
//  StarcatCollectionHeatmap.swift
//  StarcatWidgets
//
//  将收藏日聚合渲染为“周为列、星期为行”的紧凑热力图。
//

import SwiftUI

/// 适配 Widget 固定尺寸的收藏热力图。
///
/// 这里不用 LazyGrid：Widget 数据最多 182 个点，固定 HStack/VStack 能直接控制每个
/// 方格的物理尺寸，也避免不同系统版本的惰性布局在 Gallery 快照中出现裁剪差异。
struct StarcatCollectionHeatmap: View {
    @Environment(\.colorScheme) private var colorScheme

    let points: [WidgetCollectionTrendDay]
    let weekCount: Int
    let referenceDate: Date
    let palette: CollectionTrendPalette

    private let spacing: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let displayedPoints = Array(points.suffix(weekCount * 7))
            let maximum = max(
                1,
                displayedPoints
                    .filter { $0.date <= referenceDate }
                    .map(\.count)
                    .max() ?? 0
            )
            let cellSize = max(
                2,
                min(
                    (proxy.size.width - spacing * CGFloat(weekCount - 1))
                        / CGFloat(weekCount),
                    (proxy.size.height - spacing * 6) / 7
                )
            )

            HStack(alignment: .top, spacing: spacing) {
                ForEach(0..<weekCount, id: \.self) { weekIndex in
                    VStack(spacing: spacing) {
                        ForEach(0..<7, id: \.self) { weekdayIndex in
                            let pointIndex = weekIndex * 7 + weekdayIndex
                            if displayedPoints.indices.contains(pointIndex) {
                                heatmapCell(
                                    point: displayedPoints[pointIndex],
                                    maximum: maximum,
                                    size: cellSize
                                )
                            } else {
                                Color.clear
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
        // 整张卡片已有可读指标；逐格朗读 182 个日期会让 VoiceOver 无法使用。
        .accessibilityHidden(true)
    }

    private func heatmapCell(
        point: WidgetCollectionTrendDay,
        maximum: Int,
        size: CGFloat
    ) -> some View {
        let intensity = intensity(for: point.count, maximum: maximum)
        let isFuture = point.date > referenceDate

        return RoundedRectangle(cornerRadius: max(2, size * 0.22), style: .continuous)
            .fill(
                isFuture
                    ? Color.clear
                    : palette.color(
                        intensity: intensity,
                        colorScheme: colorScheme
                    )
            )
            .frame(width: size, height: size)
    }

    /// 低频收藏直接映射 1...4，高频场景再按当前窗口峰值归一化。
    /// 这样个人常见的 1 次收藏不会被高峰周吞没，同时仍能表达相对强弱。
    private func intensity(for count: Int, maximum: Int) -> Int {
        guard count > 0 else { return 0 }
        if maximum <= 4 {
            return min(4, count)
        }
        return min(4, max(1, Int(ceil(Double(count) / Double(maximum) * 4))))
    }
}

extension CollectionTrendPalette {
    func color(intensity: Int, colorScheme: ColorScheme) -> Color {
        guard intensity > 0 else {
            return Color.secondary.opacity(colorScheme == .dark ? 0.20 : 0.12)
        }

        let base: Color = switch self {
        case .system:
            .accentColor
        case .evergreen:
            .green
        case .ocean:
            .blue
        case .ember:
            .orange
        case .nordic:
            .indigo
        }
        let opacities: [Double] = [0.34, 0.54, 0.76, 1]
        return base.opacity(opacities[min(3, intensity - 1)])
    }
}
