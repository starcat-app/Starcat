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
//  当前数值（2026-06-02 v8）：启动默认强制回三栏展开态 1410×763；运行期窗口
//  硬下限跟 `NavigationSplitViewVisibility` 绑定：三栏 `.all` 时是 1410×763，
//  sidebar 已折叠 / 隐藏后才降到 1190×763（RepoList 420 + Detail 770）。
//  这样可以避免用户从初始化大小直接拖窄时，sidebar 还没真正离开布局就被裁切。
//  如果用户先收起 sidebar 再把窗口缩到 1190，之后重新展开 sidebar 时，需要主动
//  把窗口内容区扩回 1410，否则 `NavigationSplitView` 只会把 sidebar 塞回当前窄窗口，
//  形成左栏抽屉 / 裁切状态。
//

import AppKit
import SwiftUI

enum MainWindowFrameDefaults {
    static let autosaveName = "Starcat.MainWindow"

    /// HomeView 启动时的展开态默认尺寸：**1410×763**（2026-06-02 v4，dong4j 实测确认）。
    ///
    /// 1410 × 763 是 dong4j 在 LayoutDebugOverlay 下亲自测出来的"理想初始化尺寸"，
    /// 也是三栏全部展开时的最紧凑可用尺寸。
    ///
    /// 三栏宽度拆分：**Sidebar 220 + RepoList 420 + Detail 770 = 1410pt**
    ///
    /// 设计意图：
    /// - 每次进入 HomeView 时都避免从"sidebar 已折叠"的 autosave frame 启动；
    ///   低于 defaultSize 的保存记录会被丢弃并重新居中到 1410×763
    /// - 大于等于 defaultSize 的 autosave 记录仍恢复，保留用户主动拉大的窗口
    /// - 高度 763 是 dong4j 实测，刚好够 Sidebar 完整渲染（头像 + 统计 + 主导航 +
    ///   Tags + Languages 前 ~10 个语言项），低于这个高度 Languages 区域开始被截断
    ///
    /// 已知约束：屏幕分辨率 < 1410×763 的设备首次启动时仍会优先保证三栏展开态，
    /// 窗口可能略超出可视区域；用户主动收起 sidebar 后，硬下限才会降到 1190×763。
    static let defaultSize = CGSize(width: 1410, height: 763)

    /// Sidebar 被系统自动折叠后的窗口硬下限。
    ///
    /// 根因：`NavigationSplitView` 在窗口变窄时会把 sidebar 折叠到工具栏按钮里；
    /// 这时左栏的 220pt 不再参与可见布局，如果还只考虑"三栏展开态"会漏掉折叠态。
    /// 折叠态仍必须保住中栏和右栏：
    ///
    /// **RepoList 420 + Detail 770 = 1190pt**
    ///
    /// 这里用 1190×763 作为 sidebar 已折叠后的 `NSWindow.contentMinSize`，
    /// 但 `.all` 三栏可见时不能提前使用它，否则左栏会在直接拖窄时被裁切。
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
    let expandedLayoutRequestID: Int

    func body(content: Content) -> some View {
        content
            .background {
                MainWindowFrameReader(
                    defaultSize: defaultSize,
                    contentMinSize: contentMinSize,
                    expandedLayoutRequestID: expandedLayoutRequestID
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
    let expandedLayoutRequestID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(
            defaultSize: defaultSize,
            contentMinSize: contentMinSize,
            expandedLayoutRequestID: expandedLayoutRequestID
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
        context.coordinator.expandedLayoutRequestID = expandedLayoutRequestID
        context.coordinator.configure(window: nsView.window)
    }

    final class Coordinator {
        var defaultSize: CGSize
        var contentMinSize: CGSize
        var expandedLayoutRequestID: Int
        private var didConfigure = false
        private var lastHandledExpandedLayoutRequestID: Int

        init(defaultSize: CGSize, contentMinSize: CGSize, expandedLayoutRequestID: Int) {
            self.defaultSize = defaultSize
            self.contentMinSize = contentMinSize
            self.expandedLayoutRequestID = expandedLayoutRequestID
            self.lastHandledExpandedLayoutRequestID = expandedLayoutRequestID
        }

        func configure(window: NSWindow?) {
            guard let window else { return }

            // SwiftUI / NavigationSplitView 在列折叠、窗口重算时可能回写窗口约束；
            // updateNSView 进来时先重设一次 AppKit 下限，避免又退回 ContentView
            // 旧的 800×600 一类值。
            applyMinimumSize(to: window)

            guard !didConfigure else {
                applyExpandedLayoutRequestIfNeeded(to: window)
                enforceMinSize(window: window)
                return
            }
            didConfigure = true

            // 先设硬下限，再做 autosave 恢复。
            //
            // contentMinSize 不能小于"当前可见列"的 min 累加值，否则用户能拖到比
            // SwiftUI 设计下限更小，视图会被裁切。展开态是 220+420+770=1410；
            // sidebar 折叠后可见列才变成 420+770=1190。HomeView 会按
            // columnVisibility 动态传入这两个值。
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
                // v5 允许运行期缩到 sidebar 折叠态 1190×763 后，AppKit 会把这个
                // 折叠 frame 保存下来；如果下次启动继续恢复它，首页就直接变成
                // sidebar 半折叠 / 内容被挤压的状态。这里把"启动默认"和"运行期
                // 可拖拽下限"分开：启动至少 1410×763，运行时才允许缩到 1190×763。
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

        private func applyExpandedLayoutRequestIfNeeded(to window: NSWindow) {
            guard expandedLayoutRequestID != lastHandledExpandedLayoutRequestID else { return }
            lastHandledExpandedLayoutRequestID = expandedLayoutRequestID

            // 请求只来自 HomeView 观察到 `NavigationSplitViewVisibility` 重新变成 `.all`。
            // HomeView 已经把当前硬下限切回 1410；这里额外负责把已缩到 1190 的
            // 折叠态窗口真正扩回去，而不是只改 minSize 后留下抽屉 / 裁切状态。
            growToExpandedLayoutIfNeeded(window: window)
        }

        private func growToExpandedLayoutIfNeeded(window: NSWindow) {
            let currentContentSize = restoredContentSize(in: window)
            guard currentContentSize.width < defaultSize.width || currentContentSize.height < defaultSize.height else {
                return
            }

            let visibleFrame = visibleFrame(for: window)
            let targetContentSize = defaultContentSize(visibleFrame: visibleFrame)
            let targetWindowSize = windowFrameSize(forContentMinSize: targetContentSize, in: window)
            let targetFrame = clampedFrame(
                keepingTopLeftOf: window.frame,
                targetSize: targetWindowSize,
                visibleFrame: visibleFrame
            )

            window.setFrame(targetFrame, display: true, animate: false)
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
            // 两个属性保持同一个物理下限：content 1410×763 或 1190×763，
            // 对应 window frame 需要额外包含 titlebar / toolbar 的高度。
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

        private func clampedFrame(
            keepingTopLeftOf currentFrame: CGRect,
            targetSize: CGSize,
            visibleFrame: CGRect
        ) -> CGRect {
            var frame = CGRect(
                x: currentFrame.minX,
                y: currentFrame.maxY - targetSize.height,
                width: targetSize.width,
                height: targetSize.height
            )

            // 展开 sidebar 时优先保持窗口左上角稳定：用户刚看到左栏从左侧展开，
            // 右侧内容自然向右获得空间。若靠近屏幕边缘，则只在能完整容纳时做边界回收。
            if frame.width <= visibleFrame.width {
                if frame.maxX > visibleFrame.maxX {
                    frame.origin.x = visibleFrame.maxX - frame.width
                }
                if frame.minX < visibleFrame.minX {
                    frame.origin.x = visibleFrame.minX
                }
            }

            if frame.height <= visibleFrame.height {
                if frame.maxY > visibleFrame.maxY {
                    frame.origin.y = visibleFrame.maxY - frame.height
                }
                if frame.minY < visibleFrame.minY {
                    frame.origin.y = visibleFrame.minY
                }
            }

            return frame
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
    ///   - contentMinSize: NSWindow.contentMinSize 硬下限。**必须**不小于三栏 SwiftUI
    ///     视图 min 累加值；HomeView 会根据 columnVisibility 在 1410 与 1190 之间切换。
    ///   - expandedLayoutRequestID: 每次 sidebar 从折叠态重新展开时递增一次，用于
    ///     触发窗口内容区扩回 defaultSize；不要拿它当长期 minSize 开关。
    func mainWindowFrameAutosave(
        defaultSize: CGSize = MainWindowFrameDefaults.defaultSize,
        contentMinSize: CGSize = MainWindowFrameDefaults.contentMinSize,
        expandedLayoutRequestID: Int = 0
    ) -> some View {
        modifier(MainWindowFrameModifier(
            defaultSize: defaultSize,
            contentMinSize: contentMinSize,
            expandedLayoutRequestID: expandedLayoutRequestID
        ))
    }
}
