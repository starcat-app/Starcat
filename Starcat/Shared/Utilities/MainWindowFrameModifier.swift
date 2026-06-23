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
//  当前数值（2026-06-23 v11）：启动默认 content 为 1440×878，换算外框约
//  1440×900，方便直接产出 Mac App Store 2880×1800 截图；运行期硬下限
//  仍保留 1440×763。dong4j 实测 1190 最小宽度下重新展开 sidebar 时右上角
//  会短暂出现 `>>` toolbar overflow；手动拉到 1440 后该问题消失。因此这里
//  不再保留折叠态 1190 下限，也不做 sidebar 展开时的主动扩窗。
//

import AppKit
import SwiftUI

enum MainWindowFrameDefaults {
    static let autosaveName = "Starcat.MainWindow"

    /// HomeView 启动时的展开态默认 content 尺寸：**1440×878**。
    ///
    /// 早期 1410×763 是 dong4j 在 LayoutDebugOverlay 下测出来的初始化视觉尺寸；
    /// 后续实测发现 1190 最小宽度下展开 sidebar 会短暂出现 `>>` overflow，而
    /// 1440 宽度下问题消失。因此宽度默认和运行期硬下限统一到 1440，避免
    /// “启动宽度可用但拖到最小后展开不稳定”的双标准。
    ///
    /// 高度 878 是 2026-06-23 为截图流程新增的默认值：Starcat 主窗口标题栏 /
    /// toolbar 约占 22pt，content 1440×878 换算外层 window frame 后约为
    /// 1440×900pt；在 Retina @2x 下可直接裁出 Apple 接受的 2880×1800 PNG。
    ///
    /// 设计意图：
    /// - 每次进入 HomeView 时都避免从"sidebar 已折叠"的 autosave frame 启动；
    ///   低于 defaultSize 的保存记录会被丢弃并重新居中到 1440×878
    /// - 大于等于 defaultSize 的 autosave 记录仍恢复，保留用户主动拉大的窗口
    /// - 运行期最小高度仍是 763，这是 dong4j 实测能完整渲染 Sidebar 的下限；
    ///   默认高度提高只为更舒展的首屏和截图，不强迫用户一直保持 900pt 高窗口
    ///
    /// 已知约束：屏幕可视高度 < 默认外框高度时会裁到屏幕内，但仍不低于
    /// contentMinSize；运行期拖拽下限固定为 1440×763。
    static let defaultSize = CGSize(width: 1440, height: 878)

    /// 运行期窗口硬下限。
    ///
    /// 根因：1190×763 虽然能保住中栏 / 右栏不继续被裁切，但左栏从折叠态展开时
    /// 仍会让 toolbar 短暂进入 overflow，右上角出现 `>>`。1440 是 dong4j
    /// 手动验证过的稳定下限，所以直接作为 AppKit 层硬下限。
    static let contentMinSize = CGSize(width: 1440, height: 763)

    /// AppKit 保存窗口 frame 的 UserDefaults key 约定。
    ///
    /// 这里显式检查 key，是为了区分：
    /// - 首次登录：没有保存记录，主动给三栏主页一个 1440×878 的默认 content 尺寸
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
                // 旧版本允许运行期缩到 1190×763 后，AppKit 会把这个 frame 保存下来；
                // 如果下次启动继续恢复它，首页就可能直接进入窄布局。这里把
                // 启动视觉宽度统一到 1440，避免恢复旧窄窗口；高度则以 defaultSize
                // 过滤过矮的截图/首屏不理想窗口。
                if restoredContentSize(in: window).isAtLeast(defaultSize) {
                    enforceMinSize(window: window)
                    return
                }

                // 保存记录太小，说明上次关闭时处于折叠态或旧版本异常小窗。
                // 不清 UserDefaults key，直接用本次 setFrame 覆盖；AppKit autosave
                // 已开启，后续会把 1440×878 content 对应的 frame 写回同一个 autosaveName。
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
            let targetContentSize = defaultContentSize(visibleFrame: visibleFrame)
            let targetFrameSize = window.frameRect(
                forContentRect: CGRect(origin: .zero, size: targetContentSize)
            ).size

            let targetOrigin = CGPoint(
                x: visibleFrame.midX - targetFrameSize.width / 2,
                y: visibleFrame.midY - targetFrameSize.height / 2
            )

            window.setFrame(
                CGRect(origin: targetOrigin, size: targetFrameSize),
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
            // 两个属性保持同一个物理下限：content 1440×763；对应 window frame
            // 需要额外包含 titlebar / toolbar 的高度。
            window.contentMinSize = contentMinSize
            window.minSize = windowFrameSize(forContentMinSize: contentMinSize, in: window)
        }

        private func defaultContentSize(visibleFrame: CGRect) -> CGSize {
            // 默认 1440×878 是三栏展开态 + App Store 截图友好的理想尺寸；
            // 如果用户屏幕可视区域更小,
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
    ///   - contentMinSize: NSWindow.contentMinSize 硬下限。当前固定为 1440×763，
    ///     sidebar 折叠 / 展开不再触发主动扩窗；默认启动高度可高于该下限。
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
