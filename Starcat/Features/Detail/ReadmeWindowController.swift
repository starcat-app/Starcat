//
//  ReadmeWindowController.swift
//  Starcat
//
//  README 纯渲染独立窗。
//
//  ─────────────────────────────────────────────────────────
//  与 RepoDetailWindowController 的视觉差异
//  ─────────────────────────────────────────────────────────
//
//  ReadmeWindowController：
//  - 只有 README 正文 + 右下角浮动工具栏（字号调节 / 回到顶部）
//  - 无 hero 区、无仓库元信息卡片、无 AI 助手入口
//  - 窗口标题 = 仓库全名（owner/repo），仅此一行
//  - 每次点击都开全新窗口（不复用），方便对照阅读多份 README
//
//  RepoDetailWindowController：
//  - 完整仓库详情页：hero（头像 + 全名 + badges）+ 元信息卡片
//    + README + AI 助手入口 + 翻译 + 分享
//  - 窗口标题 = 仓库全名，含 traffic light + title bar
//  - 同 repo 点击复用窗口（singleton），不同 repo 可同时开
//
//  一句话：ReadmeWindow 是"只看 README"的阅读器；
//         RepoDetailWindow 是"围绕这个仓库做一切操作"的工作台。
//
//  ─────────────────────────────────────────────────────────
//  设计要点
//  ─────────────────────────────────────────────────────────
//
//  - 从 README 浮动工具栏「新窗口打开」按钮触发。
//  - 不注入 ReadmeViewModel：传入的 htmlFragment 已是渲染好的内容，
//    新窗口不需要再调网络。
//  - 共享 AppSettings（字号偏好在主窗调过的，独立窗同步生效）。
//  - 窗口关闭自然释放（ARC），不需要 singleton map 清理。
//

import AppKit
import SwiftUI

/// README 独立窗口的尺寸策略。
private enum ReadmeWindowMetrics {
    /// 800×700：与 RepoDetailWindow 一致的默认尺寸，适合长文阅读。
    static let defaultContentSize = NSSize(width: 800, height: 700)
    /// 最小 500×400：再小正文排版会拥挤。
    static let minContentSize = NSSize(width: 500, height: 400)
}

/// README 独立窗口控制器。
///
/// 每次调用 `show(...)` 都创建新窗口，不复用——用户可能同时打开多个
/// README 做对照阅读。
final class ReadmeWindowController: NSWindowController, NSWindowDelegate {

    /// 显示 README 独立窗口。
    ///
    /// - Parameters:
    ///   - htmlFragment: 已渲染的 README HTML 内容（含 GFM CSS）。
    ///   - baseURL: 用于解析 HTML 内相对链接的基地址。
    ///   - title: 窗口标题（通常为 `owner/repo`）。
    ///   - settings: 应用设置（字号偏好等），注入 SwiftUI environment。
    @MainActor
    static func show(
        htmlFragment: String,
        baseURL: URL?,
        title: String,
        settings: AppSettings
    ) {
        let controller = ReadmeWindowController(
            htmlFragment: htmlFragment,
            baseURL: baseURL,
            title: title,
            settings: settings
        )
        controller.showWindow(nil)
        positionWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 将新窗口居中于主窗口；找不到主窗口时退化为屏幕居中。
    @MainActor
    private static func positionWindow(_ window: NSWindow?) {
        guard let window else { return }

        // 尝试找到主窗口（通过 frameAutosaveName 匹配）
        if let mainWindow = NSApp.windows.first(where: { w in
            w !== window
                && w.isVisible
                && w.frameAutosaveName == MainWindowFrameDefaults.autosaveName
        }) {
            let mainCenter = NSPoint(
                x: mainWindow.frame.midX,
                y: mainWindow.frame.midY
            )
            let newOrigin = NSPoint(
                x: mainCenter.x - window.frame.width / 2,
                y: mainCenter.y - window.frame.height / 2
            )
            window.setFrameOrigin(newOrigin)
        } else {
            window.center()
        }
    }

    private init(
        htmlFragment: String,
        baseURL: URL?,
        title: String,
        settings: AppSettings
    ) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: ReadmeWindowMetrics.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // 不传 onScrollReportChange / onOpenInNewWindow：独立窗口内不需要
        // 详情页的滚动联动，也不需要再次"在新窗口打开"（避免无限套娃）。
        let content = ReadmeWebView(
            htmlFragment: htmlFragment,
            baseURL: baseURL
        )
        .environment(settings)

        let hostingController = NSHostingController(rootView: content)
        window.contentViewController = hostingController
        window.title = title
        window.setContentSize(ReadmeWindowMetrics.defaultContentSize)
        window.contentMinSize = ReadmeWindowMetrics.minContentSize
        window.minSize = ReadmeWindowMetrics.minContentSize
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReadmeWindowController does not support storyboard initialization")
    }

    /// 窗口关闭自动释放：无需 singleton 复用，每次都是新窗口。
    func windowWillClose(_ notification: Notification) {
        // NSWindow.isReleasedWhenClosed = false 意味着关闭后 controller 仍在内存；
        // 这里不做额外清理——SwiftUI 子树随 hosting controller 一起在 window 关闭后
        // 由 ARC 自然回收。
    }
}
