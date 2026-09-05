//
//  SettingsSidebarWidthLimiter.swift
//  Starcat
//
//  为设置窗口的原生 NavigationSplitView Sidebar 补充 AppKit 硬宽度约束。
//
//  设计约束：
//  - SwiftUI 的 navigationSplitViewColumnWidth 继续负责声明初始和理想宽度。
//  - AppKit 只设置当前 Sidebar 对应 NSSplitViewItem 的最小/最大厚度，
//    不持续回写 divider 位置，避免破坏用户在合法范围内的拖拽结果。
//  - 探针必须挂在目标 column 内部，不能从窗口根部猜测第一个 split item，
//    因为设置子页面未来仍可能包含自己的分栏视图。
//

import AppKit
import SwiftUI

/// 把 SwiftUI 分栏宽度建议同步为底层 `NSSplitViewItem` 的硬拖拽边界。
///
/// `NavigationSplitView` 保持 SwiftUI 所有权；这个桥接只补足 macOS 上原生 divider
/// 未稳定遵守 `navigationSplitViewColumnWidth(min:ideal:max:)` 的边界行为。
struct SettingsSidebarWidthLimiter: NSViewRepresentable {
    let minimumThickness: CGFloat
    let maximumThickness: CGFloat

    func makeNSView(context: Context) -> NSView {
        let probe = ProbeView(frame: .zero)
        updateProbe(probe)
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let probe = nsView as? ProbeView else { return }
        updateProbe(probe)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? ProbeView)?.onHierarchyChange = nil
    }

    /// SwiftUI 可能重建 Sidebar 的宿主层级；每次挂载和更新都幂等重设约束。
    private func updateProbe(_ probe: ProbeView) {
        probe.onHierarchyChange = { [minimumThickness, maximumThickness] view in
            Self.applyConstraints(
                minimumThickness: minimumThickness,
                maximumThickness: maximumThickness,
                toColumnContaining: view
            )
        }
        probe.onHierarchyChange?(probe)
    }

    /// 找到真正包含探针的 split item，而不是假定 Sidebar 永远是窗口中的第一个分栏。
    ///
    /// 返回值只用于单测确认探测是否成功；生产调用无需据此维护第二份状态。
    @discardableResult
    static func applyConstraints(
        minimumThickness: CGFloat,
        maximumThickness: CGFloat,
        toColumnContaining view: NSView
    ) -> Bool {
        guard let context = splitViewContext(containing: view) else {
            return false
        }

        if context.item.minimumThickness != minimumThickness {
            context.item.minimumThickness = minimumThickness
        }
        if context.item.maximumThickness != maximumThickness {
            context.item.maximumThickness = maximumThickness
        }
        clampCurrentThickness(
            of: context,
            minimumThickness: minimumThickness,
            maximumThickness: maximumThickness
        )
        return true
    }

    /// 先从真实窗口 controller 树定位，再用 ancestor / responder chain 兜底。
    /// SwiftUI 的 `NavigationSplitView` 可能把 `NSSplitViewController` 留在 controller
    /// 层级而不设为 split view delegate，不能只依赖 delegate 强转。
    private static func splitViewContext(
        containing view: NSView
    ) -> (controller: NSSplitViewController, item: NSSplitViewItem, itemIndex: Int)? {
        if let rootController = view.window?.contentViewController,
           let controller = descendantSplitViewController(
               in: rootController,
               containing: view
           ),
           let context = context(in: controller, containing: view) {
            return context
        }

        var ancestor = view.superview
        while let current = ancestor {
            if let splitView = current as? NSSplitView,
               let controller = splitView.delegate as? NSSplitViewController,
               let context = context(in: controller, containing: view) {
                return context
            }
            ancestor = current.superview
        }

        var responder = view.nextResponder
        while let current = responder {
            if let controller = current as? NSSplitViewController,
               let context = context(in: controller, containing: view) {
                return context
            }
            responder = current.nextResponder
        }
        return nil
    }

    /// 深度优先遍历 controller children，兼容 SwiftUI 在 hosting controller
    /// 与原生 split controller 之间增加私有包装层。
    private static func descendantSplitViewController(
        in rootController: NSViewController,
        containing view: NSView
    ) -> NSSplitViewController? {
        if let splitViewController = rootController as? NSSplitViewController,
           context(in: splitViewController, containing: view) != nil {
            return splitViewController
        }

        for childController in rootController.children {
            if let match = descendantSplitViewController(
                in: childController,
                containing: view
            ) {
                return match
            }
        }
        return nil
    }

    /// 返回包含探针的精确 item 和索引，避免设置页子视图增加分栏后误约束其他列。
    private static func context(
        in controller: NSSplitViewController,
        containing view: NSView
    ) -> (controller: NSSplitViewController, item: NSSplitViewItem, itemIndex: Int)? {
        guard let itemIndex = controller.splitViewItems.firstIndex(where: { item in
            let itemView = item.viewController.view
            return view === itemView || view.isDescendant(of: itemView)
        }) else {
            return nil
        }
        return (controller, controller.splitViewItems[itemIndex], itemIndex)
    }

    /// `maximumThickness` 会限制后续拖拽，但不会保证把已恢复的越界 divider
    /// 立即移回范围内；设置窗口 Sidebar 位于首栏，可直接用 divider 位置钳制。
    private static func clampCurrentThickness(
        of context: (controller: NSSplitViewController, item: NSSplitViewItem, itemIndex: Int),
        minimumThickness: CGFloat,
        maximumThickness: CGFloat
    ) {
        let splitView = context.controller.splitView
        guard splitView.isVertical,
              context.itemIndex == 0,
              context.controller.splitViewItems.count > 1 else {
            return
        }

        let currentThickness = context.item.viewController.view.frame.width
        guard currentThickness > 0 else { return }
        let clampedThickness = min(max(currentThickness, minimumThickness), maximumThickness)
        guard abs(currentThickness - clampedThickness) > 0.5 else { return }

        splitView.setPosition(clampedThickness, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
    }

    /// 零尺寸探针只监听宿主层级变化，不参与绘制、布局或事件处理。
    private final class ProbeView: NSView {
        var onHierarchyChange: ((NSView) -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            onHierarchyChange?(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onHierarchyChange?(self)
        }

        override func layout() {
            super.layout()
            // 首次挂窗时 split item 可能还是 0 宽；布局完成后再幂等补一次约束和钳制。
            onHierarchyChange?(self)
        }
    }
}
