//
//  MainWindowFrameModifier.swift
//  Starcat
//
//  登录后的主窗口尺寸、位置与最小尺寸管理。
//
//  SwiftUI 的 `.defaultSize(...)` 只在 WindowGroup 创建窗口时给初始建议尺寸；
//  Starcat 登录成功时是在同一个窗口内从登录页切到 HomeView，因此需要在
//  HomeView 真正进入窗口后，通过 NSWindow 接入 AppKit 的 frame autosave 机制。
//
//  另一个关键职责：**通过 `NSWindow.contentMinSize` 设置窗口硬下限**。
//  这是因为 SwiftUI 的 `.frame(minWidth:)` / `.navigationSplitViewColumnWidth(min:)`
//  只是子视图的布局提示，**不会反向约束 NSWindow 的最小拖动尺寸**——用户把窗口
//  拖小到子视图 min 累加值以下时，SwiftUI 会**裁切/压缩**视图（截图：sidebar 几乎
//  完全不可见、列表行被左侧裁掉），而不是阻止拖动。
//
//  正确做法：在 AppKit 层用 `contentMinSize` 设硬下限（这是 NSWindow 的"内容区
//  最小尺寸"属性，含义就是 SwiftUI contentView 不能小于这个值，到达后用户拖不动）。
//
//  当前数值（2026-06-02 v9）：启动默认强制回三栏展开态 1410×763；运行期窗口
//  硬下限固定为 1190×763。RepoDetail 不再额外设置 `.frame(minWidth: 770)` 后，
//  `NavigationSplitView` 能自然协商窄窗口布局；这里不再根据 sidebar 折叠/展开主动
//  `setFrame`，避免用户在 1190 最小尺寸下展开左栏时看到窗口宽度乱跳。
//

import AppKit
import SwiftUI

enum MainWindowFrameDefaults {
    static let autosaveName = "Starcat.MainWindow"

    /// HomeView 启动时的展开态默认尺寸：**1410×763**（2026-06-02 v4，dong4j 实测确认）。
    ///
    /// 1410 × 763 是 dong4j 在 LayoutDebugOverlay 下亲自测出来的"理想初始化尺寸"。
    /// 这个值现在只用于启动 / 恢复时的视觉默认，不再作为运行期三栏 minWidth 公式。
    ///
    /// 设计意图：
    /// - 每次进入 HomeView 时都避免从"sidebar 已折叠"的 autosave frame 启动；
    ///   低于 defaultSize 的保存记录会被丢弃并重新居中到 1410×763
    /// - 大于等于 defaultSize 的 autosave 记录仍恢复，保留用户主动拉大的窗口
    /// - 高度 763 是 dong4j 实测，刚好够 Sidebar 完整渲染（头像 + 统计 + 主导航 +
    ///   Tags + Languages 前 ~10 个语言项），低于这个高度 Languages 区域开始被截断
    ///
    /// 已知约束：屏幕分辨率 < 1410×763 的设备首次启动时仍会优先保证三栏展开态，
    /// 窗口可能略超出可视区域；运行期拖拽下限固定为 1190×763。
    static let defaultSize = CGSize(width: 1410, height: 763)

    /// 运行期窗口硬下限。
    ///
    /// 根因：`NavigationSplitView` 会在窄窗口内自行协商 sidebar 折叠 / 展开。
    /// 这里不要再跟随 `columnVisibility` 动态切换 1410 / 1190，也不要在展开时
    /// 主动 `setFrame`；否则和 SwiftUI 的列协商叠加后会出现窗口宽度跳动。
    /// 1190×763 是当前交互验证后保留下来的 AppKit 层硬下限，防止窗口回退到
    /// 旧 ContentView 800×600 下限导致中栏 / 右栏继续被裁切。
    static let contentMinSize = CGSize(width: 1190, height: 763)

    /// AppKit 保存窗口 frame 的 UserDefaults key 约定。
    ///
    /// 这里显式检查 key，是为了区分：
    /// - 首次登录：没有保存记录，主动给三栏主页一个 1410×763 的默认尺寸
    /// - 后续启动：已有保存记录，优先恢复用户上次拖拽后的尺寸与位置
    static var defaultsKey: String {
        "NSWindow Frame \(autosaveName)"
    }
}

private struct MainWindowFrameModifier: ViewModifier {
    let defaultSize: CGSize
    let contentMinSize: CGSize

    func body(content: Content) -> some View {
        content
            .background {
                MainWindowFrameReader(
                    defaultSize: defaultSize,
                    contentMinSize: contentMinSize
                )
                .frame(width: 0, height: 0)
            }
    }
}

/// 通过一个不可见 NSView 拿到承载当前 SwiftUI View 的 NSWindow。
///
/// 约束：不要把这个 reader 放到 Settings 或其他独立窗口里，否则会复用同一个
/// autosaveName，导致不同窗口互相覆盖 frame。当前只在 HomeView 根节点挂载。
private struct MainWindowFrameReader: NSViewRepresentable {
    let defaultSize: CGSize
    let contentMinSize: CGSize

    func makeCoordinator() -> Coordinator {
        Coordinator(
            defaultSize: defaultSize,
            contentMinSize: contentMinSize
        )
    }

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onMoveToWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.configure(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        context.coordinator.defaultSize = defaultSize
        context.coordinator.contentMinSize = contentMinSize
        context.coordinator.configure(window: nsView.window)
    }

    final class Coordinator {
        var defaultSize: CGSize
        var contentMinSize: CGSize
        private var didConfigure = false

        init(defaultSize: CGSize, contentMinSize: CGSize) {
            self.defaultSize = defaultSize
            self.contentMinSize = contentMinSize
        }

        func configure(window: NSWindow?) {
            guard let window else { return }

            // SwiftUI / NavigationSplitView 在列折叠、窗口重算时可能回写窗口约束；
            // updateNSView 进来时先重设一次 AppKit 下限，避免又退回 ContentView
            // 旧的 800×600 一类值。
            applyMinimumSize(to: window)

            guard !didConfigure else {
                enforceMinSize(window: window)
                return
            }
            didConfigure = true

            // 先设硬下限，再做 autosave 恢复。
            //
            // contentMinSize 是运行期唯一硬下限。它只负责阻止窗口被拖回旧的
            // ContentView 800×600 一类过小尺寸；sidebar 是否折叠、展开交给
            // NavigationSplitView 自己协商，避免这里二次 setFrame 造成视觉跳动。
            //
            // **特殊情况**：autosave 恢复出的尺寸如果**小于** contentMinSize（例如
            // 用户在更小窗口下限版本里拖小过窗口，新版本提高了下限），AppKit 不会
            // 自动放大恢复出的 frame——所以下面 setFrameUsingName 后还要兜底
            // 检查并放大。
            let hasSavedFrame = UserDefaults.standard.object(
                forKey: MainWindowFrameDefaults.defaultsKey
            ) != nil

            // setFrameAutosaveName 启用 AppKit 原生持久化：用户拖拽修改尺寸/位置后,
            // AppKit 会写入 UserDefaults,并在下次设置相同 autosaveName 时恢复。
            window.setFrameAutosaveName(MainWindowFrameDefaults.autosaveName)

            if hasSavedFrame, window.setFrameUsingName(MainWindowFrameDefaults.autosaveName) {
                // 启动期只信任"三栏展开态及以上"的 autosave。
                //
                // 允许运行期缩到 1190×763 后，AppKit 会把这个 frame 保存下来；
                // 如果下次启动继续恢复它，首页就可能直接进入窄布局。这里把
                // "启动视觉尺寸"和"运行期可拖拽下限"分开：启动至少 1410×763，
                // 运行时才允许缩到 1190×763。
                if restoredContentSize(in: window).isAtLeast(defaultSize) {
                    enforceMinSize(window: window)
                    return
                }

                // 保存记录太小，说明上次关闭时处于折叠态或旧版本异常小窗。
                // 不清 UserDefaults key，直接用本次 setFrame 覆盖；AppKit autosave
                // 已开启，后续会把 1410×763 写回同一个 autosaveName。
                applyInitialFrame(to: window)
                return
            }

            applyInitialFrame(to: window)
        }

        private func restoredContentSize(in window: NSWindow) -> CGSize {
            // 优先用 contentView.bounds，因为 defaultSize / contentMinSize 都是内容区尺寸。
            // 极早期 contentView 还没挂好时，退回 contentRect(forFrameRect:) 换算。
            if let contentSize = window.contentView?.bounds.size {
                return contentSize
            }

            return window.contentRect(forFrameRect: window.frame).size
        }

        private func applyInitialFrame(to window: NSWindow) {
            let visibleFrame = visibleFrame(for: window)
            let targetSize = defaultContentSize(visibleFrame: visibleFrame)

            let targetOrigin = CGPoint(
                x: visibleFrame.midX - targetSize.width / 2,
                y: visibleFrame.midY - targetSize.height / 2
            )

            window.setFrame(
                CGRect(origin: targetOrigin, size: targetSize),
                display: true,
                animate: false
            )
        }

        private func enforceMinSize(window: NSWindow) {
            let frame = window.frame
            let minWindowSize = windowFrameSize(forContentMinSize: contentMinSize, in: window)

            if frame.size.width < minWindowSize.width || frame.size.height < minWindowSize.height {
                let newSize = CGSize(
                    width: max(frame.size.width, minWindowSize.width),
                    height: max(frame.size.height, minWindowSize.height)
                )
                window.setFrame(
                    CGRect(origin: frame.origin, size: newSize),
                    display: true,
                    animate: false
                )
            }
        }

        private func applyMinimumSize(to window: NSWindow) {
            // `contentMinSize` 是推荐表达：下限以 SwiftUI contentView 为准。
            // 同时显式设置 `minSize` 是为了抵抗 SwiftUI / NavigationSplitView 在
            // sidebar 折叠过程中重算窗口约束时把 AppKit minSize 回写成较小值。
            // 两个属性保持同一个物理下限：content 1190×763；对应 window frame
            // 需要额外包含 titlebar / toolbar 的高度。
            window.contentMinSize = contentMinSize
            window.minSize = windowFrameSize(forContentMinSize: contentMinSize, in: window)
        }

        private func defaultContentSize(visibleFrame: CGRect) -> CGSize {
            // 默认 1410×763 是三栏展开态的理想尺寸；如果用户屏幕可视区域更小,
            // 需要裁到屏幕内,避免首次登录后窗口超出可见范围。
            //
            // 注意:裁到屏幕内之后还要确保不小于 contentMinSize——AppKit 不会自动
            // 处理这个冲突,如果屏幕太小（< contentMinSize）只能让窗口溢出屏幕,
            // 否则用户压根用不了 App。
            CGSize(
                width: max(
                    contentMinSize.width,
                    min(defaultSize.width, visibleFrame.width)
                ),
                height: max(
                    contentMinSize.height,
                    min(defaultSize.height, visibleFrame.height)
                )
            )
        }

        private func visibleFrame(for window: NSWindow) -> CGRect {
            window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame
                ?? window.frame
        }

        private func windowFrameSize(forContentMinSize contentMinSize: CGSize, in window: NSWindow) -> CGSize {
            // window.frame 是含 titleBar 的整窗口 frame；contentMinSize 描述的是
            // contentView 的最小尺寸，两者差一个 titleBar / toolbar 高度。这里用
            // frameRect(forContentRect:) 把 contentMinSize 换算成 window frame 单位。
            let minContentRect = CGRect(origin: .zero, size: contentMinSize)
            return window.frameRect(forContentRect: minContentRect).size
        }
    }
}

private extension CGSize {
    func isAtLeast(_ other: CGSize) -> Bool {
        width >= other.width && height >= other.height
    }
}

private final class WindowReaderView: NSView {
    var onMoveToWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(window)
    }
}

extension View {
    /// 为登录后的主窗口启用默认尺寸 + AppKit frame autosave + 硬最小尺寸约束。
    ///
    /// 使用方式：挂在 HomeView 根节点，确保登录页小窗口不会被强制放大、用户关闭
    /// /重开 App 后能恢复上次的窗口尺寸和位置、用户拖窗口不能拖到 contentMinSize 以下。
    ///
    /// - Parameters:
    ///   - defaultSize: 首次启动（无 autosave 记录时）的默认窗口尺寸。
    ///   - contentMinSize: NSWindow.contentMinSize 硬下限。当前固定为 1190×763，
    ///     sidebar 折叠 / 展开不再触发主动扩窗。
    func mainWindowFrameAutosave(
        defaultSize: CGSize = MainWindowFrameDefaults.defaultSize,
        contentMinSize: CGSize = MainWindowFrameDefaults.contentMinSize
    ) -> some View {
        modifier(MainWindowFrameModifier(
            defaultSize: defaultSize,
            contentMinSize: contentMinSize
        ))
    }
}
