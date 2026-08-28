//
//  GitHubStarListMenuLabel.swift
//  Starcat
//
//  GitHub Stars List 菜单项的统一标签，供单仓库右键菜单与批量分组菜单复用。
//

import AppKit
import SwiftUI

/// 用原色圆点、分组名和仓库数量构成统一的 GitHub List 菜单标签。
///
/// 勾选状态由外层 `Toggle` / `NSMenuItem.state` 表达；本组件只负责不会被系统 tint
/// 覆盖的分组颜色和稳定文本格式。
struct GitHubStarListMenuLabel: View {

    let list: GitHubStarList
    let repositoryCount: Int

    var body: some View {
        Label(
            title: { Text(verbatim: "\(list.name)  (\(repositoryCount))") },
            icon: { Image(nsImage: colorDotImage) }
        )
    }

    /// AppKit 菜单会 tint template image；显式关闭 template 才能保留分组原色。
    private var colorDotImage: NSImage {
        let nsColor = Self.nsColor(from: list.colorHex) ?? .controlAccentColor
        let size: CGFloat = 10
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// 将持久化的 `#RRGGBB` 转成 AppKit 菜单可使用的颜色。
    private static func nsColor(from hex: String) -> NSColor? {
        var normalized = hex.trimmingCharacters(in: .whitespaces)
        if normalized.hasPrefix("#") { normalized.removeFirst() }
        guard normalized.count == 6, let rgb = UInt32(normalized, radix: 16) else { return nil }
        return NSColor(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
