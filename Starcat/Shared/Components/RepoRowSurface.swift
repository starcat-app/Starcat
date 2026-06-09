//
//  RepoRowSurface.swift
//  Starcat
//
//  R-01「三场景共用架构」统一卡片容器（解决 D-17 视觉骨架重复）。
//
//  ────────────────────────────────────────────────────────────────────────────
//  设计意图（详细设计 §3.1）
//  ────────────────────────────────────────────────────────────────────────────
//
//  替代原本散落 4 处、视觉 95% 相同但无法复用的 row surface 实现：
//    1. `RepoRowSurface` (Features/Home/RepoRowView.swift) ← Manage 详情页
//    2. `TrendingRepoRowSurface` (Features/Trending/TrendingRepoRowView.swift)
//    3. `ActivityRowSurface` (Features/Activity/ActivityView.swift)
//    4. `WeeklyProjectRow` 内嵌容器 (Features/Activity/WeeklyContentView.swift)
//
//  这 4 处都重新实现了「accent 边框 / hover / selected / 圆角 / 左侧 bar」逻辑，
//  数值一致但代码不一致——任何一处微调都漏改其他，是典型 D-17 漂移点。
//
//  本组件用「接受 `isSelected` + `accentColor: Color?` + `content`」的最小 API
//  收敛骨架；调用方只关心 row 的内容（HStack 布局），不再 care 视觉细节。
//
//  ────────────────────────────────────────────────────────────────────────────
//  视觉常量
//  ────────────────────────────────────────────────────────────────────────────
//
//  - 选中态：背景 accent.opacity(0.18) + 边框 accent.opacity(0.42) + 左侧 3pt accent bar
//  - hover：背景 accent.opacity(0.08) + 边框 accent.opacity(0.18)
//  - 默认：背景 accent.opacity(0.045) + 边框 accent.opacity(0.10)
//  - cornerRadius = 10，垂直 padding = 8，水平 padding = 10
//  - selected 时左侧多让 5pt 给 accent bar
//
//  这些数值与原 `RepoRowSurface` (Manage card 密度) 完全一致，平滑迁移。
//
//  ────────────────────────────────────────────────────────────────────────────
//  R-01 仅 card 密度
//  ────────────────────────────────────────────────────────────────────────────
//
//  设计 §3.1.1 + Step 7.1 决策：删除 compact 密度。本容器**不**接受 density 参数，
//  默认就是 card 密度的视觉。如果未来要做更紧凑变体，请新建另一个 surface 而非
//  在此添加 density enum（避免重蹈 D-17 覆辙）。
//

import SwiftUI

/// R-01 统一 row 视觉容器。
struct RepoRowSurface<Content: View>: View {

    /// 是否选中（选中态背景 + 边框加重 + 左侧 accent bar）。
    let isSelected: Bool

    /// 自定义 accent 颜色；nil 时用系统 accentColor。
    /// Manage / Trending 调用时通常传 `LanguageColor.color(for: repo.language)`，
    /// 其他场景可传 nil 用系统色。
    let accentColor: Color?

    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    init(
        isSelected: Bool,
        accentColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.accentColor = accentColor
        self.content = content()
    }

    // MARK: - 视觉常量

    private var resolvedAccent: Color {
        accentColor ?? .accentColor
    }

    private let cornerRadius: CGFloat = 10
    private let verticalPadding: CGFloat = 8
    private let horizontalPadding: CGFloat = 10

    private var backgroundOpacity: Double {
        if isSelected { return 0.18 }
        if isHovered { return 0.08 }
        return 0.045
    }

    private var borderOpacity: Double {
        if isSelected { return 0.42 }
        if isHovered { return 0.18 }
        return 0.10
    }

    var body: some View {
        content
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, horizontalPadding)
            .padding(.leading, isSelected ? 5 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(resolvedAccent.opacity(backgroundOpacity))
                    .background {
                        // 半透明 controlBackgroundColor 让 selected / hover 状态在
                        // 浅 / 深背景下都能凸显（参考 macOS 原生 List 的视觉手法）
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected || isHovered ? 0.40 : 0.0))
                    }
            }
            .overlay(alignment: .leading) {
                // 选中态左侧 3pt accent bar（设计 §3.1.4）
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(resolvedAccent)
                    .frame(width: isSelected ? 3 : 0)
                    .padding(.vertical, 8)
                    .opacity(isSelected ? 1 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(resolvedAccent.opacity(borderOpacity), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.14)) {
                    isHovered = hovering
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: isSelected)
    }
}
