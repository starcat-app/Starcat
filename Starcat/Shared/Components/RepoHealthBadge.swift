//
//  RepoHealthBadge.swift
//  Starcat
//
//  Repo Health 小型胶囊徽章 —— 详情页 hero 与 Manage 列表 row 共用。
//
//  设计要点：
//  - 视觉风格与 OpenSSFScoreBadge 对齐：图标 + 分数 + 等级 + 彩色背景 + 细描边。
//  - 颜色由 score 自动派生（绿 >=80 / 黄 >=60 / 红 <60），保持"分数 = 颜色"映射一致。
//  - 不带交互：列表场景仅展示；详情页如需点击进 health sheet，由调用方在外层套 Button。
//
//  v1.0（2026-06-21，dong4j 反馈"列表 row 也加 Health badge"）：
//  从 `RepoMetadataHeaderView` 内的私有 `RepoHealthInlineBadge` 抽取出来，
//  统一供详情页 + 列表行 + 未来其它场景复用，避免两处实现漂移。
//

import SwiftUI

/// 仓库健康度胶囊徽章。
///
/// 输入 `RepoHealthBadgeData`（来自 `RepoHealthStore.badge(for:)` 的本地缓存），
/// 渲染为 11pt gauge 图标 + 分数 + 等级 的紧凑胶囊。
struct RepoHealthBadge: View {
    let data: RepoHealthBadgeData

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(verbatim: data.grade)
                .font(.footnote)
                .fontWeight(.bold)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay {
            Capsule()
                .stroke(tint.opacity(0.32), lineWidth: 0.5)
        }
        .fixedSize(horizontal: true, vertical: false)
        // 详情页 + 列表行共用同一个无障碍文案，避免在两处分别实现。
        // 屏幕阅读器仍读出分数 + 等级(数字可访问性比纯字母 grade 强)。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(
                format: String.l10n("repoHealth.badge.a11y"),
                data.roundedScore,
                data.grade
            )
        )
    }

    /// 颜色随分数变化：>=80 绿 / >=60 黄 / 其余红。
    /// 与 RepoHealthSheet.healthTint 完全一致，保持"分数 ↔ 颜色"映射统一。
    private var tint: Color {
        if data.score >= 80 { return .green }
        if data.score >= 60 { return .yellow }
        return .red
    }
}
