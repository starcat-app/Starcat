//
//  ViewSnapshotPasteboard.swift
//  Starcat
//
//  把已经在屏幕上排好的 SwiftUI 卡片克隆到不可见 NSHostingView，再写入剪贴板。
//
//  为什么不用 ImageRenderer：
//  Star 趋势卡里有 Swift Charts。ImageRenderer 经常给出空白或轴错位，资料卡那种
//  纯 SwiftUI 布局才适合走 renderer。这里要的是「同一套卡片、去掉操作 chrome」，
//  所以用真实 AppKit 承载，让 Charts 走正常 display 路径。
//
//  关键约束（2026-08-29 崩溃后收紧）：
//  - 必须挂到一扇永不 orderFront 的窗口上，否则 backing scale / 图层合成不完整；
//  - **禁止** `CATransaction.flush()` 和 `RunLoop.run`。二者会重入主窗口的
//    display cycle，侧栏 `SidebarHeaderView` 的 `TimelineView(.animation)` 在
//    嵌套 `NSHostingView.layout()` 里会空指针（EXC_BAD_ACCESS / objc_msgSend）；
//  - 只对这扇屏外窗口做 `layoutSubtreeIfNeeded` + `displayIfNeeded`；
//  - 剪贴板同时写 PNG + TIFF，和通行证 / 资料卡出口对齐。
//

import AppKit
import SwiftUI

/// 屏外克隆 SwiftUI 视图并写入系统剪贴板。
enum ViewSnapshotPasteboard {
    /// 小于这个尺寸视为还没量到（骨架或未布局），拒绝出图以免写出一张空卡。
    static let minimumSize: CGFloat = 32

    /// 渲染失败返回 `nil`；调用方据此决定要不要亮「已复制」。
    @MainActor
    static func renderImage<Content: View>(
        _ content: Content,
        size: CGSize,
        colorScheme: ColorScheme? = nil
    ) -> NSImage? {
        guard size.width >= minimumSize, size.height >= minimumSize else {
            AppLog.ui.error("ViewSnapshotPasteboard: rejected undersized snapshot \(size.width, privacy: .public)x\(size.height, privacy: .public)")
            return nil
        }

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(origin: .zero, size: size)

        // 无边框、不显示、不进窗口循环。只为了拿到 backing scale，以及让 SwiftUI 走 AppKit 绘制。
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.animationBehavior = .none
        if let colorScheme {
            window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        }
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }

        hosting.layoutSubtreeIfNeeded()
        // 只画这扇屏外窗口。全局 flush / 转 runloop 会把主窗口 TimelineView 一并重入。
        window.displayIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            AppLog.ui.error("ViewSnapshotPasteboard: bitmapImageRepForCachingDisplay returned nil")
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)

        guard bitmap.pixelsWide > 1, bitmap.pixelsHigh > 1 else {
            AppLog.ui.error("ViewSnapshotPasteboard: captured bitmap is empty")
            return nil
        }

        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }

    /// 把已渲染的图写成 PNG + TIFF。`clearContents()` 避免旧文本残留让接收方误判类型。
    @MainActor
    @discardableResult
    static func writeImage(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            AppLog.ui.error("ViewSnapshotPasteboard: failed to encode snapshot as PNG")
            return false
        }

        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        item.setData(tiff, forType: .tiff)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let wrote = pasteboard.writeObjects([item])
        if wrote {
            AppLog.ui.info("ViewSnapshotPasteboard: copied PNG+TIFF snapshot")
        } else {
            AppLog.ui.error("ViewSnapshotPasteboard: NSPasteboard.writeObjects returned false")
        }
        return wrote
    }

    /// 渲染并写入剪贴板。任一步失败都返回 `false`，按钮不得切成功态。
    @MainActor
    @discardableResult
    static func copyImage<Content: View>(
        _ content: Content,
        size: CGSize,
        colorScheme: ColorScheme? = nil
    ) -> Bool {
        guard let image = renderImage(content, size: size, colorScheme: colorScheme) else {
            return false
        }
        return writeImage(image)
    }
}
