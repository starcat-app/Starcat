//
//  DailyRadarWindowChromeModifier.swift
//  Starcat
//
//  每日热点的窗口内局部覆盖桥。
//  系统 toolbar 位于 SwiftUI 内容树之外，直接切换其可见性会让交通灯和侧栏跳动；
//  因此保留整窗布局，只在中右栏上方挂载一个延伸到窗口顶部的 SwiftUI 宿主。
//

import AppKit
import SwiftUI

/// 探针由中右栏联合锚点布局；宿主使用同一窗口，不创建 child window，也不改窗口属性。
///
/// NSHostingView 是唯一的 AppKit 边界。窗口尺寸与侧栏宽度变化时，只更新局部宿主 frame，
/// 原 NavigationSplitView、toolbar 与系统按钮的布局始终由 SwiftUI / AppKit 保持。
/// 查学习索引关键词：NSViewRepresentable / NSHostingView / 坐标转换。
@MainActor
struct DailyRadarWindowOverlay<Overlay: View>: NSViewRepresentable {
    let isPresented: Bool
    let reduceMotion: Bool
    @ViewBuilder var content: () -> Overlay

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onGeometryChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.attach(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.update(
            from: nsView,
            rootView: DailyRadarWindowOverlayContent(
                isPresented: isPresented,
                reduceMotion: reduceMotion,
                environment: context.environment,
                content: content
            ),
            isPresented: isPresented
        )
        // SwiftUI 先更新 representable、后完成分栏布局；下一轮再读取实际坐标，
        // 避免侧栏拖动时使用上一帧的 origin。这里不回写 State，不触发布局循环。
        DispatchQueue.main.async { [weak coordinator = context.coordinator, weak nsView] in
            guard let nsView else { return }
            coordinator?.attach(from: nsView)
        }
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        nsView.onGeometryChange = nil
        coordinator.detach()
    }

    /// 只拥有局部 hosting view；随探针附加 / 拆除，不修改 NSWindow 或系统按钮。
    @MainActor
    final class Coordinator {
        private var hostingView: DailyRadarOverlayHostingView<DailyRadarWindowOverlayContent<Overlay>>?

        /// 跨宿主完整传递环境（含依赖、语言、字号和主题），但不重新创建已打开的工作区。
        func update(from probe: ProbeView, rootView: DailyRadarWindowOverlayContent<Overlay>, isPresented: Bool) {
            if let hostingView {
                hostingView.rootView = rootView
            } else {
                let view = DailyRadarOverlayHostingView(rootView: rootView)
                // frame 由锚点决定，不允许内容的 fitting size 反向撑大窗口。
                view.sizingOptions = []
                view.safeAreaRegions = []
                hostingView = view
            }
            hostingView?.interceptsEvents = isPresented
            hostingView?.setAccessibilityHidden(!isPresented)
            attach(from: probe)
        }

        /// 使用公开的 contentView 父层覆盖原 toolbar；左右沿锚点，顶部沿窗口，
        /// 因而既不覆盖侧栏交通灯，也不需要猜测标题栏在不同系统版本下的高度。
        func attach(from probe: ProbeView) {
            guard let hostingView else { return }
            guard let container = probe.window?.contentView?.superview else {
                hostingView.removeFromSuperview()
                return
            }
            if hostingView.superview !== container {
                container.addSubview(hostingView, positioned: .above, relativeTo: nil)
            }
            let columns = probe.convert(probe.bounds, to: container)
            let frame = CGRect(
                x: columns.minX,
                // AppKit 视图默认非 flipped，y 轴从窗口底部向上；这里从 theme frame
                // 底边画到顶边，才能同时覆盖原 toolbar 和下方两栏内容。
                y: container.bounds.minY,
                width: columns.width,
                height: container.bounds.height
            )
            if hostingView.frame != frame {
                hostingView.frame = frame
            }
        }

        /// 原内容始终在下层；拆除宿主即可恢复，不需要还原整窗 chrome 快照。
        func detach() {
            hostingView?.removeFromSuperview()
            hostingView = nil
        }
    }

    /// 零交互的几何探针；同步实际布局，避免 resize 时面板边界滞后。
    @MainActor
    final class ProbeView: NSView {
        var onGeometryChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onGeometryChange?()
        }

        override func layout() {
            super.layout()
            onGeometryChange?()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            onGeometryChange?()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            onGeometryChange?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

/// 保持宿主挂载，让 SwiftUI 同时处理进入 / 退出和快速反向切换，不用延迟任务销毁面板。
struct DailyRadarWindowOverlayContent<Overlay: View>: View {
    let isPresented: Bool
    let reduceMotion: Bool
    let environment: EnvironmentValues
    @ViewBuilder var content: () -> Overlay

    var body: some View {
        ZStack {
            if isPresented {
                content()
                    .environment(\.self, environment)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 10)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .disabled(!isPresented)
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isPresented)
    }
}

/// 关闭后透明宿主仍保留以完成退出动画，但不能拦截原 toolbar / 内容区的鼠标事件。
@MainActor
private final class DailyRadarOverlayHostingView<Content: View>: NSHostingView<Content> {
    var interceptsEvents = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        interceptsEvents ? super.hitTest(point) : nil
    }
}
