//
//  AboutPanelController.swift
//  Starcat
//
//  关于窗口入口适配器。
//
//  早期版本使用 NSApplication 的标准 About Panel。现在关于页已经升级为
//  SwiftUI 自定义窗口，但菜单入口仍保留这个轻量 wrapper，避免 StarcatApp
//  关心具体窗口实现细节。
//

/// 关于窗口入口。
final class AboutPanelController {

    /// 显示自定义关于窗口。
    @MainActor
    static func show() {
        AboutWindowController.show()
    }
}
