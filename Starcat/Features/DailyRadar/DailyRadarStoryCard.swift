//
//  DailyRadarStoryCard.swift
//  Starcat
//
//  专题预览的封面卡片。大标题和整幅插画仅用于用户确认的编辑式内容区；
//  周边导航和控件继续沿用原生样式。所有可见正文都来自明确标注的样本。
//

import SwiftUI

/// 首页主推和普通专题共用的数据卡片；悬停不改变布局尺寸。
struct DailyRadarStoryCard: View {
    let story: DailyRadarReport
    let featured: Bool
    let action: () -> Void
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.locale) private var locale
    @State private var hovered = false

    /// 列表徽标由服务端返回；旧接口缺失时整组隐藏，不改变既有卡片布局。
    private var projectBadges: [DailyRadarReport.ProjectBadge] {
        story.relatedProjectBadges ?? []
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    GeometryReader { geometry in
                        // featured 大卡左侧叠标题/摘要：程序化封面通过渐变保护文字区；
                        // 普通卡/阅读页 hero 文字不压封面，保持居中。
                        DailyRadarCoverView(cover: story.cover, category: story.category,
                                            seed: story.id,
                                            textSafeLeading: featured ? 0.38 : 0)
                            .scaleEffect(hovered && !featured ? 1.01 : 1)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .accessibilityHidden(true)

                    if featured {
                        // 本地封面在文字安全区降低细节与亮度，文字固定深色语义
                        // 环境（白字），保持明暗主题下相同的阅读对比。
                        VStack(alignment: .leading, spacing: 14) {
                            DailyRadarPillLabel(onDark: true) {
                                Text("dailyRadar.featured").tracking(1)
                            }
                            Spacer(minLength: 12)
                            Text(verbatim: story.title)
                                .font(scale.font(size: 34, weight: .bold))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: story.summary)
                                .font(scale.font(size: 14))
                                .lineLimit(2)
                                .frame(maxWidth: 380, alignment: .leading)
                            DailyRadarPillLabel(emphasized: true, onDark: true) {
                                HStack(spacing: 6) {
                                    Text("dailyRadar.read")
                                    Image(systemName: "arrow.right")
                                }
                                .font(scale.font(size: 12, weight: .semibold))
                            }
                            .padding(.top, 4)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.primary)
                        .environment(\.colorScheme, .dark)
                    }
                }
                .frame(height: featured ? scale.scaled(320) : 160)
                .overlay(alignment: .bottomTrailing) {
                    if featured, !projectBadges.isEmpty {
                        // 专题 hero 右下角叠加项目徽标；胶囊底色压深保证任意封面上可读。
                        DailyRadarProjectBadgeCluster(
                            badges: projectBadges, maxVisible: 6,
                            avatarSize: 36 * scale.multiplier, style: .hero
                        )
                        .padding(.trailing, 20 * scale.multiplier)
                        .padding(.bottom, 20 * scale.multiplier)
                    }
                }

                if !featured {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(verbatim: story.title.replacingOccurrences(of: "\n", with: ""))
                                .font(scale.font(size: 20, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Text(verbatim: story.summary)
                                .font(scale.font(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            // 分类与时长同属弱化元信息；固定在卡底让两列卡的对齐关系稳定。
                            HStack(spacing: 8) {
                                DailyRadarPillLabel {
                                    HStack(spacing: 4) {
                                        Text(verbatim: DailyRadarCatalog.Category.localizedTitle(for: story.category))
                                        Text("·")
                                            .accessibilityHidden(true)
                                        Text(verbatim: String(format: String.l10n("dailyRadar.readingTime"), locale: locale, story.minutes.formatted(.number.locale(locale))))
                                    }
                                }
                                Spacer(minLength: 8)
                                if !projectBadges.isEmpty {
                                    DailyRadarProjectBadgeCluster(
                                        badges: projectBadges, maxVisible: 4,
                                        avatarSize: 26 * scale.multiplier, style: .surface
                                    )
                                    .layoutPriority(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: scale.scaled(118), alignment: .topLeading)
                        .padding(20)
                }
            }
            // 控件背景在日报页面中承担 panel 层；hover 只叠加极轻填充，不改变布局尺寸。
            .background {
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    if hovered { Color.primary.opacity(0.025) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(hovered ? 0.20 : 0.08), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering in
            guard !reduceMotion else {
                hovered = hovering
                return
            }
            withAnimation(.easeOut(duration: 0.16)) {
                hovered = hovering
            }
        }
        .accessibilityLabel(Text(verbatim: story.title.replacingOccurrences(of: "\n", with: "")))
        .accessibilityHint(Text("dailyRadar.read"))
    }
}
