//
//  RepoDetailNoSelectionPlaceholder.swift
//  Starcat
//
//  详情区未选中条目时的共享占位视图。
//
//  适用范围：Manage / Trending / Activity / Weekly 的右侧详情列。这个组件只表达
//  “当前没有选中可展示的 repo 或项目”，不承载列表空态、错误态或 Smart Collections
//  集合浏览态。Smart Collections 的 selectedRepoID == nil 是产品入口，不应复用这里。
//

import SwiftUI

/// 详情列未选中内容时的轻量示意图 + 单行提示。
///
/// 设计约束：
/// - 使用已确认的 3D 透明插画，让空白区域自然透出当前明暗主题背景；
/// - 保持素材原始宽高比，并沿用详情列的响应式尺寸与图文间距；
/// - 默认只显示一行提示文字，避免空态在工具型主界面里过度解释。
struct RepoDetailNoSelectionPlaceholder: View {

    private static let illustrationBaseSize = CGSize(width: 360, height: 240)
    private static let illustrationAspectRatio = illustrationBaseSize.width / illustrationBaseSize.height
    private static let horizontalPadding: CGFloat = 48
    private static let verticalPadding: CGFloat = 64
    private static let captionReservedHeight: CGFloat = 34
    private static let minimumMessageSpacing: CGFloat = 36
    private static let maximumMessageSpacing: CGFloat = 68
    private static let compactMaximumWidth: CGFloat = 520
    private static let expandedMaximumWidth: CGFloat = 760
    private static let widthFillRatio: CGFloat = 0.48

    private struct LayoutMetrics {
        let illustrationSize: CGSize
        let messageSpacing: CGFloat
    }

    private let messageKey: LocalizedStringKey

    init(messageKey: LocalizedStringKey = "empty.selectFromList") {
        self.messageKey = messageKey
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = layoutMetrics(in: proxy.size)

            VStack(spacing: 0) {
                // 文案已表达选择动作，插画不重复进入 VoiceOver 的阅读顺序。
                Image(decorative: "RepoDetailNoSelectionArtwork")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: metrics.illustrationSize.width, height: metrics.illustrationSize.height)

                Spacer(minLength: 0)
                    .frame(height: metrics.messageSpacing)

                Text(messageKey)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: Self.captionReservedHeight, alignment: .top)
            }
            .padding(.horizontal, Self.horizontalPadding)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func layoutMetrics(in containerSize: CGSize) -> LayoutMetrics {
        // 透明 PNG 已包含素材留白，不再为旧 SwiftUI 示意图的外溢阴影预留高度。
        // 先按宽度估算图文间距，再用可用高度限制插画；矮窗口优先缩图，
        // 避免说明文字被挤出详情列。宽高比与 1536x1024 的原图保持一致。
        let availableWidth = max(160, containerSize.width - Self.horizontalPadding * 2)
        let responsiveMaximumWidth = responsiveMaximumWidth(for: availableWidth)
        let tentativeWidth = min(responsiveMaximumWidth, availableWidth)
        let tentativeScale = tentativeWidth / Self.illustrationBaseSize.width
        let reservedMessageSpacing = messageSpacing(for: tentativeScale)

        let availableHeight = max(
            120,
            containerSize.height
                - Self.verticalPadding * 2
                - Self.captionReservedHeight
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
            messageSpacing: messageSpacing(for: scale)
        )
    }

    private func responsiveMaximumWidth(for availableWidth: CGFloat) -> CGFloat {
        min(
            Self.expandedMaximumWidth,
            max(Self.compactMaximumWidth, availableWidth * Self.widthFillRatio)
        )
    }

    private func messageSpacing(for scale: CGFloat) -> CGFloat {
        let scaled = Self.minimumMessageSpacing + max(0, scale - 1) * 22
        return min(Self.maximumMessageSpacing, scaled)
    }

}
