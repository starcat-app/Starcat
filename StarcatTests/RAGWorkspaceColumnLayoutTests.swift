//
//  RAGWorkspaceColumnLayoutTests.swift
//  StarcatTests
//
//  使用生产分栏外壳、RAG Markdown 和未显示的 NSWindow 验证面板切换过程。
//  不构造会读取用户数据库的 AppDependencies，不启动检索或操作用户窗口。
//

import AppKit
import SwiftUI
import Testing
@testable import Starcat

/// 窗口外框与列内容同时采样；固定 NSHostingView 宽度会掩盖原生分栏扩窗问题。
@Suite("RAG 工作台窗口与分栏", .serialized)
@MainActor
struct RAGWorkspaceColumnLayoutTests {
    @Test("两侧反复显隐保持窗口、对侧与正文边界",
          arguments: [false, true], [false, true])
    func togglesPreserveWindow(hasContent: Bool, maximumWidths: Bool) async throws {
        let suite = "RAGWindowLayout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        if maximumWidths {
            defaults.set(380, forKey: RAGWorkspaceLayoutMetrics.leftWidthDefaultsKey)
            defaults.set(520, forKey: RAGWorkspaceLayoutMetrics.rightWidthDefaultsKey)
        }
        let widths = WorkspaceColumnWidthPersistence(
            layout: RAGWorkspaceLayoutMetrics.columnLayout, defaults: defaults
        )
        defer {
            widths.cancelPendingPersistence()
            defaults.removePersistentDomain(forName: suite)
        }
        for initiallyCollapsed in [false, true] {
            let state = WorkspaceChromeState()
            state.isLeftColumnCollapsed = initiallyCollapsed
            state.isRightColumnCollapsed = initiallyCollapsed
            let reference = WorkspaceSceneWindowReference()
            var animatedUpdates: [Bool] = []
            let controller = NSHostingController(rootView: RAGColumnLayoutFixture(
                state: state, widths: widths, hasContent: hasContent,
                onTransaction: { animatedUpdates.append($0.animation != nil) }
            ).modifier(WorkspaceWindowSizing(
                reference: reference,
                minimumContentSize: KnowledgeRAGWorkspaceWindowMetrics.minimumContentSize
            )))
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            defer { window.close() }

            // 不固定 host.frame、不关闭默认尺寸协商；窗口保持未显示。
            // 屏幕外的默认坐标会抑制原生扩窗，必须显式设置夹具坐标。
            for width in [1440.0, 1880.0, 1440.0] {
                window.setContentSize(NSSize(width: width, height: 820))
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(48))
                controller.view.layoutSubtreeIfNeeded()
                window.setFrameOrigin(NSPoint(x: 100, y: 100))
                #expect(reference.window === window)
                let initialFrame = window.frame
                #expect(abs(initialFrame.width - width) < 1)
                let states = [
                    (true, false), (false, false), (false, true), (false, false),
                    (true, false), (true, true), (false, true), (false, false),
                    (false, true), (true, true), (true, false), (false, false)
                ]
                for (step, target) in states.enumerated() {
                    let before = frames(in: controller.view)
                    let leftChanged = state.isLeftColumnCollapsed != target.0
                    let rightChanged = state.isRightColumnCollapsed != target.1
                    let opposite = leftChanged ? "inspector" : "rail"
                    let oppositeBefore = leftChanged != rightChanged ? before[opposite] : nil
                    animatedUpdates.removeAll()
                    // 同时覆盖系统 Binding 与工具栏入口，即使调用者带动画也不能带动整窗。
                    withAnimation(.easeInOut(duration: 0.16)) {
                        WorkspaceColumnVisibility.leftBinding(for: state).wrappedValue =
                            target.0 ? .detailOnly : .all
                        if rightChanged && step.isMultiple(of: 2) {
                            WorkspaceColumnVisibility.toggleRight(in: state)
                        } else {
                            WorkspaceColumnVisibility.rightBinding(for: state).wrappedValue = !target.1
                        }
                    }
                    for sample in 0..<13 {
                        if sample > 0 { try await Task.sleep(for: .milliseconds(16)) }
                        controller.view.layoutSubtreeIfNeeded()
                        try #require(window.frame == initialFrame,
                                     "第 \(sample) 次采样整窗变化：\(initialFrame) → \(window.frame)")
                        let current = frames(in: controller.view)
                        let answer = try #require(current["answer"])
                        for name in ["header", "messages", "composer"] {
                            let frame = try #require(current[name])
                            #expect(abs(frame.minX - answer.minX) < 1)
                            #expect(abs(frame.width - answer.width) < 1)
                            #expect(frame.minY >= answer.minY - 1 && frame.maxY <= answer.maxY + 1)
                        }
                        for frame in current.values {
                            #expect(frame.minX >= -1 && frame.maxX <= width + 1)
                        }
                        if let oppositeBefore {
                            let frame = try #require(current[opposite])
                            #expect(abs(frame.minX - oppositeBefore.minX) < 1)
                            #expect(abs(frame.width - oppositeBefore.width) < 1)
                        }
                        if sample == 12 {
                            #expect((current["rail"] == nil) == target.0)
                            #expect((current["inspector"] == nil) == target.1)
                            #expect(window.contentMinSize == KnowledgeRAGWorkspaceWindowMetrics.minimumContentSize)
                        }
                    }
                    #expect(!animatedUpdates.isEmpty)
                    #expect(!animatedUpdates.contains(true), "面板显隐不应注入内容布局动画")
                }
            }
        }
    }

    @Test("拖动分隔条后切换面板并重开缓存仍恢复 RAG 宽度")
    func draggedWidthsSurviveToggles() async throws {
        let suite = "RAGColumnResize.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let widths = WorkspaceColumnWidthPersistence(
            layout: RAGWorkspaceLayoutMetrics.columnLayout, defaults: defaults
        )
        defer {
            widths.cancelPendingPersistence()
            defaults.removePersistentDomain(forName: suite)
        }
        let state = WorkspaceChromeState()
        let host = NSHostingView(rootView: RAGColumnLayoutFixture(
            state: state, widths: widths, hasContent: true
        ))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 1880, height: 820)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(32))
        let (left, leftIndex) = try splitView(containing: "rail", in: host)
        left.setPosition(360, ofDividerAt: leftIndex)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(32))
        let (right, rightIndex) = try splitView(containing: "inspector", in: host)
        try #require(rightIndex > 0)
        right.setPosition(right.bounds.width - 480, ofDividerAt: rightIndex - 1)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(32))

        for _ in 0..<3 {
            for collapsed in [true, false] {
                WorkspaceColumnVisibility.leftBinding(for: state).wrappedValue =
                    collapsed ? .detailOnly : .all
                try await Task.sleep(for: .milliseconds(32))
                host.layoutSubtreeIfNeeded()
                #expect(abs(try #require(frames(in: host)["inspector"]).width - 480) < 1)
            }
            for presented in [false, true] {
                WorkspaceColumnVisibility.rightBinding(for: state).wrappedValue = presented
                try await Task.sleep(for: .milliseconds(32))
                host.layoutSubtreeIfNeeded()
                #expect(abs(try #require(frames(in: host)["rail"]).width - 360) < 1)
                if presented {
                    #expect(abs(try #require(frames(in: host)["inspector"]).width - 480) < 1)
                }
            }
        }
        widths.persistLastMeasuredWidths()
        let reopened = WorkspaceColumnWidthPersistence(
            layout: RAGWorkspaceLayoutMetrics.columnLayout, defaults: defaults
        )
        #expect(abs(reopened.initialLeftColumnWidth - 360) < 1)
        #expect(abs(reopened.initialRightColumnWidth - 480) < 1)
        #expect(defaults.object(forKey: AgentWorkspaceLayoutMetrics.leftWidthDefaultsKey) == nil)
        #expect(defaults.object(forKey: AgentWorkspaceLayoutMetrics.rightWidthDefaultsKey) == nil)
    }

    /// 只读取夹具自己的原生视图坐标，不访问屏幕或辅助功能树。
    private func frames(in host: NSView) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        func visit(_ view: NSView) {
            if !view.isHiddenOrHasHiddenAncestor,
               let name = view.identifier?.rawValue, name.hasPrefix("rag-layout-") {
                result[String(name.dropFirst("rag-layout-".count))] =
                    host.convert(view.bounds, from: view)
            }
            view.subviews.forEach(visit)
        }
        visit(host)
        return result
    }

    /// 通过内容标记定位实际原生分栏，以真实分隔条调整测试宽度。
    private func splitView(containing name: String, in host: NSView) throws -> (NSSplitView, Int) {
        func marker(in view: NSView) -> NSView? {
            if view.identifier?.rawValue == "rag-layout-\(name)" { return view }
            return view.subviews.lazy.compactMap { marker(in: $0) }.first
        }
        let marker = try #require(marker(in: host))
        var ancestor = marker.superview
        while let view = ancestor {
            if let split = view as? NSSplitView,
               let index = split.arrangedSubviews.firstIndex(where: { marker.isDescendant(of: $0) }) {
                return (split, index)
            }
            ancestor = view.superview
        }
        throw RAGLayoutFixtureError.missingSplitView
    }
}

/// 使用真实 RAG Markdown 承载宽表、代码及引用长文本；不启动问答业务生命周期。
private struct RAGColumnLayoutFixture: View {
    let state: WorkspaceChromeState
    let widths: WorkspaceColumnWidthPersistence
    let hasContent: Bool
    var onTransaction: (Transaction) -> Void = { _ in }

    var body: some View {
        WorkspaceColumns(chromeState: state, columnWidths: widths) {
            Text("Conversation rail")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RAGLayoutMarker(name: "rail"))
        } runSurface: {
            VStack(spacing: 0) {
                Text("Knowledge RAG \(state.isLeftColumnCollapsed) \(state.isRightColumnCollapsed)")
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(RAGLayoutMarker(
                        name: "header",
                        revision: (state.isLeftColumnCollapsed ? 1 : 0)
                            + (state.isRightColumnCollapsed ? 2 : 0),
                        onTransaction: onTransaction
                    ))
                ScrollView {
                    if hasContent {
                        RAGMarkdownText(content: """
                        # Knowledge answer

                        \(String(repeating: "A repository description. ", count: 40))

                        | Repository | Evidence |
                        | --- | --- |
                        | \(String(repeating: "long-repository-", count: 15)) | [S1] |

                        ```text
                        \(String(repeating: "long-argument ", count: 60))
                        ```
                        """)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RAGLayoutMarker(name: "messages"))
                Text("Question composer")
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(RAGLayoutMarker(name: "composer"))
            }
            .background(RAGLayoutMarker(name: "answer"))
        } inspector: {
            ScrollView {
                RAGMarkdownText(content: hasContent
                    ? String(repeating: "Citation evidence and long/path/to/repository ", count: 40)
                    : "Citations")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RAGLayoutMarker(name: "inspector"))
        }
    }
}

/// 标记只随父视图布局，记录实际事务，不对父级提出额外尺寸要求。
private struct RAGLayoutMarker: NSViewRepresentable {
    let name: String
    var revision: Int = 0
    var onTransaction: (Transaction) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = .init("rag-layout-\(name)")
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onTransaction(context.transaction)
    }
}

/// 分隔条必须存在；缺失时不能静默跳过拖动恢复检查。
private enum RAGLayoutFixtureError: Error {
    case missingSplitView
}
