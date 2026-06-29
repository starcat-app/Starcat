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
//  当前数值（2026-06-23 v12）：启动默认 content 为 1440×878；运行期硬下限
//  1440×763。autosave 恢复只卡 contentMinSize，不再用 defaultSize 过滤——
//  否则用户拖到 1440×800 等合法尺寸后，每次重启都会被强行拉回 1440×878。
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
    /// - **仅首次启动**（无 autosave 记录）使用本常量居中到 1440×878
    /// - **有 autosave 记录**时无条件恢复用户上次尺寸与位置，只经
    ///   `contentMinSize` 兜底（旧版 1190 宽等异常记录会被抬到 1440×763）
    /// - 不要把 defaultSize 当作恢复门槛——2026-06-23 截图改动曾误把
    ///   `isAtLeast(defaultSize)` 加进恢复路径，导致合法小窗每次重启丢失
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
/// autosaveName，导致不同窗口互相覆盖 frame。当前挂在 `ContentView` 根节点。
@MainActor
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

    static func dismantleNSView(_ nsView: WindowReaderView, coordinator: Coordinator) {
        nsView.onMoveToWindow = nil
        coordinator.removePersistenceObservers()
    }

    @MainActor
    final class Coordinator {
        var defaultSize: CGSize
        var contentMinSize: CGSize
        private var didConfigure = false
        private var persistenceObservers: [NSObjectProtocol] = []

        func removePersistenceObservers() {
            persistenceObservers.forEach {
                NotificationCenter.default.removeObserver($0)
            }
            persistenceObservers.removeAll()
        }

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

            let hasSavedFrame = UserDefaults.standard.object(
                forKey: MainWindowFrameDefaults.defaultsKey
            ) != nil

            window.setFrameAutosaveName(MainWindowFrameDefaults.autosaveName)
            registerTerminateSave(for: window)

            if hasSavedFrame {
                // 有历史记录时**绝不**走 applyInitialFrame——即使首轮
                // setFrameUsingName 失败（SwiftUI 首帧 window 未就绪），也不能
                // 把用户上次尺寸覆盖成 1440×878 默认。
                restoreSavedFrame(to: window)
                scheduleDeferredRestores(to: window)
            } else {
                applyInitialFrame(to: window)
            }
        }

        /// 从 UserDefaults 恢复上次窗口 frame；成功返回 true。
        @discardableResult
        private func restoreSavedFrame(to window: NSWindow) -> Bool {
            guard UserDefaults.standard.object(
                forKey: MainWindowFrameDefaults.defaultsKey
            ) != nil else {
                return false
            }

            // force: true —— SwiftUI WindowGroup 首帧 window 可能已 visible，
            // 默认 setFrameUsingName 会拒绝写入；这是恢复失败的主因之一。
            let restored = window.setFrameUsingName(
                MainWindowFrameDefaults.autosaveName,
                force: true
            )
            if restored {
                enforceMinSize(window: window)
            }
            return restored
        }

        /// SwiftUI 首帧 layout 可能在 configure 之后再次改写 window frame；
        /// 延迟两轮恢复，抢在 NavigationSplitView 稳定布局之后写回 autosave。
        private func scheduleDeferredRestores(to window: NSWindow) {
            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                self.restoreSavedFrame(to: window)
            }

            Task { @MainActor [weak self, weak window] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, let window else { return }
                self.restoreSavedFrame(to: window)
            }
        }

        /// 退出 / 失活前显式 saveFrame，避免仅依赖 AppKit 隐式 autosave 在 SwiftUI 生命周期下漏写。
        private func registerTerminateSave(for window: NSWindow) {
            guard persistenceObservers.isEmpty else { return }

            persistenceObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification,
                    object: nil,
                    queue: .main
                ) { [weak window] _ in
                    Task { @MainActor in
                        window?.saveFrameIfNeeded()
                    }
                }
            )

            persistenceObservers.append(
                NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak window] _ in
                    Task { @MainActor in
                        window?.saveFrameIfNeeded()
                    }
                }
            )
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

@MainActor
private final class WindowReaderView: NSView {
    var onMoveToWindow: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?(window)
    }
}

@MainActor
private extension NSWindow {
    /// 仅主窗口写入 autosave，避免误伤 Settings / sheet host。
    func saveFrameIfNeeded() {
        guard frameAutosaveName == MainWindowFrameDefaults.autosaveName else { return }
        saveFrame(usingName: MainWindowFrameDefaults.autosaveName)
    }
}

extension View {
    /// 为登录后的主窗口启用默认尺寸 + AppKit frame autosave + 硬最小尺寸约束。
    ///
    /// 使用方式：挂在 `ContentView` 根节点，确保冷启动 splash 期间也能尽早接入
    /// autosave；用户关闭 / 重开 App 后能恢复上次的窗口尺寸和位置。
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
