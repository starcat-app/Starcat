// DailyRadarProjectBadgeCluster.swift
// 报告关联 GitHub 项目的头像徽标组，供历史行、小卡 metadata 与专题 hero 三处复用。
//
// 为什么独立成组件：三处场景都要展示「报告里包含哪些项目」，数量上限、深浅底色和
// 无障碍语义一致才能保持扫描体验稳定；头像组不新增独立点击，避免与整卡 / 整行按钮冲突。

import SwiftUI

/// 重叠头像组：超过 `maxVisible` 时只展示前 N 个并追加 `+N` 徽标。
struct DailyRadarProjectBadgeCluster: View {
    let badges: [DailyRadarReport.ProjectBadge]
    var maxVisible: Int = 4
    var avatarSize: CGFloat = 22
    var style: Style = .surface

    /// surface 用于浅色列表 / 卡片；hero 用于深色封面右下角。
    enum Style {
        case surface
        case hero
    }

    @Environment(\.starcatInterfaceScale) private var scale

    private var visible: [DailyRadarReport.ProjectBadge] {
        Array(badges.prefix(maxVisible))
    }
    private var hiddenCount: Int { max(0, badges.count - visible.count) }
    private var accessibilityNames: String {
        badges.map(\.fullName).joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: avatarSize * 0.26) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, badge in
                DailyRadarProjectBadgeAvatar(badge: badge, size: avatarSize, style: style)
                    .zIndex(Double(visible.count - index))
            }
            if hiddenCount > 0 {
                Text(verbatim: "+\(hiddenCount)")
                    .font(scale.font(size: max(10, avatarSize * 0.42), weight: .semibold))
                    .foregroundStyle(style == .hero ? .white : .primary)
                    .frame(minWidth: avatarSize, minHeight: avatarSize)
                    .background {
                        Capsule().fill(style == .hero ? Color.black.opacity(0.55) : Color(nsColor: .controlBackgroundColor))
                    }
                    .overlay {
                        Capsule().strokeBorder(style == .hero ? Color.white.opacity(0.30) : Color.primary.opacity(0.16), lineWidth: 1)
                    }
                    .zIndex(0)
            }
        }
        // 整组不承载点击；hover 提示完整项目名，方便快速确认报告内容。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityNames))
        .help(accessibilityNames)
    }
}

/// 单枚项目头像：远程头像失败或缺失时回退到 owner 首字母。
private struct DailyRadarProjectBadgeAvatar: View {
    let badge: DailyRadarReport.ProjectBadge
    let size: CGFloat
    let style: DailyRadarProjectBadgeCluster.Style

    private var ringColor: Color {
        style == .hero ? Color.white.opacity(0.55) : Color(nsColor: .controlBackgroundColor)
    }

    var body: some View {
        Group {
            if let urlString = badge.ownerAvatar, !urlString.isEmpty {
                RemoteAvatar(urlString: urlString, size: size, showBorder: false)
            } else {
                Text(verbatim: badge.initial)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(style == .hero ? .white : .secondary)
                    .frame(width: size, height: size)
                    .background {
                        Circle().fill(style == .hero ? Color.white.opacity(0.16) : Color.primary.opacity(0.10))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(ringColor, lineWidth: 1)
        }
    }
}
