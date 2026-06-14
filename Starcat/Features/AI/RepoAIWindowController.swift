//
//  RepoAIWindowController.swift
//  Starcat
//
//  详情页 AI 助手玻璃态浮动面板的 AppKit 外壳（HOM-150）。
//
//  设计要点：
//  - **按 repo.id 复用单例**：同一仓库再点 AI 按钮不会开第二个面板，而是把已有面板
//    带到前台，避免堆积一批"同 repo 不同对话"的浮动窗口，与 macOS 用户的浮窗心智
//    （Finder 单文件 quicklook、Preview 单文件预览）对齐。
//  - **不同 repo 各自独立窗口**：用户可以继续打开其他 repo 做对比；所有面板默认
//    常驻、保持浮动层级，只有主动点关闭按钮才销毁。
//  - **窗口关闭后释放控制器**：单例 map 在 `windowWillClose` 里清掉对应条目；
//    `isReleasedWhenClosed = false` 让 NSWindow 不在关闭时自动 dealloc，从而保留
//    NSHostingController 直到我们手动放手；下次再开会重建一个全新窗口与 VM。
//  - SwiftUI 内容通过 `.environment(_)` 注入 `AppDependencies` 与 `HomeViewModel`，
//    因为 AppKit 创建的 hosting controller 不会自动继承主窗的 environment 链。
//
//  参考：`AboutWindowController.swift` 同款单例模式。
//

import AppKit
import SwiftUI

/// `NSPanel` 默认不一定接受键盘焦点；AI 输入框必须能成为 first responder，
/// 因此只在这个最小 AppKit 边界覆写 key/main 能力。
private final class RepoAIPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 默认窗口尺寸与下限，集中在一处便于以后整体调优。
///
/// 调优历史：
/// - HOM-150 dong4j 2026-06-04 15:30："调整为更适合对话框的尺寸——宽度减少，
///   高度增加"→ 第一版 620 x 800。
/// - HOM-150 dong4j 2026-06-04 15:48："将 AI 窗口的默认宽度改成 540"→ 进一步收窄
///   到 540 x 800（约 2:3 比例），更贴近 ChatGPT 桌面端 / iPhone 对话界面比例。
private enum RepoAIWindowMetrics {
    /// 540 x 800：更瘦长（约 2:3 宽高比），单面板 + 输入框的 chat 形态最佳节奏。
    static let defaultContentSize = NSSize(width: 540, height: 800)
    /// 最小尺寸：低于 480 宽 / 600 高时输入条 + 气泡 + segmented toggle bar
    /// 会显得很拥挤。当前默认 540 - 60 = 还有约 1 档可继续收窄空间。
    static let minContentSize = NSSize(width: 480, height: 600)
}

/// 详情页 AI 助手窗口的控制器。
final class RepoAIWindowController: NSWindowController, NSWindowDelegate {

    /// repo.id → controller 单例 map。
    ///
    /// 用字典而不是单一 static var，是为了支持"多个 repo 同时各开一个窗口做对比"，
    /// 同时保留"同一 repo 重复点 AI 不重复开窗口"的体验。
    /// key 类型选 `Repo.ID`（当前为 Int64）而非 String，避免每次 lookup 都做一次
    /// 字符串化的隐式开销，也跟主窗 ViewModel 里其他按 id 索引的容器对齐。
    private static var instances: [Repo.ID: RepoAIWindowController] = [:]

    private let repoId: Repo.ID
    /// `contentView` 只会保留 hosting view；控制器需要显式强持有 hosting controller，
    /// 才能让 SwiftUI 生命周期与 AppKit 面板一致。
    private let hostedContentController: NSViewController

    /// 监听 `NSApplication.didBecomeActiveNotification` 的 block-based observer token。
    ///
    /// 2026-06-14 dong4j 反馈"AI 摘要窗口现在是置顶于所有窗口之上的, 我只需要置顶于
    /// starcat 主窗口之上"——把固定 `.floating` level 改成"按 App active 状态动态切"：
    ///   - Starcat 是前台 App 时 → `.floating`：浮在 Starcat 主窗之上，保留原体验；
    ///   - 切到其它 App（Chrome / Xcode 等）时 → `.normal`：其它 App 的窗口可以正常
    ///     遮住 AI 窗，不再强行浮在所有窗口之上。
    /// 用 block-based observer + `[weak self]` 比 selector-based 安全（self dealloc 时
    /// 不会触发悬挂调用），deinit 显式 `removeObserver(token)` 双保险。
    private var didBecomeActiveObserver: NSObjectProtocol?

    /// 监听 `NSApplication.didResignActiveNotification` 的 block-based observer token。
    /// 见 `didBecomeActiveObserver` 注释。
    private var didResignActiveObserver: NSObjectProtocol?

    /// 显示给定 repo 的 AI 助手窗口；已开则把窗口带到前台。
    ///
    /// - Parameters:
    ///   - repo: 当前详情页选中的 repo。窗口 title / 上下文都来自这个对象。
    ///   - dependencies: 应用级依赖，注入到 SwiftUI 子树的 `@Environment` 里供
    ///     `RepoAIInsightViewModel` / `RepoAIChatViewModel` 构造时读取。
    ///   - homeViewModel: 主窗的 HomeViewModel，应用标签后用于触发 Sidebar / 列表
    ///     刷新。属性以强引用形式传给 SwiftUI environment（`HomeViewModel` 是 class），
    ///     不会循环引用——主窗关闭时 HomeViewModel 自然释放，AI 窗口里的弱引用回调
    ///     会安全失效。
    @MainActor
    static func show(
        repo: Repo,
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel
    ) {
        if let existing = instances[repo.id] {
            existing.showWindow(nil)
            alignWindow(existing.window)
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = RepoAIWindowController(
            repo: repo,
            dependencies: dependencies,
            homeViewModel: homeViewModel
        )
        instances[repo.id] = controller
        controller.showWindow(nil)
        alignWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private static func alignWindow(_ window: NSWindow?) {
        guard let aiWindow = window,
              let mainWindow = NSApp.windows.first(where: { $0.frameAutosaveName == MainWindowFrameDefaults.autosaveName }) else {
            window?.center()
            return
        }
        
        let toolbarHeight = mainWindow.frame.height - mainWindow.contentLayoutRect.height
        let targetHeight = MainWindowFrameDefaults.defaultSize.height - toolbarHeight
        
        var newFrame = aiWindow.frame
        newFrame.size.height = targetHeight
        newFrame.origin.x = mainWindow.frame.maxX - newFrame.size.width
        newFrame.origin.y = mainWindow.frame.maxY - toolbarHeight - targetHeight
        
        aiWindow.setFrame(newFrame, display: true)
    }

    private init(
        repo: Repo,
        dependencies: AppDependencies,
        homeViewModel: HomeViewModel
    ) {
        self.repoId = repo.id

        let window = RepoAIPanel(
            contentRect: NSRect(origin: .zero, size: RepoAIWindowMetrics.defaultContentSize),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // `.environment` 必须在 hosting root 上挂——SwiftUI 子树才能正确读到
        // `@Environment(AppDependencies.self)` / `@Environment(HomeViewModel.self)`。
        // 这里同时挂上 settings，因为部分子视图（未来如果引入主题相关 modifier）
        // 会读 settings；与主窗 `StarcatApp` 给 ContentView 注入的链路对齐。
        let content = RepoAIWindowContentView(
            repo: repo,
            onClose: { [weak window] in
                window?.close()
            }
        )
            .environment(dependencies)
            .environment(dependencies.authSession)
            .environment(dependencies.settings)
            .environment(homeViewModel)

        let hostingController = NSHostingController(rootView: content)
        self.hostedContentController = hostingController

        // 玻璃效果放在 AppKit 根视图，SwiftUI 内容只负责透明叠加。这样窗口阴影、
        // 背景采样和圆角裁切都由同一个系统材质层完成，不需要手写 blur/scrim。
        //
        // 圆角实现（dong4j 2026-06-14 反馈：浅色主题下圆角外有白色"折角"露出）：
        // - 原 `layer.cornerRadius = 18 + masksToBounds = true` 对 NSVisualEffectView
        //   的 vibrant 子层裁切不完整，在浅色主题下圆角外的扇形死角会透出 NSWindow
        //   或 hosting layer 的默认白色背景。深色主题下底色为深，肉眼难察。
        // - 改用 `NSVisualEffectView.maskImage` 9-slice 圆角蒙版：这是 Apple 给
        //   visual effect view 的官方圆角入口，会一并裁切 vibrant 子层与背景采样区，
        //   是 Spotlight / Raycast 等浮窗的标准做法。
        // - `invalidateShadow()` 兜底：borderless + 圆角 contentView 时 NSWindow
        //   的阴影需要重算一次，否则首帧阴影按矩形 frame 绘制，圆角处阴影发硬。
        let glassView = NSVisualEffectView()
        glassView.material = .popover
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        glassView.maskImage = Self.roundedCornerMaskImage(radius: 18)

        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        glassView.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: glassView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
        ])
        window.contentView = glassView

        // 窗口标题走 String(localized:) + format：AppKit NSWindow.title 是 String，
        // 不像 SwiftUI Text 那样自动解析 LocalizedStringKey，必须显式跑一次本地化。
        window.title = String(
            format: String(localized: "ai.assistant.window.titleFormat"),
            repo.fullName
        )
        window.setContentSize(RepoAIWindowMetrics.defaultContentSize)
        window.contentMinSize = RepoAIWindowMetrics.minContentSize
        window.minSize = RepoAIWindowMetrics.minContentSize
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        // AI 助手是常驻工具面板：Starcat 是前台 App 时浮在主窗之上，切到其他 App 时
        // 降到 `.normal` 让其他 App 的窗口可以遮住它（dong4j 2026-06-14 反馈：之前固定
        // `.floating` 让 AI 窗在用户切到 Chrome / Xcode 看资料时仍挡在前面，不符合
        // "只置顶于 Starcat 主窗口之上"的预期）。下方 `installAppActivationObservers()`
        // 负责切换；初始值按当前 App active 状态设定。`hidesOnDeactivate = false` 让
        // 失活时窗口仍可见（只是 level 降低不被前置），用户切回 Starcat 立刻看到。
        window.level = NSApp.isActive ? .floating : .normal
        window.hidesOnDeactivate = false
        window.animationBehavior = .utilityWindow
        // 窗口关闭后不自动释放，让 controller 的 windowWillClose 里完成清理
        // （与 AboutWindowController 一致）。
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        // 见上文 maskImage 注释：圆角 contentView + borderless 时阴影需要重算一次，
        // 否则首帧 shadow 按矩形 frame 绘制，圆角处会硬切。
        window.invalidateShadow()
        // super.init 之后才能用 self；在此挂上 App 激活 / 失活 observer，让窗口 level
        // 跟随 Starcat 前后台状态切换（详见两个 observer 字段的注释）。
        installAppActivationObservers()
    }

    /// 注册 App 激活 / 失活的 NotificationCenter observer，让 AI 窗 `level` 跟随切换。
    ///
    /// - Starcat 进入前台 (`didBecomeActive`) → `.floating`：恢复"浮在主窗之上"；
    /// - Starcat 离开前台 (`didResignActive`) → `.normal`：其他 App 的窗口可以遮住它。
    ///
    /// 用 main queue 派发回调，因为 NSWindow.level setter 必须在主线程调用；observer
    /// closure 默认在 posted notification 所在线程跑（这里是主线程，但显式 `.main`
    /// 队列更稳）。`[weak self]` 防止 self dealloc 后 observer 被异步触发悬挂调用。
    private func installAppActivationObservers() {
        let center = NotificationCenter.default
        didBecomeActiveObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.window?.level = .floating
        }
        didResignActiveObserver = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.window?.level = .normal
        }
    }

    deinit {
        // block-based observer 在 self dealloc 时不会自动 invalidate（与 selector-based
        // observer 在 macOS 10.11+ 的自动清理不同），必须显式 removeObserver(token) 防
        // NotificationCenter 持有过期 token / 已 deallocated controller 的弱引用闭包
        // 仍被调用（虽然 `[weak self]` 兜底，但 token 留在 center 里仍是泄漏）。
        if let token = didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = didResignActiveObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// 生成 9-slice 圆角蒙版图，用于 `NSVisualEffectView.maskImage`。
    ///
    /// 实现要点：
    /// - 单元图尺寸 = `radius * 2 + 1`：四个角各占 radius、中心 1pt 是拉伸区。
    /// - `capInsets` 标记四角不拉伸区域，`resizingMode = .stretch` 让中间 1pt
    ///   被拉伸到任意目标尺寸，因此一张 37x37 图可以适配任意窗口大小。
    /// - 填充色用 `NSColor.black` —— maskImage 只看 alpha，颜色无意义；
    ///   不透明像素 = 显示，透明像素 = 裁掉。
    private static func roundedCornerMaskImage(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RepoAIWindowController does not support storyboard initialization")
    }

    /// 窗口关闭：从单例 map 中移除自己，下次打开会重建一个全新窗口 + 全新 VM
    /// （清空对话历史，符合 HOM-150 验收"对话存储可选，建议内存中，不持久化"）。
    func windowWillClose(_ notification: Notification) {
        Self.instances.removeValue(forKey: repoId)
    }
}
