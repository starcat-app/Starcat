//
//  WorkspaceColumns.swift
//  Starcat
//
//  Agent / RAG 共用的原生分栏外壳与显隐事务。
//

import AppKit
import QuartzCore
import SwiftUI

/// 侧栏宽度由原生分栏管理，保存结果不反向参与当前窗口的尺寸协商。
///
/// 内容视图只能使用原生分栏已分配的尺寸，不能将长文本的固有宽度带回外壳。
/// 尺寸一次提交，呈现层执行淡入淡出；不让窗口、分栏与正文同时插值尺寸。
/// 无动画事务只作用于本次 SwiftUI 状态提交，时间线和任务内容仍可使用自己的动画。
struct WorkspaceColumns<Rail: View, RunSurface: View, Inspector: View>: View {
    @Environment(\.starcatReduceMotion) private var reduceMotion
    let chromeState: WorkspaceChromeState
    let columnWidths: WorkspaceColumnWidthPersistence
    @ViewBuilder var rail: () -> Rail
    @ViewBuilder var runSurface: () -> RunSurface
    @ViewBuilder var inspector: () -> Inspector

    var body: some View {
        NavigationSplitView(columnVisibility: WorkspaceColumnVisibility.leftBinding(
            for: chromeState, reduceMotion: reduceMotion
        )) {
            rail()
                .navigationSplitViewColumnWidth(
                    min: columnWidths.layout.left.minimum,
                    ideal: columnWidths.initialLeftColumnWidth,
                    max: columnWidths.layout.left.maximum
                )
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onChange(of: proxy.size.width, initial: true) { _, width in
                                columnWidths.scheduleLeftWidthPersistence(
                                    width, isCollapsed: chromeState.isLeftColumnCollapsed
                                )
                            }
                    }
                }
        } detail: {
            GeometryReader { proxy in
                runSurface()
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
                    .background(WorkspaceSplitCollapsePolicy(transition: chromeState.columnTransition))
            }
        }
        .inspector(isPresented: WorkspaceColumnVisibility.rightBinding(
            for: chromeState, reduceMotion: reduceMotion
        )) {
            GeometryReader { proxy in
                inspector()
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .clipped()
            }
            .inspectorColumnWidth(
                min: columnWidths.layout.right.minimum,
                ideal: columnWidths.rightColumnWidthForPresentation,
                max: columnWidths.layout.right.maximum
            )
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size.width, initial: true) { _, width in
                            columnWidths.scheduleRightWidthPersistence(
                                width, isCollapsed: chromeState.isRightColumnCollapsed
                            )
                        }
                }
            }
        }
        .onChange(of: chromeState.leftColumnVisibility) { _, _ in
            columnWidths.cancelPendingPersistence()
        }
        .onChange(of: chromeState.isRightColumnPresented) { _, _ in
            columnWidths.cancelPendingPersistence()
        }
        .onDisappear {
            columnWidths.persistLastMeasuredWidths()
            columnWidths.cancelPendingPersistence()
        }
    }
}

/// 在中栏接入两层原生分栏，显隐只按约束重新分配内容空间，不采用默认的窗口扩张策略。
///
/// SwiftUI 没有暴露 NSSplitViewItem.collapseBehavior。探针只沿自己的祖先链配置
/// Sidebar / Inspector，不替换系统 delegate、不接管窗口，也不扫描其他工作台。
private struct WorkspaceSplitCollapsePolicy: NSViewRepresentable {
    let transition: WorkspaceColumnTransition

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        transition.register(view)
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.configureAncestorSplitItems()
    }

    /// 原生分栏在挂载和显隐时可能重建；随本视图布局重设策略，覆盖新生成的 Inspector。
    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureAncestorSplitItems()
        }

        override func layout() {
            super.layout()
            configureAncestorSplitItems()
        }

        /// 保留现有最小尺寸与 holdingPriority，避免“禁止扩窗”同时破坏用户拖动栏宽。
        func configureAncestorSplitItems() {
            var ancestor = superview
            while let view = ancestor {
                if let splitView = view as? NSSplitView,
                   let controller = splitView.delegate as? NSSplitViewController {
                    for item in controller.splitViewItems
                    where item.behavior == .sidebar || item.behavior == .inspector {
                        // preferResizingSiblingsWithFixedSplitView 在碰到窗口下限时仍会
                        // 扩窗；useConstraints 才能在保留整窗下限时交由现有栏宽约束求解。
                        if item.collapseBehavior != .useConstraints {
                            item.collapseBehavior = .useConstraints
                        }
                    }
                }
                ancestor = view.superview
            }
        }
    }
}

/// SwiftUI 只提交最终可见性，原生合成层过渡画面，避免显隐时重复插值几何尺寸。
@MainActor
enum WorkspaceColumnVisibility {
    static let duration: TimeInterval = 0.2

    /// 子树不继承按钮调用方的布局动画，正常内容更新仍使用自己的事务。
    static func withoutContentAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }

    static func leftBinding(
        for chromeState: WorkspaceChromeState, reduceMotion: Bool = false
    ) -> Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { chromeState.leftColumnVisibility },
            set: { visibility in
                guard visibility != chromeState.leftColumnVisibility else { return }
                withoutContentAnimation {
                    chromeState.columnTransition.begin(reduceMotion: reduceMotion)
                    chromeState.leftColumnVisibility = visibility
                }
            }
        )
    }

    /// Inspector 与 Sidebar 使用同一过渡入口；状态不延迟写入，连续反向操作不会排队。
    static func rightBinding(
        for chromeState: WorkspaceChromeState, reduceMotion: Bool = false
    ) -> Binding<Bool> {
        Binding(
            get: { chromeState.isRightColumnPresented },
            set: { isPresented in
                guard isPresented != chromeState.isRightColumnPresented else { return }
                withoutContentAnimation {
                    chromeState.columnTransition.begin(reduceMotion: reduceMotion)
                    chromeState.isRightColumnPresented = isPresented
                }
            }
        )
    }

    static func toggleRight(in chromeState: WorkspaceChromeState, reduceMotion: Bool = false) {
        rightBinding(for: chromeState, reduceMotion: reduceMotion).wrappedValue =
            chromeState.isRightColumnCollapsed
    }
}

/// 通过本工作台最外层分栏的合成层淡入淡出，窗口与栏宽约束始终使用稳定的最终值。
/// 不能再次对 NSSplitViewItem 或 SwiftUI 尺寸做动画：两层分栏会独立插值并带动对侧。
/// 同一个动画 key 会替换尚未完成的过渡，快速点击无需积累任务或延迟可见性状态。
@MainActor
final class WorkspaceColumnTransition {
    static let animationKey = "StarcatWorkspaceColumnTransition"
    private weak var contentProbe: NSView?

    /// 保存稳定的内容探针；Inspector 会重建外层分栏，不能缓存它的合成层。
    func register(_ contentProbe: NSView) {
        self.contentProbe = contentProbe
    }

    /// 在提交可见性之前开始合成层过渡；减少动态效果时同时撤销在途过渡。
    func begin(reduceMotion: Bool) {
        // 每次操作沿当前祖先链重新定位，避免把过渡添加到已经脱离窗口的旧分栏。
        var ancestor = contentProbe?.superview
        var splitView: NSSplitView?
        while let view = ancestor {
            if let candidate = view as? NSSplitView,
               candidate.delegate is NSSplitViewController {
                splitView = candidate
            }
            ancestor = view.superview
        }
        splitView?.wantsLayer = true
        guard let layer = splitView?.layer else { return }
        layer.removeAnimation(forKey: Self.animationKey)
        guard !reduceMotion else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = WorkspaceColumnVisibility.duration
        transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(transition, forKey: Self.animationKey)
    }
}
