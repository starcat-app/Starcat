//
//  LayoutDebugOverlay.swift
//  Starcat
//
//  调试用：在主窗口右上角浮动显示当前容器尺寸（W × H pt 胶囊）。
//
//  使用方式：
//
//      content
//          .overlay(alignment: .topTrailing) {
//              if DebugFlags.layoutOverlay {
//                  LayoutDebugOverlay()
//              }
//          }
//
//  设计要点：
//  - 优先通过一个不可见 `NSViewRepresentable` 读取 `NSWindow.contentView.bounds`；
//    这是窗口内容区真实尺寸，不会在 NavigationSplitView 折叠 sidebar 后误读成 toolbar
//    或局部容器尺寸（曾出现过 798×50 这类误导性数值）
//  - `.allowsHitTesting(false)` 让胶囊不拦截鼠标事件，不影响下方 UI 的点击 / hover
//  - 胶囊用 `.regularMaterial` 半透明背景，无论 Light/Dark 都可读
//
//  历史：2026-06-02 dong4j 调整三栏 min/ideal/max 宽度时引入，方便实时验证。
//

import AppKit
import SwiftUI

/// 浮动尺寸 overlay。
///
/// 用 `GeometryReader` 测量容器尺寸，在右上角显示一个 `regularMaterial` 胶囊
/// `width × height` 文本。不拦截鼠标事件、纯只读、纯调试。
///
/// 显隐由 `DebugFlags.layoutOverlay` 控制（详见 `DebugFlags.swift` 文档）。
struct LayoutDebugOverlay: View {
    @State private var windowContentSize: CGSize?

    var body: some View {
        GeometryReader { proxy in
            let size = windowContentSize ?? proxy.size

            Text("\(Int(size.width)) × \(Int(size.height))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.primary.opacity(0.12), lineWidth: 0.5)
                }
                .padding(12)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topTrailing
                )
        }
        .background {
            WindowContentSizeReader(size: $windowContentSize)
                .frame(width: 0, height: 0)
        }
        .allowsHitTesting(false)
    }
}

/// 读取当前 SwiftUI view 所在的 `NSWindow.contentView.bounds.size`。
///
/// 为什么不用纯 `GeometryReader`：
/// `NavigationSplitView` 折叠 sidebar 后，overlay 所在的 SwiftUI 提案尺寸可能变成
/// toolbar / navigation bar 局部尺寸；窗口调试需要的是 AppKit contentView 的真实尺寸。
private struct WindowContentSizeReader: NSViewRepresentable {
    @Binding var size: CGSize?

    func makeCoordinator() -> Coordinator {
        Coordinator(size: $size)
    }

    func makeNSView(context: Context) -> WindowContentSizeReaderView {
        let view = WindowContentSizeReaderView()
        view.onMoveToWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowContentSizeReaderView, context: Context) {
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowContentSizeReaderView, coordinator: Coordinator) {
        nsView.onMoveToWindow = nil
        coordinator.attach(to: nil)
    }

    @MainActor
    final class Coordinator {
        private var size: Binding<CGSize?>
        private weak var window: NSWindow?
        private var resizeObserver: NSObjectProtocol?

        init(size: Binding<CGSize?>) {
            self.size = size
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                updateSize(from: window)
                return
            }

            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            resizeObserver = nil
            self.window = window

            guard let window else {
                size.wrappedValue = nil
                return
            }

            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor [weak self, weak window] in
                    self?.updateSize(from: window)
                }
            }

            updateSize(from: window)
        }

        private func updateSize(from window: NSWindow?) {
            let newSize = window?.contentView?.bounds.size
            guard size.wrappedValue != newSize else { return }
            // updateNSView 期间直接写 @State 会触发 SwiftUI 的
            // "Modifying state during view update" 警告；投递到下一轮主队列即可。
            Task { @MainActor [size] in
                guard size.wrappedValue != newSize else { return }
                size.wrappedValue = newSize
            }
        }
    }
}

@MainActor
private final class WindowContentSizeReaderView: NSView {
    var onMoveToWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(window)
    }
}

#if DEBUG
#Preview("Layout Debug Overlay") {
    ZStack {
        Color.gray.opacity(0.15)
        Text("Hover-only debug pill →")
            .foregroundStyle(.secondary)
    }
    .overlay(alignment: .topTrailing) {
        LayoutDebugOverlay()
    }
    .frame(width: 1024, height: 600)
}
#endif
