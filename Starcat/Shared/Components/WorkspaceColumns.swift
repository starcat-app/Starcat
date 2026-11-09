//
//  WorkspaceColumns.swift
//  Starcat
//
//  Agent / RAG 共用的原生分栏外壳与显隐事务。
//

import AppKit
import SwiftUI

/// 侧栏宽度由原生分栏管理，保存结果不反向参与当前窗口的尺寸协商。
///
/// 内容视图只能使用原生分栏已分配的尺寸，不能将长文本的固有宽度带回外壳。
/// 显隐变化单独禁用布局动画，避免 Sidebar、Inspector 与中栏同时插值而相互裁切；
/// 该限制只作用于显隐变化的更新，时间线和任务内容仍可使用自己的动画。
struct WorkspaceColumns<Rail: View, RunSurface: View, Inspector: View>: View {
    let chromeState: WorkspaceChromeState
    let columnWidths: WorkspaceColumnWidthPersistence
    @ViewBuilder var rail: () -> Rail
    @ViewBuilder var runSurface: () -> RunSurface
    @ViewBuilder var inspector: () -> Inspector

    var body: some View {
        NavigationSplitView(columnVisibility: WorkspaceColumnVisibility.leftBinding(for: chromeState)) {
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
                    .background(WorkspaceSplitCollapsePolicy())
            }
        }
        .inspector(isPresented: WorkspaceColumnVisibility.rightBinding(for: chromeState)) {
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
    func makeNSView(context: Context) -> ProbeView { ProbeView() }

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

/// 在状态写入源头统一系统侧栏、Inspector 与工具栏按钮的显隐事务。
///
/// 原生分栏分别承载列内容，子树可能在外层 `.transaction(value:)` 执行前就响应
/// Observation 更新；因此不能依靠根视图事后清除动画。Binding 的事务必须在写入时
/// 生效，工具栏的直接写入也必须使用同一事务。任务内容自身的动画不受全局禁用影响。
@MainActor
enum WorkspaceColumnVisibility {
    private static var transaction: Transaction {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return transaction
    }

    /// 系统 Sidebar 按钮通过此 Binding 更新可见性，不继承调用方的布局动画。
    static func leftBinding(for chromeState: WorkspaceChromeState) -> Binding<NavigationSplitViewVisibility> {
        // 只给 Binding 附加 transaction 仍可能在首次更新时合入外层动画。
        // 显式包住 Observation 的写入，保证独立承载的列内容首先收到正确事务。
        Binding(
            get: { chromeState.leftColumnVisibility },
            set: { visibility in
                withTransaction(transaction) {
                    chromeState.leftColumnVisibility = visibility
                }
            }
        )
    }

    /// Inspector 自身发起的显隐变化也走相同事务，避免只覆盖工具栏入口。
    static func rightBinding(for chromeState: WorkspaceChromeState) -> Binding<Bool> {
        Binding(
            get: { chromeState.isRightColumnPresented },
            set: { isPresented in
                withTransaction(transaction) {
                    chromeState.isRightColumnPresented = isPresented
                }
            }
        )
    }

    /// 工作台工具栏直接修改共享状态时，必须在 Observation 发布更新前确定事务。
    static func toggleRight(in chromeState: WorkspaceChromeState) {
        withTransaction(transaction) {
            chromeState.isRightColumnCollapsed.toggle()
        }
    }
}
