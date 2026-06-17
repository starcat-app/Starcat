//
//  DetailHeroTintBackground.swift
//  Starcat
//
//  右侧详情页顶部 accent 色光晕（延伸到 window toolbar 区域）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（2026-06-17）：4 详情页 + 中栏 repo 列表根节点统一顶部 accent 光晕，
//  延伸到透明 window toolbar（`ContentView.toolbarBackground(.hidden)`）。
//  ────────────────────────────────────────────────────────────────────────────
//
//  `ContentView` 已 `.toolbarBackground(.hidden, for: .windowToolbar)`，toolbar
//  区域透明后若详情列根节点不绘制 tint，会露出窗口底色，与 hero 卡片形成横向硬分界。
//
//  **为什么不能挂在 `RepoMetadataHeaderView` / `activityMetadataPanel` 内部？**
//  Manage 路径的 hero 包在 `CollapsibleRepoMetadataPanel` 里，外层 `.clipped()` 会裁掉
//  子 view `ignoresSafeArea` 向上溢出的渐变——注释写了延伸 titlebar，运行时到不了。
//
//  **正确挂点**：详情分支根 VStack / ZStack 的 `.background(alignment: .top)`，与
//  `SidebarHeaderView.sidebarTintFrame` 同款策略（见该文件 `ignoresSafeArea(edges: .top)`）。
//
//  **顶部 stop 必须从 opacity 0 淡入**（Sidebar 2026-06-02 22:27 修硬色边同款）：
//  若顶部直接 `tint.opacity(0.18)`，与透明 toolbar 交界处仍会有一条色带。
//

import SwiftUI

/// 详情页顶部 hero tint 渐变层；挂在详情根节点，配合透明 window toolbar 使用。
struct DetailHeroTintBackground: View {

    let tint: Color

    /// 全局透明度乘子（`RepoDetailScaffold` 折叠 hero 时绑 `1 - collapseProgress` 淡出）。
    var overallOpacity: CGFloat = 1

    /// repo-backed 详情 accent：语言色优先，无语言时走场景 fallback（Activity 分类色等）。
    static func accentColor(language: String?, fallback: Color) -> Color {
        if let language, !language.isEmpty {
            return LanguageColor.color(for: language)
        }
        return fallback
    }

    /// 渐变可视高度（pt）。须大于 hero 区对角线量级，让底部 alpha≈0 落在边界外。
    private let gradientHeight: CGFloat = 220

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: tint.opacity(0), location: 0),
                .init(color: tint.opacity(0.18), location: 0.14),
                .init(color: tint.opacity(0.08), location: 0.42),
                .init(color: tint.opacity(0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: .infinity)
        .frame(height: gradientHeight)
        .opacity(overallOpacity)
        .allowsHitTesting(false)
        // 绘制进 titlebar / toolbar 透明区域；不扩其它边，避免影响底部 batch bar inset。
        .ignoresSafeArea(edges: .top)
    }
}

extension View {

    /// 详情根节点顶部 accent 光晕（透明 toolbar 前提下延伸到标题栏）。
    func detailHeroTintBackground(tint: Color, opacity: CGFloat = 1) -> some View {
        background(alignment: .top) {
            DetailHeroTintBackground(tint: tint, overallOpacity: opacity)
        }
    }
}
