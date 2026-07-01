//
//  RepoHealthBadge.swift
//  Starcat
//
//  Repo Health 小型胶囊徽章 —— 详情页 hero 与 Manage 列表 row 共用。
//
//  设计要点：
//  - 视觉风格与 OpenSSFScoreBadge 对齐：图标 + 分数 + 等级 + 彩色背景 + 细描边。
//  - 颜色由 RepoHealthTint 自动派生；C/D 档使用更深的 amber，避免浅色主题下系统黄对比度不足。
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
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(interfaceScale.font(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(verbatim: data.grade)
                .font(interfaceScale.font(size: 11, weight: .bold))
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

    private var tint: Color {
        RepoHealthTint.color(grade: data.grade, colorScheme: colorScheme)
    }
}

/// Repo Health 的统一语义色。
///
/// 小型 badge 与项目健康度窗口必须共享这里的映射，避免列表里可读、窗口里仍偏浅。
enum RepoHealthTint {
    /// 所有等级颜色都在这里显式声明，后续只改这一处即可同步所有 health 展示。
    static func color(grade: String, colorScheme: ColorScheme) -> Color {
        switch grade {
        case "A":
            return resolved(light: 0x16803C, dark: 0x4ADE80, colorScheme: colorScheme)
        case "B":
            return resolved(light: 0x2E7D8A, dark: 0x5DD4E8, colorScheme: colorScheme)
        case "C":
            return resolved(light: 0xA16207, dark: 0xFACC15, colorScheme: colorScheme)
        case "D":
            return resolved(light: 0xC2410C, dark: 0xFB923C, colorScheme: colorScheme)
        default:
            return resolved(light: 0xB91C1C, dark: 0xF87171, colorScheme: colorScheme)
        }
    }

    /// 分数展示也先归一到等级，再复用同一张颜色表，避免窗口与 badge 规则漂移。
    static func color(score: Double, colorScheme: ColorScheme) -> Color {
        color(grade: grade(for: score), colorScheme: colorScheme)
    }

    private static func grade(for score: Double) -> String {
        switch score {
        case 90...: return "A"
        case 80..<90: return "B"
        case 70..<80: return "C"
        case 60..<70: return "D"
        default: return "E"
        }
    }

    /// light/dark 必须成对声明，避免系统色在浅色主题下过浅或暗色主题下过艳。
    private static func resolved(light: UInt32, dark: UInt32, colorScheme: ColorScheme) -> Color {
        Color.fromHex6(colorScheme == .dark ? dark : light)
    }
}
