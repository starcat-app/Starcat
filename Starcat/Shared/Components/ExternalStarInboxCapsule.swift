//
//  ExternalStarInboxCapsule.swift
//  Starcat
//
//  「星标 → 全部仓库」中栏浮层：用 owner 头像提示有外部新增 star。
//
//  关键约束：
//  - 只覆盖列表顶部，不改列表高度，也不挡住顶栏刷新按钮。
//  - 向上箭头提示点击后立即回顶；最多 3 个头像，超出用 +N。
//  - 出现 / 消失 / 队列变长都要过渡；减少动态效果时只保留透明度。
//  - 点击走 ExternalStarInbox.apply()，复用现有增量同步。
//

import SwiftUI

/// 外部新增星标的蓝色胶囊。
struct ExternalStarInboxCapsule: View {
    let items: [ExternalStarInbox.Item]
    let onTap: () -> Void

    private static let avatarSize: CGFloat = 22
    private static let overlap: CGFloat = 8

    var body: some View {
        let helpText = String(
            format: String.l10n("list.externalStarInbox.helpFormat"),
            items.count
        )
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up")
                    .font(.caption.weight(.semibold))
                    // 蓝色胶囊中的操作图标使用 on-accent 白色，保持明暗主题下的对比度。
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)

                HStack(spacing: -Self.overlap) {
                    ForEach(
                        Array(ExternalStarInboxPresentation.slots(from: items).enumerated()),
                        id: \.offset
                    ) { _, slot in
                        slotView(slot)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor, in: Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(helpText)
        .accessibilityLabel(helpText)
    }

    @ViewBuilder
    private func slotView(_ slot: ExternalStarInboxPresentation.Slot) -> some View {
        switch slot {
        case .avatar(_, _, let url):
            RemoteAvatar(urlString: url, size: Self.avatarSize, showBorder: false)
                .overlay {
                    // 蓝底上需要白描边才能把叠放头像分开；这不是装饰弱化。
                    Circle().stroke(.white.opacity(0.9), lineWidth: 1)
                }
        case .overflow(let count):
            // 胶囊底是 accent，+N 必须用 on-accent 白字才能读。
            Text("+\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: Self.avatarSize, height: Self.avatarSize)
                .background(Color.accentColor.opacity(0.35), in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.9), lineWidth: 1)
                }
        }
    }
}
