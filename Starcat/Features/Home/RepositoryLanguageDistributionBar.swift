//
//  RepositoryLanguageDistributionBar.swift
//  Starcat
//
//  Manage 详情 Hero 中的响应式语言占比分割线。
//

import SwiftUI

/// 将语言占比画成随详情栏宽度变化的整行分割线；文字只通过 hover tooltip 与辅助功能暴露。
struct RepositoryLanguageDistributionBar: View {
    let repo: Repo
    let onLanguageTapped: (String) -> Void

    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @State private var viewModel: RepositoryLanguageDistributionViewModel
    @State private var hoveredSegment: RepositoryLanguageDistributionViewModel.Segment?
    @State private var hoverAnchorX: CGFloat = 0

    init(
        repo: Repo,
        service: any RepositoryLanguageServing,
        onLanguageTapped: @escaping (String) -> Void
    ) {
        self.repo = repo
        self.onLanguageTapped = onLanguageTapped
        _viewModel = State(
            initialValue: RepositoryLanguageDistributionViewModel(service: service)
        )
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if viewModel.segments.isEmpty {
                    // Loading、空数据和失败共用一条中性线，Hero 高度从首帧起保持稳定。
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                } else {
                    HStack(spacing: 0) {
                        ForEach(viewModel.segments) { segment in
                            segmentView(segment)
                                // 总宽度只来自父容器 proposal；窗口缩放时每段按占比即时重算。
                                .frame(width: proxy.size.width * segment.fraction)
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .contentShape(Rectangle())
            // `.help` 由 AppKit 延迟调度，在 6pt 分段按钮上触发不稳定；保留横条原本
            // 的直接布局链路，只在它自身统一跟踪 x 坐标，避免浮层容器改变 Rectangle 高度。
            .onContinuousHover { phase in
                updateHover(phase, barWidth: proxy.size.width)
            }
            .overlay(alignment: .topLeading) {
                if let hoveredSegment {
                    hoverTooltip(for: hoveredSegment)
                        .position(
                            x: clampedTooltipX(hoverAnchorX, barWidth: proxy.size.width),
                            y: -18
                        )
                        // 浮层只做即时说明，不能抢走横条按钮的点击和 hover 命中。
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 6)
        .task(id: repo.id) {
            clearHover()
            await viewModel.load(
                repoID: repo.id,
                owner: repo.owner,
                name: repo.name
            )
        }
    }

    @ViewBuilder
    private func segmentView(
        _ segment: RepositoryLanguageDistributionViewModel.Segment
    ) -> some View {
        let title = segment.language ?? String.l10n("sidebar.languages.other")
        let tooltip = "\(title) · \(segment.fraction.formatted(.percent.precision(.fractionLength(1))))"

        if let language = segment.language {
            Button {
                onLanguageTapped(language)
            } label: {
                Rectangle()
                    .fill(LanguageColor.color(for: language))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .accessibilityLabel(Text(verbatim: tooltip))
        } else {
            // Other 是多个语言的聚合，无法映射到单个主语言筛选，因此只展示说明、不响应点击。
            Rectangle()
                .fill(Color.secondary.opacity(0.45))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: tooltip))
        }
    }

    /// 即时 hover 浮层沿用洞察图表的紧凑 Material 视觉，不参与 Hero 布局高度。
    private func hoverTooltip(
        for segment: RepositoryLanguageDistributionViewModel.Segment
    ) -> some View {
        Text(verbatim: tooltipText(for: segment))
            .font(interfaceScale.font(.captionSmall, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
    }

    /// 光标只需命中整条横线；用累计占比反查语言，极窄分段也不会因独立 hit-test 丢事件。
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

    private func hoverTarget(
        at x: CGFloat,
        barWidth: CGFloat
    ) -> (segment: RepositoryLanguageDistributionViewModel.Segment, centerX: CGFloat)? {
        guard barWidth > 0, !viewModel.segments.isEmpty else { return nil }
        let normalizedX = min(max(Double(x / barWidth), 0), 1)
        var lowerBound = 0.0

        for segment in viewModel.segments {
            let upperBound = lowerBound + segment.fraction
            if normalizedX <= upperBound {
                let centerX = CGFloat((lowerBound + upperBound) / 2) * barWidth
                return (segment, centerX)
            }
            lowerBound = upperBound
        }

        // 浮点累计可能略小于 1；最右侧像素仍应归到最后一段。
        guard let last = viewModel.segments.last else { return nil }
        return (last, barWidth)
    }

    private func tooltipText(
        for segment: RepositoryLanguageDistributionViewModel.Segment
    ) -> String {
        let title = segment.language ?? String.l10n("sidebar.languages.other")
        let percentage = segment.fraction.formatted(.percent.precision(.fractionLength(1)))
        return "\(title) · \(percentage)"
    }

    /// 预留约半个常见 tooltip 宽度，避免最左/最右语言段的浮层被详情栏裁掉。
    private func clampedTooltipX(_ proposedX: CGFloat, barWidth: CGFloat) -> CGFloat {
        let safeInset: CGFloat = 96
        guard barWidth > safeInset * 2 else { return barWidth / 2 }
        return min(max(proposedX, safeInset), barWidth - safeInset)
    }

    private func clearHover() {
        hoveredSegment = nil
        hoverAnchorX = 0
    }
}
