//
//  RepoRecommendButton.swift
//  Starcat
//
//  详情页 hero trailing actions 的相似推荐入口。
//
//  视觉契约（v1.1.2 修订，2026-09-06）：
//  - 与左侧 Wiki 入口（`RepoWikiMenu`）同款「28×28 capsule icon-only」样式：
//    28×28 frame、中性 Capsule 底、13pt semibold icon（accentColor 主色）
//  - 推荐入口不叠加状态点；外层已通过 `recommendationVM.hasItems` 控制是否显示
//  - 必须 `.focusEffectDisabled()` —— CLAUDE.md「所有 .buttonStyle(.plain) Button 强制」
//
//  接入方式：放在 `RepoDetailScaffold` 的 `trailingActionsView` HStack 中，
//  AI 按钮之前；外层根据 `recommendationVM.hasItems` 条件渲染整个按钮。
//
//  演化历史：
//  - v1.0：副按钮（.bordered 风格：透明背景 + 描边），与 AI 按钮同高
//  - v1.1：icon-only（去掉文字）
//  - v1.1.1：改为与 Wiki 入口同款 28×28 capsule，让 hero action 区视觉同构
//  - v1.1.2：移除状态点，并统一为自适应明暗主题的中性背景
//

import SwiftUI

struct RepoRecommendButton: View {

    /// 点击动作（外层用 `.popover(isPresented:)` 绑定 popover）
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            // 推荐图标保留 accentColor 语义色，背景使用 Hero 共用的中性色，
            // 避免高对比底色放大视觉体积，也避免背景与图标同色。
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background {
                    Capsule(style: .continuous)
                        .fill(HeroActionIconStyle.background(colorScheme: colorScheme))
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
