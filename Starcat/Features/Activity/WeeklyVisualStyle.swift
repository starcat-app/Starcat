//
//  WeeklyVisualStyle.swift
//  Starcat
//
//  Weekly 视图共享的轻量视觉常量。
//
//  设计约束:
//  - Weekly 已从 Activity 迁移到 Explore,不能再通过 `ActivityCategory.weekly`
//    取得颜色或图标语义;
//  - 这里仅保留跨列表、详情、toolbar tint 都需要复用的稳定 accent 色。
//

import SwiftUI

enum WeeklyVisualStyle {
    /// Rust beige: 与 Weekly 项目历史视觉保持一致,作为无语言仓库的兜底色。
    static let accentColor: Color = Color(hex: "#dea584") ?? .accentColor
}
