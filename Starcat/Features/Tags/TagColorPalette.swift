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

    /// 预设 12 色板（localization key, hex）。Apple HIG 系统色为底，覆盖典型分类需求。
    static let presets: [(name: String, hex: String)] = [
        ("tagColor.red",    "#FF453A"),
        ("tagColor.orange", "#FF9F0A"),
        ("tagColor.yellow", "#FFD60A"),
        ("tagColor.green",  "#30D158"),
        ("tagColor.mint",   "#66D4CF"),
        ("tagColor.teal",   "#40C8E0"),
        ("tagColor.cyan",   "#64D2FF"),
        ("tagColor.blue",   "#0A84FF"),
        ("tagColor.indigo", "#5E5CE6"),
        ("tagColor.purple", "#BF5AF2"),
        ("tagColor.pink",   "#FF375F"),
        ("tagColor.brown",  "#AC8E68"),
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

/// 自动为新建标签挑选「颜色 + 图标」的共享算法。
///
/// 单一信息源，两条创建路径必须共用：
/// 1. **批量 AI 整理**（`BatchAIQueueService.findOrCreateTag`）—— 一次性给多个 repo 落标签
/// 2. **单仓 AI 摘要确认应用**（`RepoAIInsightViewModel.findOrCreateTag`）—— 用户在详情页点
///    "应用此标签 / 应用全部" 时
///
/// 两边都要从「标签管理面板的同款候选集」里挑，避免 AI 自动建的标签视觉风格与用户手建的割裂。
///
/// ---
///
/// 设计要点（HOM-52 2026-06-06 dong4j 反馈累计）：
///
/// - **稳定哈希而不是真随机**：同一个 tag 名（"Swift"）无论何时建，落到的 (颜色, 图标) 必须
///   一致。否则用户今天看「Swift 是红色」、明天 AI 又给推荐了「Swift」，新建出来变绿色，
///   会让人怀疑是不是建重了。`Set.randomElement()` / `Int.random()` 在这点上不合格。
///
/// - **不能用 `String.hashValue`**：Swift 文档明确每次进程启动时 hash seed 会变，跨进程
///   不稳定。FNV-1a 32-bit 实现简单、运行时常量、对 12 色 + 30 图标这种小桶分布足够均匀。
///
/// - **颜色和图标取不同位段**：避免哈希低位变化时颜色和图标"同步翻转"导致组合多样性下降。
///
/// - **不持久化候选索引**：算法是纯函数，调用方拿 `(colorHex, iconName)` 直接写入 Tag 即可。
///   后续若调整候选集顺序，已存的标签颜色/图标不会被自动改写（数据已落库）；只影响新建。
enum TagAutoVisual {

    /// 为新标签名挑一个 (颜色 hex, SF Symbol 名)。算法稳定：同名输入永远返回同结果。
    ///
    /// - 颜色取自 `TagColorPalette.presets`（标签管理面板里的 12 色板）。
    /// - 图标取自 `SFSymbolPreset.icons`（标签编辑器里的 30 图标网格）。
    ///
    /// 入参 `name` 调用前应做完所有 normalize（trim + 多空格压缩），保证大小写 / 空白差异
    /// 不会让"看似相同"的标签拿到不同的视觉。本算法本身不做 normalize。
    static func pick(for name: String) -> (colorHex: String, iconName: String) {
        var hash: UInt32 = 2_166_136_261
        for byte in name.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let colorIdx = Int(hash % UInt32(TagColorPalette.presets.count))
        let iconIdx = Int((hash >> 8) % UInt32(SFSymbolPreset.icons.count))
        return (TagColorPalette.presets[colorIdx].hex, SFSymbolPreset.icons[iconIdx])
    }
}
