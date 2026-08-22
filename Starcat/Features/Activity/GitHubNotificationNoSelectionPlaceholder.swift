//
//  GitHubNotificationNoSelectionPlaceholder.swift
//  Starcat
//
//  通知时间线右栏未选中事件时的示意图空态。
//
//  为什么单独做、不复用 `RepoDetailNoSelectionPlaceholder`：
//  那张图画的是「仓库列表 + Star 详情」，语义是选 repo；这里要教的是
//  「中栏时间线点一条 → 右栏出 Issue 会话」。复用会让空态和当前页对不上。
//
//  设计约束：
//  - SwiftUI shape 生成，不引入图片资源；自动跟明暗主题和 accent。
//  - 固定 360×222 设计稿整体缩放，避免内部 mock 线比例散掉。
//  - 不做四角星 / 大光晕 / 快捷键 chip：主窗口空态保持工具气质，
//    且空态下并没有方向键切事件的能力，不能挂一个还不存在的提示。
//

import SwiftUI

/// 通知时间线详情列未选中事件时的示意图 + 标题 + 说明。
struct GitHubNotificationNoSelectionPlaceholder: View {

    private static let illustrationBaseSize = CGSize(width: 360, height: 222)
    private static let illustrationAspectRatio = illustrationBaseSize.width / illustrationBaseSize.height
    private static let horizontalPadding: CGFloat = 48
    private static let verticalPadding: CGFloat = 56
    private static let titleReservedHeight: CGFloat = 22
    private static let subtitleReservedHeight: CGFloat = 40
    private static let textStackSpacing: CGFloat = 8
    private static let textBlockHeight: CGFloat =
        titleReservedHeight + textStackSpacing + subtitleReservedHeight
    private static let minimumMessageSpacing: CGFloat = 28
    private static let maximumMessageSpacing: CGFloat = 56
    private static let compactMaximumWidth: CGFloat = 520
    private static let expandedMaximumWidth: CGFloat = 720
    private static let widthFillRatio: CGFloat = 0.52
    private static let subtitleMaxWidth: CGFloat = 320

    private struct LayoutMetrics {
        let illustrationSize: CGSize
        let illustrationScale: CGFloat
        let messageSpacing: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = layoutMetrics(in: proxy.size)

            VStack(spacing: 0) {
                GitHubNotificationNoSelectionIllustration()
                    .frame(
                        width: Self.illustrationBaseSize.width,
                        height: Self.illustrationBaseSize.height
                    )
                    .scaleEffect(metrics.illustrationScale)
                    .frame(width: metrics.illustrationSize.width, height: metrics.illustrationSize.height)

                Spacer(minLength: 0)
                    .frame(height: metrics.messageSpacing)

                VStack(spacing: Self.textStackSpacing) {
                    Text("activity.notification.detail.empty.title")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)

                    Text("activity.notification.detail.empty.subtitle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: Self.subtitleMaxWidth)
                }
                .frame(minHeight: Self.textBlockHeight, alignment: .top)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func layoutMetrics(in containerSize: CGSize) -> LayoutMetrics {
        // 以 360×222 为设计基准只做整体缩放。窗口变矮时优先缩小示意图，
        // 给标题 / 说明留出可读高度，避免文案贴到分栏边框。
        let availableWidth = max(160, containerSize.width - Self.horizontalPadding * 2)
        let responsiveMaximumWidth = min(
            Self.expandedMaximumWidth,
            max(Self.compactMaximumWidth, availableWidth * Self.widthFillRatio)
        )
        let tentativeWidth = min(responsiveMaximumWidth, availableWidth)
        let tentativeScale = tentativeWidth / Self.illustrationBaseSize.width
        let reservedMessageSpacing = messageSpacing(for: tentativeScale)

        let availableHeight = max(
            120,
            containerSize.height
                - Self.verticalPadding * 2
                - Self.textBlockHeight
                - reservedMessageSpacing
        )
        let heightLimitedWidth = availableHeight * Self.illustrationAspectRatio
        let maximumWidth = max(160, min(responsiveMaximumWidth, availableWidth, heightLimitedWidth))
        let minimumWidth = min(240, maximumWidth)
        let preferredWidth = min(availableWidth * Self.widthFillRatio, maximumWidth)
        let width = max(minimumWidth, preferredWidth)
        let scale = width / Self.illustrationBaseSize.width

        return LayoutMetrics(
            illustrationSize: CGSize(width: width, height: width / Self.illustrationAspectRatio),
            illustrationScale: scale,
            messageSpacing: messageSpacing(for: scale)
        )
    }

    private func messageSpacing(for scale: CGFloat) -> CGFloat {
        let scaled = Self.minimumMessageSpacing + max(0, scale - 1) * 18
        return min(Self.maximumMessageSpacing, scaled)
    }
}

// MARK: - Illustration

/// 左时间线选中行 → 虚线弧 → 右会话卡片。坐标锁在 360×222 设计稿上，由外层 `scaleEffect` 一起缩放。
private struct GitHubNotificationNoSelectionIllustration: View {

    var body: some View {
        ZStack {
            HStack(spacing: 22) {
                timelinePreview
                    .frame(width: 124)

                conversationPreview
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)

            SelectionConnector()
                .stroke(
                    Color.accentColor.opacity(0.42),
                    style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [4, 3.5])
                )
        }
        .frame(width: 360, height: 222)
        .accessibilityHidden(true)
    }

    private var timelinePreview: some View {
        VStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                timelineRow(index)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity)
        .background(panelFill)
        .overlay(panelStroke)
        .overlay(alignment: .leading) {
            // 时间线轴线：和中栏真实行一样靠左，选中行用 accent 圆点。
            RoundedRectangle(cornerRadius: 0.5, style: .continuous)
                .fill(Color.primary.opacity(0.12))
                .frame(width: 1)
                .padding(.vertical, 22)
                .padding(.leading, 13)
        }
    }

    private var conversationPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 5) {
                    previewLine(width: 92, height: 6, opacity: 0.20)
                    previewLine(width: 64, height: 5, opacity: 0.10)
                }
                Spacer(minLength: 0)
            }

            commentCard(lineWidth: 118)
            commentCard(lineWidth: 96)

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .frame(height: 28)
                .overlay(alignment: .leading) {
                    previewLine(width: 88, height: 5, opacity: 0.10)
                        .padding(.leading, 10)
                }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(panelFill)
        .overlay(panelStroke)
    }

    private func timelineRow(_ index: Int) -> some View {
        let isSelected = index == 1

        return HStack(spacing: 8) {
            Circle()
                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.22))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 5) {
                previewLine(
                    width: isSelected ? 58 : 48,
                    height: 5,
                    opacity: isSelected ? 0.22 : 0.12
                )
                previewLine(
                    width: isSelected ? 40 : 34,
                    height: 4,
                    opacity: isSelected ? 0.12 : 0.08
                )
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.38) : Color.clear,
                    lineWidth: 1
                )
        }
    }

    private func commentCard(lineWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 5) {
                previewLine(width: lineWidth, height: 5, opacity: 0.12)
                previewLine(width: lineWidth * 0.72, height: 5, opacity: 0.08)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var panelFill: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
    }

    private var panelStroke: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }

    private func previewLine(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.primary.opacity(opacity))
            .frame(width: width, height: height)
    }
}

/// 从左栏选中行右缘画到右栏标题，表达「点这一条，详情出现在这里」。
private struct SelectionConnector: Shape {
    func path(in _: CGRect) -> Path {
        var path = Path()
        // 设计稿坐标：左栏右缘 20+124=144，选中第二行中心约 y=91；右栏从 166 起对准标题。
        path.move(to: CGPoint(x: 144, y: 91))
        path.addQuadCurve(
            to: CGPoint(x: 166, y: 50),
            control: CGPoint(x: 156, y: 48)
        )
        return path
    }
}

#Preview("Notification empty") {
    GitHubNotificationNoSelectionPlaceholder()
        .frame(width: 480, height: 640)
}
