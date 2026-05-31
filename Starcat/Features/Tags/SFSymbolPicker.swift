//
//  SFSymbolPicker.swift
//  Starcat
//
//  SF Symbol 图标选择器（grid 风格）+ 默认图标列表。
//
//  设计取舍：
//  - 不用 macOS 26 的 `Image(systemName:).symbolPicker(...)` 系统选择器
//    （API 仍不稳定，且 1500+ 图标对"打分类标签"场景过载）
//  - 提供 30 个精挑常用图标，覆盖：代码 / 资料 / 工具 / 概念 / 媒体 / 设备
//  - 用户想用别的图标可手填 SF Symbol 名（Phase 2 加搜索）
//

import SwiftUI

enum SFSymbolPreset {

    /// 30 个精挑 SF Symbol，覆盖常见标签分类语境。
    /// 顺序按"代码 → 工具 → 概念 → 内容 → 媒体 → 设备"分组。
    static let icons: [String] = [
        // 代码 / 开发
        "tag", "tag.fill", "number", "chevron.left.forwardslash.chevron.right",
        "curlybraces", "terminal", "hammer", "wrench.and.screwdriver",
        // 概念 / 主题
        "lightbulb", "brain.head.profile", "sparkles", "wand.and.stars",
        "star", "flag", "bookmark", "pin",
        // 内容 / 学习
        "book", "doc.text", "newspaper", "graduationcap",
        "list.bullet", "chart.bar", "chart.line.uptrend.xyaxis",
        // 媒体
        "photo", "music.note", "play.rectangle", "film",
        // 系统 / 设备
        "globe", "cpu", "cube",
    ]

    /// 默认图标（用户未选时）。
    static let defaultIcon: String = "tag"
}

/// 紧凑 grid 形式的 SF Symbol 选择器。
///
/// 行为：
/// - 点选高亮一个图标
/// - selection 为 nil 时表示"不指定图标"，UI 上无任何高亮
struct SFSymbolGridPicker: View {

    /// 当前选中的图标名，nil 表示无图标。
    @Binding var selection: String?

    /// grid 列数；macOS sheet 内默认 8 列。
    var columns: Int = 8

    private let icons: [String] = SFSymbolPreset.icons

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(icons, id: \.self) { icon in
                cell(icon: icon)
            }
        }
    }

    private func cell(icon: String) -> some View {
        let isSelected = (selection == icon)
        return Button {
            // 再次点选 = 取消（语义化"无图标"）
            selection = isSelected ? nil : icon
        } label: {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(icon)
    }
}
