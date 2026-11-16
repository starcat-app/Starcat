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
//    2. `TrendingRepoRowSurface` (Features/Trending/TrendingRepoRowView.swift) ← 已删除（R-01 v1.2 Phase B2）
//    3. `ActivityRowSurface` (Features/Activity/ActivityView.swift)
//    4. `WeeklyProjectRow` 内嵌容器 (Features/Activity/WeeklyContentView.swift) ← 待删（R-01 v1.2 Phase B4）
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
//  - 左侧恒定预留 5pt 给 accent bar，切换时文字和图标不移动
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
    /// 每个持续单选列表持有自己的共享空间；多选模式传 nil，保留每个选中项。
    let selectionNamespace: Namespace.ID?
    /// 紧凑的常规选择器传可见行序号；仓库卡片继续使用原有语义底色。
    let rowIndex: Int?

    private let content: Content

    @Environment(\.starcatReduceMotion) private var reduceMotion
    @Environment(\.starcatListInteractionSuppressed) private var interactionSuppressed
    @State private var isHovered = false

    init(
        isSelected: Bool,
        accentColor: Color? = nil,
        selectionNamespace: Namespace.ID? = nil,
        rowIndex: Int? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.accentColor = accentColor
        self.selectionNamespace = selectionNamespace
        self.rowIndex = rowIndex
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
        if let rowIndex, rowIndex.isMultiple(of: 2) { return 0 }
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
            .padding(.leading, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Group {
                    if isSelected, let selectionNamespace, !reduceMotion {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(resolvedAccent.opacity(backgroundOpacity))
                            .background {
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .stroke(resolvedAccent.opacity(borderOpacity), lineWidth: 1)
                            }
                            .matchedGeometryEffect(id: "repo-row-selection", in: selectionNamespace)
                    } else {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(resolvedAccent.opacity(backgroundOpacity))
                            .background {
                                // 半透明底色让浅色、深色背景下的选中与悬停均清晰可见。
                                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected || isHovered ? 0.40 : 0.0))
                            }
                    }
                }
                // 背景滑动与正文布局分开，选择变化不能给整张卡片注入弹簧交易。
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
                .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: isSelected)
            }
            .overlay(alignment: .leading) {
                // 选中态左侧 3pt accent bar（设计 §3.1.4）
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(resolvedAccent)
                    .frame(width: isSelected ? 3 : 0)
                    .padding(.vertical, 8)
                    .opacity(isSelected ? 1 : 0)
                    .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: isSelected)
            }
            .overlay {
                if !isSelected || selectionNamespace == nil || reduceMotion {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(resolvedAccent.opacity(borderOpacity), lineWidth: 1)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
                        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82), value: isSelected)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onHover { hovering in
                guard !interactionSuppressed else {
                    if isHovered {
                        isHovered = false
                    }
                    return
                }
                isHovered = hovering
            }
            .onChange(of: interactionSuppressed) { _, isSuppressed in
                // 滚动开始时立即清掉旧 hover，避免离开该 row 后仍残留高亮。
                if isSuppressed, isHovered {
                    isHovered = false
                }
            }
    }
}
