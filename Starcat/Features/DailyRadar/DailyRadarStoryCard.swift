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
    @Environment(\.locale) private var locale
    @State private var hovered = false

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
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .accessibilityHidden(true)

                    if featured {
                        // 本地封面在文字安全区降低细节与亮度，文字固定深色语义
                        // 环境（白字），保持明暗主题下相同的阅读对比。
                        VStack(alignment: .leading, spacing: 14) {
                            Text("dailyRadar.featured")
                                .font(scale.font(size: 12, weight: .semibold))
                                .tracking(2)
                            Spacer(minLength: 12)
                            Text(verbatim: story.title)
                                .font(scale.font(size: 34, weight: .bold))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: story.summary)
                                .font(scale.font(size: 14))
                                .lineLimit(2)
                                .frame(maxWidth: 380, alignment: .leading)
                            HStack(spacing: 8) {
                                Text("dailyRadar.read")
                                Image(systemName: "arrow.right")
                            }
                            .font(scale.font(size: 12, weight: .semibold))
                            .padding(.top, 4)
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.primary)
                        .environment(\.colorScheme, .dark)
                    }
                }
                .frame(height: featured ? scale.scaled(320) : 160)

                if !featured {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: DailyRadarCatalog.Category.localizedTitle(for: story.category))
                            .font(scale.font(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(verbatim: story.title.replacingOccurrences(of: "\n", with: ""))
                            .font(scale.font(size: 20, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(verbatim: story.summary)
                            .font(scale.font(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(verbatim: String(format: String.l10n("dailyRadar.readingTime"), locale: locale, story.minutes.formatted(.number.locale(locale))))
                            .font(scale.font(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(hovered ? 0.18 : 0.06), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(verbatim: story.title.replacingOccurrences(of: "\n", with: "")))
        .accessibilityHint(Text("dailyRadar.read"))
    }
}
