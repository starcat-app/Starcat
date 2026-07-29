//
//  InsightsSectionSkeleton.swift
//  Starcat
//
//  仓库洞察内容区首次加载占位。Section 外壳（标题 / 范围控件）已先渲染，
//  这里只模拟指标卡 / 派生 pill / 图表 / 贡献者 / 信号行轮廓，避免「大卡片中间空洞」。
//
//  复用 SkeletonPalette + shimmer；真无数据 / 失败仍走原有 empty / error，不用骨架。
//

import SwiftUI

/// 洞察内容骨架形态：对齐真实布局高度，减少数据落地时的跳高跳低。
enum InsightsSectionSkeletonKind: Equatable, Sendable {
    /// 活动概览 / 发布节奏等顶部派生指标。
    case derivedPills(count: Int = 3)
    /// 本地概况 / 活动四卡 / Star 总量三卡。
    case metricTiles(count: Int = 4, minHeight: CGFloat = 72)
    /// Star / Commit 图表区。
    case chart(height: CGFloat = 196)
    /// Star 趋势整块：三总量 + 两速率 + 图表。
    case starBlock(chartHeight: CGFloat = 196)
    /// 贡献者：集中度三 pill + 四人网格。
    case contributorBlock(personCount: Int = 4)
    /// 健康维度网格（标题行 + 细进度条）。
    case healthGrid(count: Int = 4)
    /// 社区 / 安全 / 时间线信号行。
    case signalRows(count: Int = 5)
}

/// 仓库洞察区块内容骨架。可选弱文案用于 `generating` / `building`（远端仍在准备）。
struct InsightsSectionSkeleton: View {
    let kind: InsightsSectionSkeletonKind
    var statusCaptionKey: LocalizedStringKey? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    var body: some View {
        SkeletonAnimatedPhase { phase in
            let palette = SkeletonPalette.forColorScheme(colorScheme)
            VStack(alignment: .leading, spacing: 8) {
                switch kind {
                case .derivedPills(let count):
                    derivedPills(count: count, phase: phase, palette: palette)
                case .metricTiles(let count, let minHeight):
                    metricTiles(count: count, minHeight: minHeight, phase: phase, palette: palette)
                case .chart(let height):
                    chartBars(height: height, phase: phase, palette: palette)
                case .starBlock(let chartHeight):
                    starBlock(chartHeight: chartHeight, phase: phase, palette: palette)
                case .contributorBlock(let personCount):
                    contributorBlock(personCount: personCount, phase: phase, palette: palette)
                case .healthGrid(let count):
                    healthGrid(count: count, phase: phase, palette: palette)
                case .signalRows(let count):
                    signalRows(count: count, phase: phase, palette: palette)
                }

                if let statusCaptionKey {
                    Text(statusCaptionKey)
                        .font(interfaceScale.font(.captionSmall))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(statusCaptionKey ?? "insights.repo.state.generating"))
        }
    }

    private func derivedPills(
        count: Int,
        phase: Double,
        palette: SkeletonPalette
    ) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                SkeletonBlock(
                    height: 32,
                    cornerRadius: 8,
                    phase: phase,
                    phaseOffset: Double(index) * 0.08,
                    palette: palette
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricTiles(
        count: Int,
        minHeight: CGFloat,
        phase: Double,
        palette: SkeletonPalette
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(
                        width: 88,
                        height: 12,
                        cornerRadius: 4,
                        phase: phase,
                        phaseOffset: Double(index) * 0.06,
                        palette: palette
                    )
                    SkeletonBlock(
                        width: 56,
                        height: 22,
                        cornerRadius: 5,
                        phase: phase,
                        phaseOffset: Double(index) * 0.06 + 0.04,
                        palette: palette
                    )
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .background(
                    palette.base.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                }
            }
        }
    }

    /// 用不等高竖条模拟柱图轮廓，高度固定以免加载完抖动。
    private func chartBars(
        height: CGFloat,
        phase: Double,
        palette: SkeletonPalette
    ) -> some View {
        let barFractions: [CGFloat] = [0.35, 0.55, 0.42, 0.78, 0.48, 0.66, 0.38, 0.72, 0.50, 0.60, 0.44, 0.70]
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(barFractions.enumerated()), id: \.offset) { index, fraction in
                SkeletonBlock(
                    height: max(12, height * 0.72 * fraction),
                    cornerRadius: 4,
                    phase: phase,
                    phaseOffset: Double(index) * 0.04,
                    palette: palette
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .bottom)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.35),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func starBlock(
        chartHeight: CGFloat,
        phase: Double,
        palette: SkeletonPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            metricTiles(count: 3, minHeight: 58, phase: phase, palette: palette)
            derivedPills(count: 2, phase: phase, palette: palette)
            chartBars(height: chartHeight, phase: phase, palette: palette)
        }
    }

    private func contributorBlock(
        personCount: Int,
        phase: Double,
        palette: SkeletonPalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            derivedPills(count: 3, phase: phase, palette: palette)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 142), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(0..<personCount, id: \.self) { index in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(palette.base)
                            .frame(width: 28, height: 28)
                            .skeletonShimmer(
                                phase: (phase + Double(index) * 0.07).truncatingRemainder(dividingBy: 1),
                                palette: palette
                            )
                        VStack(alignment: .leading, spacing: 4) {
                            SkeletonBlock(
                                width: 72,
                                height: 11,
                                cornerRadius: 3,
                                phase: phase,
                                phaseOffset: Double(index) * 0.07,
                                palette: palette
                            )
                            SkeletonBlock(
                                width: 56,
                                height: 9,
                                cornerRadius: 3,
                                phase: phase,
                                phaseOffset: Double(index) * 0.07 + 0.03,
                                palette: palette
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private func healthGrid(
        count: Int,
        phase: Double,
        palette: SkeletonPalette
    ) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 148), spacing: 10)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(0..<count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        SkeletonBlock(
                            width: 14,
                            height: 12,
                            cornerRadius: 3,
                            phase: phase,
                            phaseOffset: Double(index) * 0.05,
                            palette: palette
                        )
                        SkeletonBlock(
                            width: 64,
                            height: 11,
                            cornerRadius: 3,
                            phase: phase,
                            phaseOffset: Double(index) * 0.05 + 0.02,
                            palette: palette
                        )
                        Spacer(minLength: 4)
                        SkeletonBlock(
                            width: 22,
                            height: 11,
                            cornerRadius: 3,
                            phase: phase,
                            phaseOffset: Double(index) * 0.05 + 0.04,
                            palette: palette
                        )
                    }
                    SkeletonBlock(
                        height: 3,
                        cornerRadius: 2,
                        phase: phase,
                        phaseOffset: Double(index) * 0.05 + 0.06,
                        palette: palette
                    )
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    palette.base.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                }
            }
        }
    }

    private func signalRows(
        count: Int,
        phase: Double,
        palette: SkeletonPalette
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                if index > 0 {
                    Divider().padding(.leading, 28)
                }
                HStack(spacing: 10) {
                    SkeletonBlock(
                        width: 18,
                        height: 16,
                        cornerRadius: 4,
                        phase: phase,
                        phaseOffset: Double(index) * 0.06,
                        palette: palette
                    )
                    SkeletonBlock(
                        width: 120 + CGFloat(index % 3) * 18,
                        height: 12,
                        cornerRadius: 3,
                        phase: phase,
                        phaseOffset: Double(index) * 0.06 + 0.02,
                        palette: palette
                    )
                    Spacer(minLength: 8)
                    SkeletonBlock(
                        width: 36,
                        height: 12,
                        cornerRadius: 3,
                        phase: phase,
                        phaseOffset: Double(index) * 0.06 + 0.04,
                        palette: palette
                    )
                }
                .padding(.vertical, 9)
            }
        }
    }
}
