//
//  LanguageDistributionBar.swift
//  Starcat
//
//  个人资料与仓库详情共用的语言占比条；只负责展示，不持有网络或缓存状态。
//

import SwiftUI

/// 共用分段比例与即时提示，让侧栏可以缩细色条，同时保留足够高的悬停区域。
struct LanguageDistributionBar: View {
    let segments: [RepositoryLanguageDistributionViewModel.Segment]
    var barHeight: CGFloat = 6
    var hoverHeight: CGFloat = 6
    /// 只有仓库详情提供筛选动作；个人开发语言条保持只读。
    var onLanguageTapped: ((String) -> Void)?

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.locale) private var locale
    @State private var hoveredSegment: RepositoryLanguageDistributionViewModel.Segment?
    @State private var hoverAnchorX: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Group {
                if segments.isEmpty {
                    // 加载、空数据和失败共用中性线，异步快照到达时不改变布局高度。
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                } else {
                    HStack(spacing: 0) {
                        ForEach(segments) { segment in
                            segmentView(segment)
                                .frame(width: proxy.size.width * segment.fraction)
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: barHeight)
            // 透明热区在色条上下均分，兼顾细线命中与紧凑布局，避免留白全部堆到下方。
            .frame(height: max(barHeight, hoverHeight), alignment: .center)
            .contentShape(Rectangle())
            // `.help` 在细线上的延迟提示不稳定；整条统一按光标 x 坐标识别语言。
            .onContinuousHover { phase in
                updateHover(phase, barWidth: proxy.size.width)
            }
            .overlay(alignment: .topLeading) {
                if let hoveredSegment {
                    hoverTooltip(for: hoveredSegment)
                        .position(
                            x: clampedTooltipX(hoverAnchorX, barWidth: proxy.size.width),
                            y: max(barHeight, hoverHeight) + 18
                        )
                        // 提示只负责说明，不能截获悬停或仓库详情的筛选点击。
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(barHeight, hoverHeight))
        .onChange(of: segments) { _, _ in
            // 切换账号、仓库或刷新快照后，不能保留旧分段的提示。
            clearHover()
        }
    }

    /// 筛选动作由调用方决定；Other 和个人语言分段均只提供可访问的比例说明。
    @ViewBuilder
    private func segmentView(
        _ segment: RepositoryLanguageDistributionViewModel.Segment
    ) -> some View {
        let color = segment.language.map { LanguageColor.color(for: $0) }
            ?? Color.secondary.opacity(0.45)
        let tooltip = tooltipText(for: segment)

        if let language = segment.language, let onLanguageTapped {
            Button {
                onLanguageTapped(language)
            } label: {
                Rectangle()
                    .fill(color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(Text(verbatim: tooltip))
        } else {
            Rectangle()
                .fill(color)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: tooltip))
        }
    }

    /// 浮层沿用详情页的紧凑材质，不参与色条或个人资料区的尺寸计算。
    private func hoverTooltip(
        for segment: RepositoryLanguageDistributionViewModel.Segment
    ) -> some View {
        Text(verbatim: tooltipText(for: segment))
            .font(interfaceScale.font(.captionSmall, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .starcatGlassSurface(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
    }

    /// 统一追踪整条悬停区域，极窄分段也能按比例命中。
    private func updateHover(_ phase: HoverPhase, barWidth: CGFloat) {
        switch phase {
        case .active(let location):
            guard let target = hoverTarget(at: location.x, barWidth: barWidth) else {
                clearHover()
                return
            }
            hoveredSegment = target.segment
            hoverAnchorX = target.centerX
        case .ended:
            clearHover()
        }
    }

    /// 用累计占比反查语言；最右侧像素容忍浮点累计产生的舍入误差。
    private func hoverTarget(
        at x: CGFloat,
        barWidth: CGFloat
    ) -> (segment: RepositoryLanguageDistributionViewModel.Segment, centerX: CGFloat)? {
        guard barWidth > 0, !segments.isEmpty else { return nil }
        let normalizedX = min(max(Double(x / barWidth), 0), 1)
        var lowerBound = 0.0

        for segment in segments {
            let upperBound = lowerBound + segment.fraction
            if normalizedX <= upperBound {
                let centerX = CGFloat((lowerBound + upperBound) / 2) * barWidth
                return (segment, centerX)
            }
            lowerBound = upperBound
        }

        guard let last = segments.last else { return nil }
        return (last, barWidth)
    }

    /// 复用现有“其他”译文，百分比格式跟随应用语言。
    private func tooltipText(
        for segment: RepositoryLanguageDistributionViewModel.Segment
    ) -> String {
        let title = segment.language ?? String.l10n("sidebar.languages.other")
        let percentage = segment.fraction.formatted(
            .percent.precision(.fractionLength(1)).locale(locale)
        )
        return "\(title) · \(percentage)"
    }

    /// 边缘分段的提示向内收，兼顾窄侧栏与详情栏。
    private func clampedTooltipX(_ proposedX: CGFloat, barWidth: CGFloat) -> CGFloat {
        let safeInset: CGFloat = 96
        guard barWidth > safeInset * 2 else { return barWidth / 2 }
        return min(max(proposedX, safeInset), barWidth - safeInset)
    }

    /// 数据更新或光标离开时同时清理提示内容与锚点。
    private func clearHover() {
        hoveredSegment = nil
        hoverAnchorX = 0
    }
}
