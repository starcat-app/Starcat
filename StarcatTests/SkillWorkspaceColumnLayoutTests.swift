//
//  SkillWorkspaceColumnLayoutTests.swift
//  StarcatTests
//
//  验证真实 Skill 三栏参与 NSWindow 尺寸协商时能够收敛。
//  只创建不显示的测试窗口，不扫描用户目录、不操作运行中的应用。
//

import AppKit
import SwiftUI
import Testing
@testable import Starcat

/// 保留 HostingController 默认尺寸协商，避免固定 host 尺寸掩盖布局约束循环。
@Suite("Skill 工作台原生分栏", .serialized)
@MainActor
struct SkillWorkspaceColumnLayoutTests {
    @Test("首次打开原生窗口后尺寸收敛", arguments: [480.0, 720.0, 820.0, 1100.0])
    func initialWindowLayoutConverges(detailWidth: Double) async throws {
        try await verifyInitialLayout(detailWidth: detailWidth, inspectorPresented: true)
    }

    @Test("隐藏详情时原生窗口尺寸收敛")
    func hiddenInspectorLayoutConverges() async throws {
        try await verifyInitialLayout(detailWidth: 820, inspectorPresented: false)
    }

    @Test("列表有数据而未选择时尺寸收敛")
    func populatedWindowLayoutConverges() async throws {
        try await verifyInitialLayout(detailWidth: 820, inspectorPresented: true, populated: true)
    }

    @Test("详情显示正文时尺寸收敛")
    func selectedWindowLayoutConverges() async throws {
        try await verifyInitialLayout(detailWidth: 820, inspectorPresented: true, populated: true, selected: true)
    }

    @Test("最小窗口与宽窗口反复显隐仍保持边界", arguments: [false, true])
    func visibilityAndResizingPreserveFrame(selected: Bool) async throws {
        try await verifyInitialLayout(
            detailWidth: 1100, inspectorPresented: true, populated: selected, selected: selected,
            exerciseTransitions: true
        )
    }

    @Test("真实分隔条拖动后显隐和重新读取缓存仍保留阅读宽度")
    func draggedWidthSurvivesToggling() async throws {
        try await verifyInitialLayout(
            detailWidth: 820, inspectorPresented: true, populated: true, selected: true,
            exerciseDrag: true
        )
    }

    /// 对比 Inspector 可见性与恢复宽度，隔离尺寸反馈发生在哪条原生分栏路径。
    private func verifyInitialLayout(
        detailWidth: Double, inspectorPresented: Bool, populated: Bool = false, selected: Bool = false,
        exerciseTransitions: Bool = false, exerciseDrag: Bool = false
    ) async throws {
        let suite = "SkillWorkspace.Layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(detailWidth, forKey: SkillWorkspaceWindowMetrics.columnLayout.right.defaultsKey)
        let widths = WorkspaceColumnWidthPersistence(
            layout: SkillWorkspaceWindowMetrics.columnLayout, defaults: defaults
        )
        let model = SkillWorkspaceViewModel()
        if populated {
            let items = SkillWorkspacePreviewFixtures.items()
            model.applySnapshot(items)
            if selected { model.selectedIDs = [items[0].id] }
        }
        let chromeState = WorkspaceChromeState()
        chromeState.isRightColumnPresented = inspectorPresented
        let reference = WorkspaceSceneWindowReference()
        let controller = NSHostingController(rootView: SkillWorkspaceView(
            viewModel: model, chromeState: chromeState, columnWidths: widths
        )
        .defaultAppStorage(defaults)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .modifier(WorkspaceWindowSizing(
            reference: reference,
            minimumContentSize: SkillWorkspaceWindowMetrics.minimumContentSize
        )))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        defer {
            window.close()
            widths.cancelPendingPersistence()
            defaults.removePersistentDomain(forName: suite)
        }
        window.setContentSize(SkillWorkspaceWindowMetrics.defaultContentSize)
        window.setFrameOrigin(NSPoint(x: 100, y: 100))
        let expectedFrame = window.frame
        #expect(abs(expectedFrame.width - SkillWorkspaceWindowMetrics.defaultContentSize.width) < 1)

        // 必须推进真实约束及主线程事务；仅检查栏宽常量无法发现首次打开时的循环。
        try await expectStableFrame(expectedFrame, window: window, content: controller.view)
        #expect(reference.window === window)
        #expect(window.contentMinSize == SkillWorkspaceWindowMetrics.minimumContentSize)
        if inspectorPresented, detailWidth <= 820 {
            let split = try #require(contentSplit(in: controller.view))
            #expect(abs(split.arrangedSubviews[1].frame.width - detailWidth) < 1)
        }

        if exerciseTransitions {
            for size in [
                SkillWorkspaceWindowMetrics.minimumContentSize,
                CGSize(width: 1880, height: 900),
                SkillWorkspaceWindowMetrics.defaultContentSize
            ] {
                window.setContentSize(size)
                let resizedFrame = window.frame
                #expect(abs(resizedFrame.width - size.width) < 1)
                for (leftCollapsed, rightCollapsed) in [
                    (true, false), (false, false), (false, true),
                    (true, true), (false, true), (false, false)
                ] {
                    WorkspaceColumnVisibility.leftBinding(for: chromeState).wrappedValue =
                        leftCollapsed ? .detailOnly : .all
                    WorkspaceColumnVisibility.rightBinding(for: chromeState).wrappedValue = !rightCollapsed
                    try await expectStableFrame(resizedFrame, window: window, content: controller.view)
                    #expect((contentSplit(in: controller.view) != nil) == !rightCollapsed)
                    #expect(window.contentMinSize == SkillWorkspaceWindowMetrics.minimumContentSize)
                }
                model.setLoadState(.loading)
                try await expectStableFrame(resizedFrame, window: window, content: controller.view)
                model.setLoadState(.failed("Permission denied: /ExampleHome/.claude/skills"))
                try await expectStableFrame(resizedFrame, window: window, content: controller.view)
                model.setLoadState(.ready)
            }
        }

        if exerciseDrag {
            window.setContentSize(CGSize(width: 1880, height: 900))
            let resizedFrame = window.frame
            try await expectStableFrame(resizedFrame, window: window, content: controller.view)
            let split = try #require(contentSplit(in: controller.view))
            let before = split.arrangedSubviews[1].frame.width
            split.setPosition(split.bounds.width - 880 - split.dividerThickness, ofDividerAt: 0)
            try await expectStableFrame(resizedFrame, window: window, content: controller.view)
            let dragged = split.arrangedSubviews[1].frame.width
            #expect(abs(dragged - before) > 20, "必须真的调整了原生分隔条")
            for _ in 0..<2 {
                WorkspaceColumnVisibility.rightBinding(for: chromeState).wrappedValue = false
                try await expectStableFrame(resizedFrame, window: window, content: controller.view)
                WorkspaceColumnVisibility.rightBinding(for: chromeState).wrappedValue = true
                try await expectStableFrame(resizedFrame, window: window, content: controller.view)
                let reopened = try #require(contentSplit(in: controller.view))
                #expect(abs(reopened.arrangedSubviews[1].frame.width - dragged) < 1)
            }
            widths.persistLastMeasuredWidths()
            let reopened = WorkspaceColumnWidthPersistence(
                layout: SkillWorkspaceWindowMetrics.columnLayout, defaults: defaults
            )
            #expect(abs(reopened.initialRightColumnWidth - dragged) < 1)
        }
    }

    /// 持续采样覆盖共享 0.2 秒过渡，不能只在最终布局结束后检查一次。
    private func expectStableFrame(_ expected: CGRect, window: NSWindow, content: NSView) async throws {
        for _ in 0..<16 {
            window.updateConstraintsIfNeeded()
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
            #expect(window.frame == expected, "窗口边界变化：\(expected) → \(window.frame)")
        }
    }

    /// 只遍历自建视图，按公开 item 角色区分内容分栏与导航侧栏。
    /// 当前 SDK 的 HSplitView 也使用 NSSplitViewController，不能用 delegate 类型排除。
    private func contentSplit(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2 {
            let isNavigationSplit = (split.delegate as? NSSplitViewController)?
                .splitViewItems.contains { $0.behavior == .sidebar || $0.behavior == .inspector } ?? false
            if !isNavigationSplit { return split }
        }
        return view.subviews.lazy.compactMap { contentSplit(in: $0) }.first
    }
}
