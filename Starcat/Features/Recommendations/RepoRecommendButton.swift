//
//  RepoRecommendButton.swift
//  Starcat
//
//  详情页 hero trailing actions 的相似推荐入口。
//
//  视觉契约：
//  - 副按钮（.bordered 风格：透明背景 + 描边），与左侧 AI 按钮同高同 cornerRadius
//  - 8pt accentColor 小圆点徽章：仅 `hasItems == true` 时显示，
//    用于「有东西看」的低成本信号（不显示具体 count，避免视觉噪音）
//  - 必须 `.focusEffectDisabled()` —— CLAUDE.md「所有 .buttonStyle(.plain) Button 强制」
//
//  接入方式：放在 `RepoDetailScaffold` 的 `trailingActionsView` HStack 中，
//  AI 按钮之前；外层根据 `recommendationVM.hasItems` 条件渲染整个按钮。
//

import SwiftUI

struct RepoRecommendButton: View {

    /// 是否有推荐数据，决定是否显示 8pt accentColor 圆点徽章
    let hasItems: Bool

    /// 点击动作（外层用 `.popover(isPresented:)` 绑定 popover）
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // icon-only：去掉文字后 padding(horizontal) 从 12 缩到 8，让 icon 居中。
            // 视觉上仍是「副按钮胶囊」（bordered + 透明），与 AI 按钮同高。
            // SR 用户靠 .accessibilityLabel / .help 兜底识别。
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .foregroundStyle(.primary)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.clear)
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1)
                }
                // 8pt accentColor 圆点：表示「有推荐」的低成本信号
                // alignment 放 topTrailing + offset 把它顶到 icon 右上角外
                .overlay(alignment: .topTrailing) {
                    if hasItems {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .pressableHover()
        .help(Text("repo.recommendations.open"))
        .accessibilityLabel(Text("repo.recommendations.open"))
    }
}
