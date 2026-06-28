//
//  RepoRecommendButton.swift
//  Starcat
//
//  详情页 hero trailing actions 的相似推荐入口。
//
//  视觉契约（v1.1.1 修订，2026-06-29）：
//  - 与左侧 Wiki 入口（`RepoWikiMenu`）同款「28×28 capsule icon-only」样式：
//    28×28 frame、Capsule 底（accentColor 0.15 浅色填充）、13pt semibold icon（accentColor 主色）
//  - 8pt accentColor 小圆点徽章：仅 `hasItems == true` 时显示，
//    用于「有东西看」的低成本信号（不显示具体 count，避免视觉噪音）
//  - 必须 `.focusEffectDisabled()` —— CLAUDE.md「所有 .buttonStyle(.plain) Button 强制」
//
//  接入方式：放在 `RepoDetailScaffold` 的 `trailingActionsView` HStack 中，
//  AI 按钮之前；外层根据 `recommendationVM.hasItems` 条件渲染整个按钮。
//
//  演化历史：
//  - v1.0：副按钮（.bordered 风格：透明背景 + 描边），与 AI 按钮同高
//  - v1.1：icon-only（去掉文字）
//  - v1.1.1（本版）：改为与 Wiki 入口同款 28×28 capsule，让 hero action 区视觉同构
//

import SwiftUI

struct RepoRecommendButton: View {

    /// 是否有推荐数据，决定是否显示 8pt accentColor 圆点徽章
    let hasItems: Bool

    /// 点击动作（外层用 `.popover(isPresented:)` 绑定 popover）
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // 与 Wiki 入口（`RepoWikiMenu.menuButton` line 66-67）同款：
            //   28×28 frame + Capsule 底（accentColor 0.15 浅色填充）+ 13pt semibold icon
            //   颜色用 accentColor 而非 indigo —— 推荐是「discover similar」发现型能力，
            //   与系统的 accent 色同源；与 dot badge 颜色也统一，避免一个按钮内出现
            //   两种强调色。
            //   SR 用户靠 .accessibilityLabel / .help 兜底识别。
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
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
        .fixedSize()
    }
}
