//
//  ReadmeWindowController.swift
//  Starcat
//
//  README 纯渲染独立窗。
//
//  ─────────────────────────────────────────────────────────
//  与 RepoDetailWindowController 的视觉差异
//  ─────────────────────────────────────────────────────────
//
//  ReadmeWindowController：
//  - 只有 README 正文 + 右下角浮动工具栏（字号调节 / 回到顶部）
//  - 无 hero 区、无仓库元信息卡片、无 AI 助手入口
//  - 窗口标题 = 仓库全名，或 `owner/repo · path`（同仓 Markdown）
//  - 每次点击都开全新窗口（不复用），方便对照阅读多份 README
//
//  RepoDetailWindowController：
//  - 完整仓库详情页：hero（头像 + 全名 + badges）+ 元信息卡片
//    + README + AI 助手入口 + 翻译 + 分享
//  - 窗口标题 = 仓库全名，含 traffic light + title bar
//  - 同 repo 点击复用窗口（singleton），不同 repo 可同时开
//
//  一句话：ReadmeWindow 是"只看 README"的阅读器；
//         RepoDetailWindow 是"围绕这个仓库做一切操作"的工作台。
//
//  ─────────────────────────────────────────────────────────
//  设计要点
//  ─────────────────────────────────────────────────────────
//
//  - 从 README 浮动工具栏「新窗口打开」或同仓 Markdown 点击触发。
//  - 快照窗：传入的 htmlFragment 已是渲染好的内容，不再调网络。
//  - 文档窗：先出窗显示 loading，Contents API 成功后再填 HTML；失败关窗并回退浏览器。
//  - 不写 `readmes` 表。
//  - 共享 AppSettings（字号偏好在主窗调过的，独立窗同步生效）。
//

import AppKit
import SwiftUI

/// README 独立窗口的尺寸策略。
private enum ReadmeWindowMetrics {
    /// 800×700：与 RepoDetailWindow 一致的默认尺寸，适合长文阅读。
    static let defaultContentSize = NSSize(width: 800, height: 700)
    /// 最小 500×400：再小正文排版会拥挤。
    static let minContentSize = NSSize(width: 500, height: 400)
}

/// 独立窗里继续拦截同仓 Markdown 所需的仓库身份与拉取入口。
struct ReadmeWindowMarkdownContext {
    let owner: String
    let repo: String
    let readmeAPI: ReadmeAPI
}

/// README 独立窗口控制器。
///
/// 每次调用 `show(...)` 都创建新窗口，不复用——用户可能同时打开多个
/// README 做对照阅读。
final class ReadmeWindowController: NSWindowController, NSWindowDelegate {

    /// 可见窗口必须自己保住 controller：`NSWindow.delegate` 是弱引用，
    /// 异步拉 Markdown 时如果只靠局部变量，窗会在回调前被释放。
    private static var liveWindows: [ObjectIdentifier: ReadmeWindowController] = [:]

    private let settings: AppSettings
    private let markdownContext: ReadmeWindowMarkdownContext?
    private let documentTarget: RepositoryMarkdownLinkTarget?
    private let model: RepositoryMarkdownWindowModel
    private let hostedContentController: NSViewController

    /// 显示已经渲染好的 README 快照。
    @MainActor
    static func show(
        htmlFragment: String,
        baseURL: URL?,
        title: String,
        settings: AppSettings,
        markdownContext: ReadmeWindowMarkdownContext? = nil
    ) {
        let controller = ReadmeWindowController(
            htmlFragment: htmlFragment,
            baseURL: baseURL,
            title: title,
            settings: settings,
            markdownContext: markdownContext,
            documentTarget: nil
        )
        retain(controller)
        controller.showWindow(nil)
        positionWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 先开窗再拉指定 Markdown；失败关窗并回退系统浏览器。
    @MainActor
    static func showRepositoryMarkdown(
        target: RepositoryMarkdownLinkTarget,
        settings: AppSettings,
        readmeAPI: ReadmeAPI
    ) {
        let context = ReadmeWindowMarkdownContext(
            owner: target.owner,
            repo: target.repo,
            readmeAPI: readmeAPI
        )
        let controller = ReadmeWindowController(
            htmlFragment: nil,
            baseURL: target.contentBaseURL,
            title: target.windowTitle,
            settings: settings,
            markdownContext: context,
            documentTarget: target
        )
        retain(controller)
        controller.showWindow(nil)
        positionWindow(controller.window)
        NSApp.activate(ignoringOtherApps: true)
        controller.startLoadingIfNeeded()
    }

    /// 将新窗口居中于主窗口；找不到主窗口时退化为屏幕居中。
    @MainActor
    private static func positionWindow(_ window: NSWindow?) {
        guard let window else { return }

        if let mainWindow = NSApp.windows.first(where: { w in
            w !== window
                && w.isVisible
                && w.frameAutosaveName == MainWindowFrameDefaults.autosaveName
        }) {
            let mainCenter = NSPoint(
                x: mainWindow.frame.midX,
                y: mainWindow.frame.midY
            )
            let newOrigin = NSPoint(
                x: mainCenter.x - window.frame.width / 2,
                y: mainCenter.y - window.frame.height / 2
            )
            window.setFrameOrigin(newOrigin)
        } else {
            window.center()
        }
    }

    @MainActor
    private static func retain(_ controller: ReadmeWindowController) {
        liveWindows[ObjectIdentifier(controller)] = controller
    }

    private init(
        htmlFragment: String?,
        baseURL: URL?,
        title: String,
        settings: AppSettings,
        markdownContext: ReadmeWindowMarkdownContext?,
        documentTarget: RepositoryMarkdownLinkTarget?
    ) {
        self.settings = settings
        self.markdownContext = markdownContext
        self.documentTarget = documentTarget
        self.model = RepositoryMarkdownWindowModel(
            htmlFragment: htmlFragment,
            baseURL: baseURL
        )

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: ReadmeWindowMetrics.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        let content = RepositoryMarkdownWindowRoot(
            model: model,
            settings: settings,
            markdownContext: markdownContext
        )
        .starcatAnimationOverride()
        .appLocaleEnvironment()
        .environment(\.starcatInterfaceScale, settings.interfaceScale)
        .dynamicTypeSize(settings.interfaceScale.dynamicTypeSize)
        .environment(settings)

        let hostingController = NSHostingController(rootView: content)
        window.contentViewController = hostingController
        window.title = title
        window.setContentSize(ReadmeWindowMetrics.defaultContentSize)
        window.contentMinSize = ReadmeWindowMetrics.minContentSize
        window.minSize = ReadmeWindowMetrics.minContentSize
        window.isReleasedWhenClosed = false
        self.hostedContentController = hostingController

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ReadmeWindowController does not support storyboard initialization")
    }

    @MainActor
    private func startLoadingIfNeeded() {
        guard let target = documentTarget, let markdownContext else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let html = try await markdownContext.readmeAPI.fetchRenderedRepositoryMarkdown(
                    owner: target.owner,
                    repo: target.repo,
                    path: target.path,
                    ref: target.ref
                )
                self.model.htmlFragment = html
                self.model.baseURL = target.contentBaseURL
            } catch {
                AppLog.ui.error(
                    "Repository markdown window failed: \(error.localizedDescription, privacy: .public)"
                )
                NSWorkspace.shared.open(target.browserURL)
                self.window?.close()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.liveWindows[ObjectIdentifier(self)] = nil
    }
}

/// 独立窗内容状态。快照窗一开始就有 HTML；文档窗先空着再填。
@MainActor
@Observable
private final class RepositoryMarkdownWindowModel {
    var htmlFragment: String?
    var baseURL: URL?

    init(htmlFragment: String?, baseURL: URL?) {
        self.htmlFragment = htmlFragment
        self.baseURL = baseURL
    }
}

private struct RepositoryMarkdownWindowRoot: View {
    let model: RepositoryMarkdownWindowModel
    let settings: AppSettings
    let markdownContext: ReadmeWindowMarkdownContext?

    var body: some View {
        if let htmlFragment = model.htmlFragment {
            ReadmeWebView(
                htmlFragment: htmlFragment,
                baseURL: model.baseURL,
                markdownLinkRepositoryOwner: markdownContext?.owner,
                markdownLinkRepositoryName: markdownContext?.repo,
                onOpenRepositoryMarkdown: openRepositoryMarkdown
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var openRepositoryMarkdown: ((RepositoryMarkdownLinkTarget) -> Void)? {
        guard let markdownContext else { return nil }
        return { target in
            ReadmeWindowController.showRepositoryMarkdown(
                target: target,
                settings: settings,
                readmeAPI: markdownContext.readmeAPI
            )
        }
    }
}
