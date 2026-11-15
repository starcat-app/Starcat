//
//  RepoFileReadingLayout.swift
//  Starcat
//
//  放大只改变可见性，保留树、检视栏偏好与两个阅读器实例。
//

import Foundation

/// 狭窄窗口的检视栏覆盖正文，避免将正文挤成不可阅读的窄缝。
struct RepoFileReadingLayout: Equatable {
    var showsInspector = false
    var isExpanded = false

    func usesInspectorOverlay(availableWidth: CGFloat) -> Bool {
        availableWidth - (isExpanded ? 0 : 252) - 272 < 520
    }

    /// Escape 首先回到正常阅读，再收检视栏，最后才由调用者关闭窗口。
    mutating func handleEscape() -> Bool {
        if isExpanded { isExpanded = false; return true }
        if showsInspector { showsInspector = false; return true }
        return false
    }
}
