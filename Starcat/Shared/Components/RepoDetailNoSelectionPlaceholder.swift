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
/// - 使用 SwiftUI shape 生成，不引入图片资源或第三方素材版权；
/// - 以固定设计稿为基准整体缩放，保证内部 mock line、圆角、阴影比例稳定；
/// - 默认只显示一行提示文字，避免空态在工具型主界面里过度解释。
struct RepoDetailNoSelectionPlaceholder: View {

    private static let illustrationBaseSize = CGSize(width: 360, height: 222)
    private static let illustrationAspectRatio = illustrationBaseSize.width / illustrationBaseSize.height
    private static let horizontalPadding: CGFloat = 48
    private static let verticalPadding: CGFloat = 64
    private static let captionReservedHeight: CGFloat = 34
    private static let minimumMessageSpacing: CGFloat = 36
    private static let maximumMessageSpacing: CGFloat = 68
    private static let baseIllustrationVisualBleed: CGFloat = 28
    private static let maximumIllustrationVisualBleed: CGFloat = 72
    private static let compactMaximumWidth: CGFloat = 520
    private static let expandedMaximumWidth: CGFloat = 760
    private static let widthFillRatio: CGFloat = 0.48

    private struct LayoutMetrics {
        let illustrationSize: CGSize
        let illustrationScale: CGFloat
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
                RepoDetailNoSelectionIllustration()
                    .frame(
                        width: Self.illustrationBaseSize.width,
                        height: Self.illustrationBaseSize.height
                    )
                    .scaleEffect(metrics.illustrationScale)
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
        // 以 360x222 为设计基准，只在外层整体缩放，避免内部每条 mock line 的比例散掉。
        //
        // 这里不能只看容器高度做粗略 reserve：示意图自带 shadow / glow，视觉边界会
        // 超出自身 frame，且这个溢出会随 scale 一起变大。先按详情区宽度估算一个
        // tentative scale，再用这个 scale 扣掉图文间距和视觉溢出；窗口变矮时优先
        // 缩小示意图，窗口变宽时也不会让底部提示贴到边框上。
        let availableWidth = max(160, containerSize.width - Self.horizontalPadding * 2)
        let responsiveMaximumWidth = responsiveMaximumWidth(for: availableWidth)
        let tentativeWidth = min(responsiveMaximumWidth, availableWidth)
        let tentativeScale = tentativeWidth / Self.illustrationBaseSize.width
        let reservedMessageSpacing = messageSpacing(for: tentativeScale)
        let reservedVisualBleed = illustrationVisualBleed(for: tentativeScale)

        let availableHeight = max(
            120,
            containerSize.height
                - Self.verticalPadding * 2
                - Self.captionReservedHeight
                - reservedMessageSpacing
                - reservedVisualBleed
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

    private func illustrationVisualBleed(for scale: CGFloat) -> CGFloat {
        min(Self.maximumIllustrationVisualBleed, Self.baseIllustrationVisualBleed * max(1, scale))
    }
}

// MARK: - Illustration

/// 右侧详情未选中 repo 时的轻量示意图。
///
/// 这里刻意使用 SwiftUI shape 生成抽象 mockup，而不是放一张固定图片：
/// - 可自动适配明暗主题、不同缩放倍率和未来 accent 调整；
/// - 不需要维护额外图片资源，也不会引入第三方素材版权问题；
/// - 视觉语言与首次引导页的 fallback preview 保持一致，但不把 onboarding
///   的整套大面板搬进详情区，避免空态在工具型主界面里过度抢注意力。
private struct RepoDetailNoSelectionIllustration: View {

    private let starGold = Color(red: 1.0, green: 0.74, blue: 0.28)
    private let cyan = Color(red: 0.45, green: 0.78, blue: 1.0)
    private let green = Color(red: 0.50, green: 0.86, blue: 0.62)

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            cyan.opacity(0.22),
                            starGold.opacity(0.08),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 180
                    )
                )
                .frame(width: 330, height: 250)
                .blur(radius: 2)

            HStack(spacing: 14) {
                repoListPreview
                    .frame(width: 126)

                detailPreview
                    .frame(maxWidth: .infinity)
            }
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                cyan.opacity(0.42),
                                starGold.opacity(0.24),
                                Color.primary.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 14)
            .shadow(color: cyan.opacity(0.14), radius: 34, x: 0, y: 16)
        }
        .accessibilityHidden(true)
    }

    private var repoListPreview: some View {
        VStack(spacing: 9) {
            previewChrome

            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    repoRowPreview(index)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var detailPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(starGold.opacity(0.20))
                    .frame(width: 42, height: 42)
                    .overlay {
                        Image(systemName: "star.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(starGold)
                    }

                VStack(alignment: .leading, spacing: 7) {
                    previewLine(width: 128, height: 10, opacity: 0.22)
                    previewLine(width: 164, height: 7, opacity: 0.12)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                metricPill(width: 48, color: starGold)
                metricPill(width: 58, color: cyan)
                metricPill(width: 44, color: green)
            }

            VStack(alignment: .leading, spacing: 8) {
                previewLine(width: 180, height: 8, opacity: 0.16)
                previewLine(width: 206, height: 8, opacity: 0.12)
                previewLine(width: 154, height: 8, opacity: 0.10)
            }

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.055))
                .frame(height: 48)
                .overlay(alignment: .leading) {
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(cyan)
                        previewLine(width: 132, height: 8, opacity: 0.14)
                    }
                    .padding(.horizontal, 12)
                }
        }
    }

    private var previewChrome: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red.opacity(0.50)).frame(width: 7, height: 7)
            Circle().fill(Color.yellow.opacity(0.55)).frame(width: 7, height: 7)
            Circle().fill(Color.green.opacity(0.50)).frame(width: 7, height: 7)
            Spacer(minLength: 0)
        }
    }

    private func repoRowPreview(_ index: Int) -> some View {
        let accent = rowAccent(index)
        let isSelected = index == 0

        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(isSelected ? 0.26 : 0.16))
                .frame(width: 28, height: 28)
                .overlay {
                    Circle()
                        .fill(accent.opacity(0.82))
                        .frame(width: 9, height: 9)
                }

            VStack(alignment: .leading, spacing: 6) {
                previewLine(
                    width: isSelected ? 62 : 54,
                    height: 7,
                    opacity: isSelected ? 0.22 : 0.14
                )
                previewLine(
                    width: isSelected ? 76 : 66,
                    height: 6,
                    opacity: isSelected ? 0.12 : 0.08
                )
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isSelected ? accent.opacity(0.14) : Color.primary.opacity(0.045))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isSelected ? accent.opacity(0.30) : Color.primary.opacity(0.05), lineWidth: 1)
        }
    }

    private func rowAccent(_ index: Int) -> Color {
        switch index {
        case 0: return starGold
        case 1: return cyan
        default: return green
        }
    }

    private func metricPill(width: CGFloat, color: Color) -> some View {
        Capsule(style: .continuous)
            .fill(color.opacity(0.15))
            .frame(width: width, height: 20)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(color.opacity(0.82))
                    .frame(width: 6, height: 6)
                    .padding(.leading, 9)
            }
    }

    private func previewLine(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.primary.opacity(opacity))
            .frame(width: width, height: height)
    }
}
