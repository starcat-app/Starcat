//
//  StarcatSurface.swift
//  Starcat
//
//  深色表面色：避免系统 `controlBackgroundColor` / `textBackgroundColor` 在
//  Dark Aqua 下塌成近黑，叠在窗口底上变成黑洞。
//
//  色值对齐 DESIGN.md：`panel-dark` `#2C2C2E`、`separator-dark` `#3A3A3C`。
//  浅色仍走系统窗口底 / 控件底，不另做一套灰。
//

import AppKit
import SwiftUI

/// 浮层、设置 Sheet、输入框共用的表面色。
enum StarcatSurface {
    /// 浮层 / Sheet 内容底。深色走 panel-dark，不透玻璃、不近黑。
    static func panel(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.fromHex6(0x2C2C2E)
            : Color(nsColor: .windowBackgroundColor)
    }

    /// 设置式侧栏。深色略深于内容以保持分栏，仍比纯黑浅一档。
    static func sidebar(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.fromHex6(0x252528)
            : Color(nsColor: .controlBackgroundColor).opacity(0.34)
    }

    /// 输入框 / TextEditor。深色必须浅于面板，才读得像可输入区。
    static func composer(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.fromHex6(0x3A3A3C)
            : Color(nsColor: .controlBackgroundColor)
    }

    /// 长文本编辑区。浅色用文档底（白）；深色与 composer 同档，避免 `textBackgroundColor` 纯黑。
    static func editor(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? composer(colorScheme: colorScheme)
            : Color(nsColor: .textBackgroundColor)
    }

    /// 设置分组卡片。浅色保留半透明衬底；深色改实色，避免 `0.52 × 近黑` 还是黑洞。
    static func groupedCard(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? composer(colorScheme: colorScheme)
            : Color(nsColor: .controlBackgroundColor).opacity(0.52)
    }

    /// 检索卡 / 推理后端未选中卡。浅色略实一点；深色与 groupedCard 同档。
    static func raisedCard(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? composer(colorScheme: colorScheme)
            : Color(nsColor: .controlBackgroundColor).opacity(0.72)
    }

    static func composerStrokeOpacity(colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.18 : 0.12
    }
}
