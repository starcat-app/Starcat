//
//  SettingsSidebarWidthLimiterTests.swift
//  StarcatTests
//
//  验证设置页宽度探针只约束它所在的原生 split item。
//

import AppKit
import Testing
@testable import Starcat

/// 覆盖 SwiftUI 无法直接断言的 `NSSplitViewItem` 最小/最大厚度桥接。
@MainActor
@Suite("SettingsSidebarWidthLimiter")
struct SettingsSidebarWidthLimiterTests {
    /// 构造真实 AppKit 分栏层级，防止探针误改详情栏或只在简单 view tree 下生效。
    @Test("只约束包含探针的 Sidebar split item")
    func appliesHardLimitsToContainingSplitItem() {
        let sidebarViewController = NSViewController()
        sidebarViewController.view = NSView(frame: .zero)
        let detailViewController = NSViewController()
        detailViewController.view = NSView(frame: .zero)

        let sidebarItem = NSSplitViewItem(viewController: sidebarViewController)
        let detailItem = NSSplitViewItem(viewController: detailViewController)
        let splitViewController = NSSplitViewController()
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)

        // 访问根 view 后 AppKit 才会把两个 child controller 安装进 NSSplitView 层级。
        _ = splitViewController.view
        splitViewController.view.frame = NSRect(x: 0, y: 0, width: 720, height: 720)
        splitViewController.view.layoutSubtreeIfNeeded()
        splitViewController.splitView.setPosition(500, ofDividerAt: 0)
        splitViewController.view.layoutSubtreeIfNeeded()

        let probe = NSView(frame: .zero)
        sidebarViewController.view.addSubview(probe)

        let didApply = SettingsSidebarWidthLimiter.applyConstraints(
            minimumThickness: 220,
            maximumThickness: 260,
            toColumnContaining: probe
        )

        #expect(didApply)
        #expect(sidebarItem.minimumThickness == 220)
        #expect(sidebarItem.maximumThickness == 260)
        #expect(sidebarViewController.view.frame.width <= 260.5)
        #expect(detailItem.minimumThickness != 220)
        #expect(detailItem.maximumThickness != 260)
    }
}
