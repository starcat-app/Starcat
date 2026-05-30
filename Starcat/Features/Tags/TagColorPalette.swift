//
//  TagColorPalette.swift
//  Starcat
//
//  标签颜色相关辅助：预设色板 + Color ↔ hex 字符串互转。
//
//  存在意义：
//  - `Tag.color` 在 SQLite 里以 hex 字符串保存（如 "#FF453A"），跨平台 / 同步友好
//  - SwiftUI 用 Color；需要双向桥接
//  - 提供 12 色板让用户快速选，省去随便挑色的疲劳
//
//  设计约束：
//  - 色板取自 Apple 系统色（Apple HIG 推荐的语义色），暗色模式下可读
//  - hex 字符串严格 6 位（不含 alpha），不接受 #RRGGBBAA 形式
//

import SwiftUI

enum TagColorPalette {

    /// 预设 12 色板（label, hex）。Apple HIG 系统色为底，覆盖典型分类需求。
    static let presets: [(name: String, hex: String)] = [
        ("Red",    "#FF453A"),
        ("Orange", "#FF9F0A"),
        ("Yellow", "#FFD60A"),
        ("Green",  "#30D158"),
        ("Mint",   "#66D4CF"),
        ("Teal",   "#40C8E0"),
        ("Cyan",   "#64D2FF"),
        ("Blue",   "#0A84FF"),
        ("Indigo", "#5E5CE6"),
        ("Purple", "#BF5AF2"),
        ("Pink",   "#FF375F"),
        ("Brown",  "#AC8E68"),
    ]

    /// 默认色（未设置 color 字段时）。
    static let defaultHex: String = "#0A84FF"
}

extension Color {

    /// 从 `#RRGGBB` 构造 Color；非法字符串返回 nil。
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let rgb = UInt32(s, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// 转 `#RRGGBB` hex 字符串。
    /// macOS 下走 NSColor 桥接拿 sRGB 分量；非 sRGB 色会就近转换。
    func toHex() -> String {
        #if canImport(AppKit)
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else {
            return TagColorPalette.defaultHex
        }
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
        #else
        return TagColorPalette.defaultHex
        #endif
    }
}
