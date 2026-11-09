//
//  AgentWorkspaceColumnLayoutTests.swift
//  StarcatTests
//
//  测量原生分栏中的实际视图坐标，防止时间线撑宽后把标题和输入区推到窗口外。
//  使用内存视图及不显示的测试窗口，不截屏、不操作用户正在使用的窗口。
//

import AppKit
import SwiftUI
import Testing
@testable import Starcat

/// 普通栏宽常量测试无法发现后代视图撑大整栏；这里验证真实时间线参与布局后的边界。
@Suite("Agent 工作台分栏坐标", .serialized)
@MainActor
struct AgentWorkspaceColumnLayoutTests {
    @Test("反复显隐不能扩大真实窗口，用户调整尺寸后仍保持边界",
          arguments: [false, true], [false, true])
    func panelTogglesPreserveWindowFrame(hasResult: Bool, initiallyCollapsed: Bool) async throws {
        let suite = "AgentWindowFrame.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let columnWidths = AgentWorkspaceColumnWidthPersistence(defaults: defaults)
        let chromeState = WorkspaceChromeState()
        chromeState.isLeftColumnCollapsed = initiallyCollapsed
        chromeState.isRightColumnCollapsed = initiallyCollapsed
        let reference = WorkspaceSceneWindowReference()
        let controller = NSHostingController(rootView: AgentColumnLayoutFixture(
            viewModel: makeViewModel(hasResult: hasResult),
            chromeState: chromeState,
            columnWidths: columnWidths
        ).modifier(AgentWorkspaceWindowSizing(reference: reference)))
        // 保留 HostingController 默认尺寸协商，不能固定 host.frame 或清空 sizingOptions，
        // 否则原生分栏扩大 NSWindow 的回归会被测试夹具遮住。窗口从不 orderFront。
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        defer {
            window.close()
            columnWidths.cancelPendingPersistence()
            defaults.removePersistentDomain(forName: suite)
        }
        for width in [1440.0, 1880.0, 1440.0] {
            window.setContentSize(NSSize(width: width, height: 820))
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(48))
            controller.view.layoutSubtreeIfNeeded()
            // 原生折叠策略也受窗口位置影响；默认测试位置可能完全落在屏幕外，
            // 从而抑制窗口增宽并造成假通过。只设置未显示夹具的确定坐标。
            window.setFrameOrigin(NSPoint(x: 100, y: 100))
            #expect(reference.window === window)
            let initialFrame = window.frame
            #expect(abs(initialFrame.width - width) < 1)
            let states = [
                (true, false), (false, false), (false, true), (false, false),
                (true, true), (false, true), (false, false),
                (false, true), (true, true), (true, false), (false, false)
            ]
            for (leftCollapsed, rightCollapsed) in states {
                let before = measuredFrames(in: controller.view)
                let leftChanged = chromeState.isLeftColumnCollapsed != leftCollapsed
                let rightChanged = chromeState.isRightColumnCollapsed != rightCollapsed
                let otherPanel = leftChanged ? "inspector" : "rail"
                let otherFrame = leftChanged != rightChanged ? before[otherPanel] : nil
                AgentWorkspaceColumnVisibility.leftBinding(for: chromeState).wrappedValue =
                    leftCollapsed ? .detailOnly : .all
                AgentWorkspaceColumnVisibility.rightBinding(for: chromeState).wrappedValue = !rightCollapsed
                for sample in 0..<13 {
                    if sample > 0 { try await Task.sleep(for: .milliseconds(16)) }
                    controller.view.layoutSubtreeIfNeeded()
                    #expect(window.frame == initialFrame,
                            "第 \(sample) 次采样窗口变化：\(initialFrame) → \(window.frame)")
                    let frames = measuredFrames(in: controller.view)
                    if let otherFrame {
                        let actual = try #require(frames[otherPanel])
                        #expect(abs(actual.minX - otherFrame.minX) < 1)
                        #expect(abs(actual.width - otherFrame.width) < 1)
                    }
                    for name in ["column", "header", "timeline", "composer", "rail", "inspector"] {
                        if let frame = frames[name] {
                            #expect(frame.minX >= -1 && frame.maxX <= width + 1,
                                    "\(name) 越出窗口：\(frame)")
                        }
                    }
                    if sample == 12 {
                        #expect((frames["rail"] == nil) == leftCollapsed)
                        #expect((frames["inspector"] == nil) == rightCollapsed)
                        #expect(window.contentMinSize == AgentWorkspaceWindowMetrics.minimumContentSize)
                    }
                }
            }
        }
    }

    @Test("检查器展开或收起时，标题、时间线和输入区均留在中栏",
          arguments: [1200.0, 1440.0, 1880.0], [false, true])
    func runSurfaceStaysInsideAllocatedColumn(width: Double, inspectorPresented: Bool) throws {
        for hasResult in [false, true] {
            let suite = "AgentColumnLayoutTests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let columnWidths = AgentWorkspaceColumnWidthPersistence(defaults: defaults)
            defer {
                columnWidths.cancelPendingPersistence()
                defaults.removePersistentDomain(forName: suite)
            }
            let chromeState = WorkspaceChromeState()
            chromeState.isRightColumnPresented = inspectorPresented
            let viewModel = makeViewModel(hasResult: hasResult)
            let host = NSHostingView(rootView: AgentColumnLayoutFixture(
                viewModel: viewModel,
                chromeState: chromeState,
                columnWidths: columnWidths
            ))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 820)
            host.layoutSubtreeIfNeeded()

            let frames = measuredFrames(in: host)
            let column = try #require(frames["column"])
            #expect(column.width >= AgentWorkspaceLayoutMetrics.runMinimumWidth)
            for name in ["header", "timeline", "composer"] {
                let frame = try #require(frames[name])
                #expect(abs(frame.minX - column.minX) < 1,
                        "\(name) 偏离中栏起点：\(frame)，分配区域：\(column)")
                #expect(abs(frame.width - column.width) < 1,
                        "\(name) 宽于分配区域：\(frame)，分配区域：\(column)")
                #expect(frame.minY >= column.minY - 1)
                #expect(frame.maxY <= column.maxY + 1)
            }
        }
    }

    @Test("同一工作台反复切换两侧面板，持续采样对侧位置与中栏边界",
          arguments: [1440.0, 1880.0], [false, true])
    func repeatedVisibilityChangesPreserveOtherColumn(width: Double, hasResult: Bool) async throws {
        // 同时覆盖默认宽度和用户拖到最大宽度的恢复值，不接触用户真实的偏好设置。
        for expandedWidths in [(312.0, 320.0), (380.0, 520.0)] {
            let suite = "AgentColumnTransitions.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(expandedWidths.0, forKey: AgentWorkspaceLayoutMetrics.leftWidthDefaultsKey)
            defaults.set(expandedWidths.1, forKey: AgentWorkspaceLayoutMetrics.rightWidthDefaultsKey)
            let columnWidths = AgentWorkspaceColumnWidthPersistence(defaults: defaults)
            defer {
                columnWidths.cancelPendingPersistence()
                defaults.removePersistentDomain(forName: suite)
            }
            let chromeState = WorkspaceChromeState()
            var animatedUpdates: [Bool] = []
            var animationDescriptions: [String] = []
            let host = NSHostingView(rootView: AgentColumnLayoutFixture(
                viewModel: makeViewModel(hasResult: hasResult),
                chromeState: chromeState,
                columnWidths: columnWidths,
                onTransaction: {
                    animatedUpdates.append($0.animation != nil)
                    if $0.animation != nil {
                        animationDescriptions.append(
                            "left=\(chromeState.isLeftColumnCollapsed), right=\(chromeState.isRightColumnCollapsed), disabled=\($0.disablesAnimations)"
                        )
                    }
                }
            ))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: width, height: 820)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(32))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(32))

            // 覆盖单侧往返、另一侧隐藏时展开，以及连续交错切换；始终使用同一个 host。
            let states = [
                (true, false), (false, false), (false, true), (false, false),
                (true, false), (true, true), (false, true), (false, false),
                (false, true), (true, true), (true, false), (false, false)
            ]
            for (step, state) in states.enumerated() {
                let (leftCollapsed, rightCollapsed) = state
                host.layoutSubtreeIfNeeded()
                let before = measuredFrames(in: host)
                let leftChanged = chromeState.isLeftColumnCollapsed != leftCollapsed
                let otherPanel = leftChanged ? "inspector" : "rail"
                let otherWasVisible = leftChanged
                    ? !chromeState.isRightColumnCollapsed : !chromeState.isLeftColumnCollapsed
                animatedUpdates.removeAll()
                animationDescriptions.removeAll()
                // 模拟系统按钮或调用方带入动画事务；生产外壳应只在显隐更新中屏蔽它。
                withAnimation(.easeInOut(duration: 0.16)) {
                    if leftChanged {
                        AgentWorkspaceColumnVisibility.leftBinding(for: chromeState).wrappedValue =
                            leftCollapsed ? .detailOnly : .all
                    } else if step.isMultiple(of: 2) {
                        AgentWorkspaceColumnVisibility.toggleRight(in: chromeState)
                    } else {
                        AgentWorkspaceColumnVisibility.rightBinding(for: chromeState).wrappedValue = !rightCollapsed
                    }
                }
                for sample in 0..<13 {
                    if sample > 0 {
                        try await Task.sleep(for: .milliseconds(16))
                    }
                    host.layoutSubtreeIfNeeded()
                    let frames = measuredFrames(in: host)
                    let column = try #require(frames["column"])
                    #expect(column.minX >= -1 && column.maxX <= width + 1)
                    for name in ["header", "timeline", "composer"] {
                        let frame = try #require(frames[name])
                        #expect(abs(frame.minX - column.minX) < 1,
                                "第 \(sample) 帧 \(name) 偏离中栏")
                        #expect(abs(frame.width - column.width) < 1,
                                "第 \(sample) 帧 \(name) 撑宽中栏")
                        #expect(frame.minY >= column.minY - 1 && frame.maxY <= column.maxY + 1)
                    }
                    for name in ["rail", "inspector"] {
                        if let frame = frames[name] {
                            #expect(frame.minX >= -1 && frame.maxX <= width + 1,
                                    "第 \(sample) 帧 \(name) 越出窗口：\(frame)")
                        }
                    }
                    if otherWasVisible {
                        let expected = try #require(before[otherPanel])
                        let actual = try #require(frames[otherPanel])
                        #expect(abs(actual.minX - expected.minX) < 1,
                                "第 \(sample) 帧对侧 \(otherPanel) 被带动：\(expected) → \(actual)")
                        #expect(abs(actual.width - expected.width) < 1)
                    }
                    if sample == 12 {
                        // 必须真的完成了显隐，不能让“状态变了但原生分栏没更新”假通过。
                        #expect((frames["rail"] == nil) == leftCollapsed)
                        #expect((frames["inspector"] == nil) == rightCollapsed)
                    }
                }
                #expect(!animatedUpdates.isEmpty, "必须实际观测到显隐更新事务")
                #expect(!animatedUpdates.contains(true),
                        "切换 \(step) 到 \(state) 时不能注入布局动画：\(animationDescriptions)")
            }
        }
    }

    @Test("实际调整原生分隔条后，左右面板再次展开仍保留拖动宽度")
    func resizedColumnsKeepWidthsAfterToggling() async throws {
        let suite = "AgentColumnResize.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let columnWidths = AgentWorkspaceColumnWidthPersistence(defaults: defaults)
        defer {
            columnWidths.cancelPendingPersistence()
            defaults.removePersistentDomain(forName: suite)
        }
        let chromeState = WorkspaceChromeState()
        let host = NSHostingView(rootView: AgentColumnLayoutFixture(
            viewModel: makeViewModel(hasResult: true),
            chromeState: chromeState,
            columnWidths: columnWidths
        ))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 1880, height: 820)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(32))

        // 只调整本测试的内存视图树，不创建窗口或操作用户运行中的 App。
        let (leftSplit, leftIndex) = try splitView(containing: "rail", in: host)
        #expect(leftIndex == 0)
        leftSplit.setPosition(360, ofDividerAt: leftIndex)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(32))
        let (rightSplit, rightIndex) = try splitView(containing: "inspector", in: host)
        try #require(rightIndex > 0)
        // Inspector 的内容坐标已包含分隔条占位，不能再减一次 dividerThickness。
        rightSplit.setPosition(rightSplit.bounds.width - 480,
                               ofDividerAt: rightIndex - 1)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(32))
        let resized = measuredFrames(in: host)
        #expect(abs(try #require(resized["rail"]).width - 360) < 1)
        let resizedInspector = try #require(resized["inspector"])
        #expect(abs(resizedInspector.width - 480) < 1, "调整后的检查器：\(resizedInspector)")

        for _ in 0..<2 {
            for leftCollapsed in [true, false] {
                AgentWorkspaceColumnVisibility.leftBinding(for: chromeState).wrappedValue =
                    leftCollapsed ? .detailOnly : .all
                try await Task.sleep(for: .milliseconds(32))
                host.layoutSubtreeIfNeeded()
                let frames = measuredFrames(in: host)
                #expect(abs(try #require(frames["inspector"]).width - 480) < 1)
                if !leftCollapsed {
                    #expect(abs(try #require(frames["rail"]).width - 360) < 1)
                }
            }
            for rightPresented in [false, true] {
                AgentWorkspaceColumnVisibility.rightBinding(for: chromeState).wrappedValue = rightPresented
                try await Task.sleep(for: .milliseconds(32))
                host.layoutSubtreeIfNeeded()
                let frames = measuredFrames(in: host)
                #expect(abs(try #require(frames["rail"]).width - 360) < 1)
                if rightPresented {
                    #expect(abs(try #require(frames["inspector"]).width - 480) < 1)
                }
            }
        }
        columnWidths.persistLastMeasuredWidths()
        let reopened = AgentWorkspaceColumnWidthPersistence(defaults: defaults)
        #expect(abs(reopened.initialLeftColumnWidth - 360) < 1)
        #expect(abs(reopened.initialRightColumnWidth - 480) < 1)
    }

    @Test("面板切换后，普通内容更新仍能使用自身的动画")
    func contentUpdatesKeepTheirOwnAnimation() async throws {
        let suite = "AgentColumnAnimation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let columnWidths = AgentWorkspaceColumnWidthPersistence(defaults: defaults)
        defer {
            columnWidths.cancelPendingPersistence()
            defaults.removePersistentDomain(forName: suite)
        }
        let chromeState = WorkspaceChromeState()
        let contentState = AgentColumnContentState()
        var animatedUpdates: [Bool] = []
        let host = NSHostingView(rootView: AgentColumnLayoutFixture(
            viewModel: makeViewModel(hasResult: false),
            chromeState: chromeState,
            columnWidths: columnWidths,
            onTransaction: { animatedUpdates.append($0.animation != nil) },
            contentState: contentState
        ))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: 1440, height: 820)
        host.layoutSubtreeIfNeeded()
        AgentWorkspaceColumnVisibility.leftBinding(for: chromeState).wrappedValue = .detailOnly
        try await Task.sleep(for: .milliseconds(32))
        host.layoutSubtreeIfNeeded()

        animatedUpdates.removeAll()
        withAnimation(.easeInOut(duration: 0.16)) {
            contentState.revision += 1
        }
        try await Task.sleep(for: .milliseconds(32))
        host.layoutSubtreeIfNeeded()
        #expect(animatedUpdates.contains(true), "显隐事务不能永久禁用任务内容动画")
    }

    /// 同时覆盖截图里的空任务，以及包含宽表、代码和长文本的完成态。
    private func makeViewModel(hasResult: Bool) -> AgentWorkspaceViewModel {
        let model = AgentWorkspaceViewModel(agents: [BuiltInAgents.githubWeeklyReport])
        model.configureRuntimeSelection(
            backend: .deepSeekHarness,
            providerName: "DeepSeek",
            modelName: "deepseek-v4-flash",
            reasoningEffort: nil,
            isAvailable: true
        )
        if hasResult {
            model.status = .completed
            model.messages = [
                AgentMessage(
                    runID: UUID(), role: .user, turn: 0, sequence: 0,
                    parts: [.text("Generate this week's GitHub report")]
                )
            ]
            model.artifacts = [
                AgentArtifact(
                    type: .markdown, title: "Weekly report",
                    content: """
                    # GitHub Weekly Report

                    \(String(repeating: "A repository with a long description. ", count: 20))

                    | Project | Description | Notes |
                    | --- | --- | --- |
                    | \(String(repeating: "long-repository-name-", count: 12)) | Report | Verified |

                    ```text
                    \(String(repeating: "long-command-argument ", count: 30))
                    ```
                    """,
                    sequence: 1
                )
            ]
        }
        return model
    }

    /// 读取本测试创建的无窗口视图树；不访问屏幕、辅助功能树或运行中的 App。
    private func measuredFrames(in host: NSView) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        func visit(_ view: NSView) {
            if !view.isHiddenOrHasHiddenAncestor,
               let identifier = view.identifier?.rawValue,
               identifier.hasPrefix("agent-layout-") {
                result[String(identifier.dropFirst("agent-layout-".count))] =
                    host.convert(view.bounds, from: view)
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return result
    }

    /// 定位测试标记所属的原生分隔条，用真实布局组件验证拖动后的显隐恢复。
    private func splitView(containing name: String, in host: NSView) throws -> (NSSplitView, Int) {
        func marker(in view: NSView) -> NSView? {
            if view.identifier?.rawValue == "agent-layout-\(name)" { return view }
            return view.subviews.lazy.compactMap { marker(in: $0) }.first
        }
        let view = try #require(marker(in: host))
        var ancestor = view.superview
        var result: (NSSplitView, Int)?
        while let current = ancestor {
            if let split = current as? NSSplitView,
               let index = split.arrangedSubviews.firstIndex(where: { view.isDescendant(of: $0) }) {
                result = (split, index)
                break
            }
            ancestor = current.superview
        }
        return try #require(result, "测试标记必须位于真实的原生分栏内")
    }
}

/// 直接使用生产分栏外壳及真实时间线，避免测试副本遗漏动画或栏宽保存逻辑。
private struct AgentColumnLayoutFixture: View {
    let viewModel: AgentWorkspaceViewModel
    @Bindable var chromeState: WorkspaceChromeState
    let columnWidths: AgentWorkspaceColumnWidthPersistence
    var onTransaction: (Transaction) -> Void = { _ in }
    var contentState = AgentColumnContentState()

    private var revision: Int {
        (chromeState.isLeftColumnCollapsed ? 1 : 0)
            + (chromeState.isRightColumnCollapsed ? 2 : 0) + contentState.revision * 4
    }

    var body: some View {
        AgentWorkspaceColumns(chromeState: chromeState, columnWidths: columnWidths) {
            Text("Agent rail")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AgentColumnLayoutMarker(name: "rail"))
        } runSurface: {
            VStack(spacing: 0) {
                Text("GitHub Weekly Report")
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(AgentColumnLayoutMarker(
                        name: "header", revision: revision, onTransaction: onTransaction
                    ))
                AgentMessageTimelineView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AgentColumnLayoutMarker(name: "timeline"))
                Text("Composer")
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(AgentColumnLayoutMarker(name: "composer"))
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AgentColumnLayoutMarker(name: "column"))
        } inspector: {
            AgentRunInspectorView(viewModel: viewModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AgentColumnLayoutMarker(name: "inspector"))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 内容更新走自己的 Observation 源，避免替换 NSHostingView.rootView 时丢失测试事务。
@MainActor
@Observable
private final class AgentColumnContentState {
    var revision = 0
}

/// 透明背景标记随父视图布局，供测试读取坐标，不改变内容的尺寸建议。
private struct AgentColumnLayoutMarker: NSViewRepresentable {
    let name: String
    var revision: Int = 0
    var onTransaction: (Transaction) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("agent-layout-\(name)")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onTransaction(context.transaction)
    }
}
