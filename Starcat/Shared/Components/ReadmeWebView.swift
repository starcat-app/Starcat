//
//  ReadmeWebView.swift
//  Starcat
//
//  WKWebView 包装：渲染 GitHub 服务端返回的 README HTML 片段。
//
//  设计要点：
//  1. 输入 = GitHub `Accept: application/vnd.github.html` 返回的纯 HTML 片段
//     （已是渲染好的 GFM，含 anchor / code block / table / mermaid / 任务列表等）
//  2. 包装一层带 GFM 主题 CSS 的完整 HTML（亮/暗自适应 prefers-color-scheme）
//  3. 禁止页面自带 JavaScript：GitHub HTML 不需要页面脚本，关闭可减小攻击面。
//     例外：注入 app-owned user script，只用于 README 阅读体验增强：
//     滚动上报、图片加载态、图片点击预览、翻译 DOM 与 Mermaid 检测；不执行 README
//     自带脚本。Mermaid 运行时也来自 App Bundle，并仅在文档确实包含图表时按需加载。
//  4. 图片相对路径重写：
//     - GitHub 的 HTML render 端点对 Markdown `![]()` 会做 camo 代理重写，
//       但对原生 HTML `<img src="./xx">` 不重写，原样吐回相对路径
//     - 我们的 baseURL 是 `https://github.com/owner/repo`，浏览器把 `./logo.PNG`
//       解析成 `https://github.com/owner/logo.PNG` → 404
//     - 修复：HOM-201 P1-2（2026-06-14）把"`<img>` 相对路径 → raw URL"重写从渲染层
//       迁移到 `ReadmeAPI` upsert 前（见 `ReadmeAssetURLRewriter`）。本视图收到的
//       `htmlFragment` 已是 rewrite 过的版本，直接 wrap document 即可，不再在
//       渲染线程跑 NSRegularExpression。
//  5. 链接拦截（decidePolicyFor navigationAction）：
//     - 用户点链接（`.linkActivated`）→ NSWorkspace.open 跳系统浏览器
//     - 主框架的"非首次"导航（含右键菜单"重新加载"、reload()、meta refresh 等）
//       一律 cancel —— 否则会发起对 baseURL（repo 的 GitHub 页面）的真实请求，
//       把整个 GitHub 仓库页面拉进 WebView。"真正的刷新"应走 ReadmeViewModel.reload()
//       重新走一遍 ETag 缓存路径，由 SwiftUI 重建 view 时触发 loadHTMLString。
//
//  约束：
//  - WKWebView 在 NSViewRepresentable 里复用：updateNSView 只在 html 真正变化时 reload
//    （避免列表切换 repo 时白闪）
//  - baseURL 必须由 repositoryContentBaseURL(from:) 生成并保留末尾 `/`，否则
//    WebKit 会把 HEAD 当文件名，`docs/guide.md` 会错误解析成 `/blob/docs/guide.md`
//  - **背景透明**：`drawsBackground = false` + CSS `html, body { background: transparent }`
//    是必须成对存在的。任一缺失就会在暗色下看到色差
//    （GitHub `#0d1117` 与 SwiftUI 宿主 `NSColor.windowBackgroundColor` 不同色）。
//    亮色下虽然两者都接近 `#ffffff`，看不出差异，但同样要保留 transparent。
//  - **暗色局部表面**（代码块 / 行内 code / 表格斑马纹 / 引用条）不能再用 GitHub
//    `#161b22` / `#30363d`：那组色是给更黑的 `#0d1117` 画布准备的抬升面。页面已经
//    透出系统窗底后，它们会变成比页面更黑的坑。改为半透明白叠加，相对真实窗底抬升。
//
//  已知系统噪音（**不是 Bug，不要排查**）：
//  macOS App Sandbox 下 WKWebView 加载新内容时，WebContent 进程会向 RunningBoard /
//  IOKit / pboard / launchservicesd / networkd 等系统服务申请各种"使用状态"切换
//  或 sandbox extension，而我们的 app 没有 Apple 内部私有 entitlement
//  （如 `com.apple.runningboard.assertions.webkit` / `com.apple.multitasking.systemappassertions`），
//  这些请求会被静默拒绝并打 debug log。具体字符串包括但不限于：
//    - `Failed to change to usage state 2: (null)` — 每次切 repo（loadHTMLString 触发）都会出现
//    - `Could not create a sandbox extension for ...`
//    - `Error acquiring assertion: <Error Domain=RBSServiceErrorDomain Code=1 ...>`
//    - `WebProcessProxy::didFinishLaunching: Invalid connection identifier` 之类
//  以上**全部是无害噪音**，App Store 审核也不会卡（私有 entitlement 我们也加不上）。
//  开发期如想清净，可在 Scheme → Run → Arguments → Environment Variables 加
//  `OS_ACTIVITY_MODE=disable` 屏蔽所有系统 os_log，只看 `AppLog.*` 业务日志。
//

import SwiftUI
import WebKit
import AppKit

extension Notification.Name {
    /// 外部指引请求当前 README 回到顶部，用于在展示顶部 Hero 指引前恢复稳定锚点。
    static let repoDetailScrollToTopRequested = Notification.Name("starcat.repoDetail.scrollToTopRequested")
}

struct ReadmeWebView: View {

    /// 与 GitHub 线上 Viewscreen 当前使用的版本对齐；测试会校验对应 Bundle 资源存在。
    nonisolated static let mermaidRendererVersion = "11.16.0"
    nonisolated static let mermaidRuntimeResourceName = "mermaid-\(mermaidRendererVersion).min"

    /// README 文档结束时注入的 app-owned 脚本。保持 internal 仅用于验证真实注入内容，
    /// 页面自身脚本仍由 CSP 禁止，业务层不应直接执行或拼接该字符串。
    static var readmeEnhancementScript: String {
        ReadmeWebContentView.Coordinator.readmeEnhancementScript
    }

    /// README 媒体只允许用户主动开始播放；页面里的 autoplay 属性不能绕过这一层。
    ///
    /// 保持 internal 便于单测直接验证 WebKit 配置，不为单一策略再引入播放器对象。
    static func configureMediaPlayback(_ configuration: WKWebViewConfiguration) {
        configuration.mediaTypesRequiringUserActionForPlayback = .all
    }

    /// GitHub 返回的 HTML 片段（不含 <html>/<head>/<body>）。
    let htmlFragment: String

    /// 调用方可提供的轻量文档身份。详情页用它避免 `updateNSView` 每次重算时比较整份 HTML；
    /// 其它调用方省略后仍回退到内容本身，保持原有正确性。
    var documentID: String? = nil

    /// 用于解析 HTML 内相对 URL 的基地址（链接 `<a href>` 等）。
    /// 通常传 repo.htmlUrl（https://github.com/owner/repo）。
    /// HOM-201 P1-2（2026-06-14）起，`<img>` 相对路径已在 IO 层（`ReadmeAPI`）
    /// 通过 `ReadmeAssetURLRewriter.rewrite(...)` 预处理为 raw.githubusercontent.com
    /// 绝对 URL，**渲染层不再依赖 baseURL 解析图片**；baseURL 仅用于链接解析。
    let baseURL: URL?

    /// README 内部滚动度量变化回调。
    ///
    /// 背景：README 由 WKWebView 自己滚动，外层 SwiftUI 看不到 ScrollView offset。
    /// 详情页需要在用户阅读时收起顶部元信息面板，所以这里把 scroll offset 与可滚动
    /// 余量一并透出；不把 WKWebView / NSScrollView 暴露给业务层。
    var onScrollReportChange: (RepoDetailScrollReport) -> Void = { _ in }

    /// 「在新窗口打开 README」回调。
    ///
    /// nil 时浮动工具栏不显示该按钮（独立窗口自身不提供此操作，避免无限套娃）。
    var onOpenInNewWindow: (() -> Void)? = nil

    /// 「导出 README Markdown」回调。
    ///
    /// nil 时浮动工具栏不显示该按钮。
    var onExportMarkdown: (() -> Void)? = nil

    /// 当前 README 所属仓库。有值且设置打开「应用内打开仓库文档」时，
    /// 同仓 Markdown 点击走 `onOpenRepositoryMarkdown`，不再进浏览器。
    var markdownLinkRepositoryOwner: String? = nil
    var markdownLinkRepositoryName: String? = nil

    /// 打开同仓 Markdown 独立窗。nil 时即使开关打开也回退浏览器。
    var onOpenRepositoryMarkdown: ((RepositoryMarkdownLinkTarget) -> Void)? = nil

    /// 当前翻译渲染状态。默认隐藏，普通 README 调用方无需感知翻译能力。
    var translationRenderState: ReadmeTranslationRenderState = .hidden

    /// WebView 完成 DOM 提取后回传两种模式的纯文本。只在本机内存流转，
    /// 用户点击翻译后才会把当前模式对应的数据发给 AI。
    var onTranslationSourceChange: (ReadmeTranslationSourceSnapshot) -> Void = { _ in }

    @Environment(AppSettings.self) private var settings
    @State private var scrollToTopRequestID = 0
    @State private var isFindBarVisible = false
    @State private var findQuery = ""
    @State private var findRequest = ReadmeFindRequest()
    @State private var findHasMatch: Bool?
    @FocusState private var isFindFieldFocused: Bool
    @State private var isFontToolbarExpanded = false

    var body: some View {
        ReadmeWebContentView(
            htmlFragment: htmlFragment,
            documentID: documentID,
            baseURL: baseURL,
            onScrollReportChange: handleScrollReport,
            readmeFontSizeAdjustment: settings.readmeFontSizeAdjustment,
            scrollToTopRequestID: scrollToTopRequestID,
            findRequest: findRequest,
            onFindResult: { findHasMatch = $0 },
            translationRenderState: translationRenderState,
            onTranslationSourceChange: onTranslationSourceChange,
            openRepositoryMarkdownInApp: settings.openRepositoryMarkdownInApp,
            markdownLinkRepositoryOwner: markdownLinkRepositoryOwner,
            markdownLinkRepositoryName: markdownLinkRepositoryName,
            onOpenRepositoryMarkdown: onOpenRepositoryMarkdown
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if isFindBarVisible {
                ReadmeFindBar(
                    query: $findQuery,
                    hasMatch: findHasMatch,
                    isFindFieldFocused: $isFindFieldFocused,
                    onNext: { submitFind(query: findQuery, backwards: false) },
                    onPrevious: { submitFind(query: findQuery, backwards: true) },
                    onClose: hideFindBar
                )
            }
        }
        // 工具条必须作为 overlay 贴边悬浮，不能参与 WebView 正文布局。
        .overlay(alignment: .bottomTrailing) {
            ReadmeFloatingToolbar(
                fontSizeAdjustment: settings.readmeFontSizeAdjustment,
                isExpanded: isFontToolbarExpanded,
                toggleExpanded: toggleFontToolbar,
                decreaseFontSize: decreaseFontSize,
                resetFontSize: resetFontSize,
                increaseFontSize: increaseFontSize,
                openInNewWindow: onOpenInNewWindow,
                onExportMarkdown: onExportMarkdown
            )
            .padding(.trailing, 10)
            .padding(.bottom, 54)
        }
        // 回到顶部是独立常驻操作，固定贴在 README 渲染区右下角。
        .overlay(alignment: .bottomTrailing) {
            ReadmeBackToTopButton(action: scrollToTop)
                .padding(.trailing, 10)
                .padding(.bottom, 14)
        }
        .onReceive(NotificationCenter.default.publisher(for: .repoDetailScrollToTopRequested)) { _ in
            scrollToTop()
        }
        .onChange(of: findQuery) { _, newValue in
            guard isFindBarVisible else { return }
            submitFind(query: newValue, backwards: false)
        }
        .onChange(of: readmeFindCommandIdentity) { _, _ in
            hideFindBar()
        }
        .starcatReadmeFindCommand(identity: readmeFindCommandIdentity) {
            showFindBar()
        }
    }

    private func decreaseFontSize() {
        settings.readmeFontSizeAdjustment = AppSettings.clampedReadmeFontSizeAdjustment(
            settings.readmeFontSizeAdjustment - 1
        )
    }

    private func resetFontSize() {
        settings.readmeFontSizeAdjustment = 0
    }

    private func increaseFontSize() {
        settings.readmeFontSizeAdjustment = AppSettings.clampedReadmeFontSizeAdjustment(
            settings.readmeFontSizeAdjustment + 1
        )
    }

    private func scrollToTop() {
        scrollToTopRequestID &+= 1
    }

    /// 唤出页内查找条。系统 `NSTextFinder` 不能在 SwiftUI `updateNSView` 里同步弹出：
    /// 那正好处于 AppKit 布局，`performTextFinderAction` 会改视图层级，macOS 26 上
    /// 变成 unrecognized selector + layout 递归崩溃。改用公开的 `WKWebView.find`。
    private func showFindBar() {
        isFindBarVisible = true
        isFindFieldFocused = true
        if !findQuery.isEmpty {
            submitFind(query: findQuery, backwards: false)
        }
    }

    private func hideFindBar() {
        guard isFindBarVisible else { return }
        isFindBarVisible = false
        isFindFieldFocused = false
        findHasMatch = nil
        submitFind(query: "", backwards: false)
    }

    private func submitFind(query: String, backwards: Bool) {
        findRequest.generation &+= 1
        findRequest.query = query
        findRequest.backwards = backwards
    }

    /// 切仓时重新登记查找动作，避免闭包还指向上一份 HTML 的 WebView。
    private var readmeFindCommandIdentity: String {
        "\(baseURL?.absoluteString ?? "")|\(htmlFragment.count)|\(htmlFragment.prefix(48))"
    }

    private func toggleFontToolbar() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isFontToolbarExpanded.toggle()
        }
    }

    private func handleScrollReport(_ report: RepoDetailScrollReport) {
        // 阅读 README 时常常只滚不点；滚动仍记成详情栏，供 ⌘R 刷新详情而不是列表。
        // 走 shared、不 `@Environment` 订阅 router：否则本视图会成为 CommandRouter
        // 的观察者，滚动触发 activate 后又立刻重绘 WebView 宿主。
        StarcatCommandRouter.shared.activate(.detail)
        onScrollReportChange(report)
        collapseToolbarForScroll()
    }

    private func collapseToolbarForScroll() {
        guard isFontToolbarExpanded else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            isFontToolbarExpanded = false
        }
    }

    // MARK: - README 链接基地址

    /// 构造 README 相对链接使用的 GitHub 仓库内容目录。
    ///
    /// GitHub HTML 渲染 API 返回的 `href="docs/guide.md"` 需要相对于
    /// `/blob/HEAD/` 解析。这里显式声明为目录 URL，关键是保留末尾 `/`；如果使用
    /// `/blob/HEAD`，Foundation / WebKit 会把 `HEAD` 当作当前文件名并在解析时丢掉它。
    static func repositoryContentBaseURL(from repositoryURL: URL) -> URL {
        repositoryURL.appendingPathComponent("blob/HEAD", isDirectory: true)
    }

    /// 将 GitHub 的 HTML 片段包装为完整文档（带 GFM 主题 CSS）。
    static func assembleDocument(
        fragment: String,
        isDark: Bool,
        interfaceScale: InterfaceScale = .standard,
        readmeFontSizeAdjustment: Int = 0
    ) -> String {
        ReadmeWebContentView.assembleDocument(
            fragment: fragment,
            isDark: isDark,
            interfaceScale: interfaceScale,
            readmeFontSizeAdjustment: readmeFontSizeAdjustment
        )
    }
}

private struct ReadmeWebContentView: NSViewRepresentable {
    let htmlFragment: String
    let documentID: String?
    let baseURL: URL?
    var onScrollReportChange: (RepoDetailScrollReport) -> Void
    let readmeFontSizeAdjustment: Int
    let scrollToTopRequestID: Int
    let findRequest: ReadmeFindRequest
    var onFindResult: (Bool?) -> Void
    let translationRenderState: ReadmeTranslationRenderState
    var onTranslationSourceChange: (ReadmeTranslationSourceSnapshot) -> Void
    var openRepositoryMarkdownInApp: Bool
    var markdownLinkRepositoryOwner: String?
    var markdownLinkRepositoryName: String?
    var onOpenRepositoryMarkdown: ((RepositoryMarkdownLinkTarget) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        PerformanceTracer.shared.mark(.readmeWebViewCreated)
        let config = WKWebViewConfiguration()
        // GitHub README HTML 已是静态结构，不需要页面脚本。这里仍允许 WebKit 执行
        // app-owned user script（见 installScrollReportingScript），页面脚本由我们注入的
        // CSP `script-src 'none'` 禁掉，兼顾滚动回调和攻击面控制。
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pagePrefs
        config.userContentController = context.coordinator.makeUserContentController()
        ReadmeWebView.configureMediaPlayback(config)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // 透明背景，跟随系统主题底色
        configureScrollbar(for: webView)

        context.coordinator.webView = webView
        context.coordinator.onScrollReportChange = onScrollReportChange
        context.coordinator.onTranslationSourceChange = onTranslationSourceChange
        context.coordinator.openRepositoryMarkdownInApp = openRepositoryMarkdownInApp
        context.coordinator.markdownLinkRepositoryOwner = markdownLinkRepositoryOwner
        context.coordinator.markdownLinkRepositoryName = markdownLinkRepositoryName
        context.coordinator.onOpenRepositoryMarkdown = onOpenRepositoryMarkdown
        context.coordinator.updateTranslationRenderState(
            translationRenderState,
            reduceMotion: reduceMotion
        )
        loadIfNeeded(into: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onScrollReportChange = onScrollReportChange
        context.coordinator.onTranslationSourceChange = onTranslationSourceChange
        context.coordinator.openRepositoryMarkdownInApp = openRepositoryMarkdownInApp
        context.coordinator.markdownLinkRepositoryOwner = markdownLinkRepositoryOwner
        context.coordinator.markdownLinkRepositoryName = markdownLinkRepositoryName
        context.coordinator.onOpenRepositoryMarkdown = onOpenRepositoryMarkdown
        context.coordinator.updateTranslationRenderState(
            translationRenderState,
            reduceMotion: reduceMotion
        )
        loadIfNeeded(into: webView, context: context)
        scrollToTopIfNeeded(in: webView, context: context)
        performFindIfNeeded(in: webView, context: context)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // WebView 退出 SwiftUI 层级后仍可能持有媒体进程；先暂停并终止请求，避免关窗后残留声音。
        coordinator.cancelFind()
        coordinator.stopMediaPlayback(stopLoading: true)
        coordinator.removeScriptMessageHandler()
    }

    // MARK: - Private

    /// 让 README 的 WebKit 滚动条与详情页其它滚动区域保持一致：只在滚动时以 overlay 方式出现。
    ///
    /// `WKWebView` 没有公开 macOS scrollView 属性，只能在 view hierarchy 建好后查找内部
    /// `NSScrollView`。这里不依赖具体私有 class 名，只配置第一个找到的标准 AppKit scroll view，
    /// 避免把 WebKit 内部实现细节泄漏到业务层。
    private func configureScrollbar(for webView: WKWebView) {
        DispatchQueue.main.async {
            guard let scrollView = webView.firstDescendant(ofType: NSScrollView.self) else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
    }

    /// 仅在 html 内容或主题变化时重新 loadHTML；仅字号变化时走 JS 动态更新 CSS 变量。
    ///
    /// 调用 `loadHTMLString` 前会把 `expectsInitialLoad` 置 true，让 Coordinator
    /// 放行紧接而来的那一次主框架导航，之后所有主框架导航全部 cancel
    /// （挡住右键菜单"重新加载"会把整页 GitHub 拉进来的副作用）。
    ///
    /// 字号调整不触发 HTML 重载：重载会产生 scroll 事件 → `collapseToolbarForScroll()`
    /// 把字号面板意外关闭，用户体验上无法连续调整。改为 `evaluateJavaScript` 直接写
    /// `--readme-body-font-size` CSS 变量，无重载、无白闪、不触发 scroll。
    private func loadIfNeeded(into webView: WKWebView, context: Context) {
        let contentKey = ReadmeKey(
            documentID: documentID ?? htmlFragment,
            baseURL: baseURL,
            isDark: colorScheme == .dark,
            interfaceScale: interfaceScale
        )

        // 内容或主题变化 → 完整重载 HTML（含初始字号）
        if context.coordinator.lastLoadedKey != contentKey {
            context.coordinator.lastLoadedKey = contentKey
            context.coordinator.lastAppliedFontSizeAdjustment = readmeFontSizeAdjustment
            // loadHTMLString 替换 DOM 前主动暂停旧文档，避免切换 repo 的短暂异步窗口继续出声。
            context.coordinator.stopMediaPlayback(stopLoading: false)
            context.coordinator.prepareForDocumentReload()

            // HOM-201 P1-2（2026-06-14）：`htmlFragment` 已是 `ReadmeAPI` rewrite 后的
            // 内容(img src 已是 raw.githubusercontent.com 绝对 URL),这里直接 wrap document,
            // 不再在渲染线程跑 NSRegularExpression。
            let fullHTML = Self.assembleDocument(
                fragment: htmlFragment,
                isDark: colorScheme == .dark,
                interfaceScale: interfaceScale,
                readmeFontSizeAdjustment: readmeFontSizeAdjustment
            )
            context.coordinator.expectsInitialLoad = true
            webView.loadHTMLString(fullHTML, baseURL: baseURL)
            return
        }

        // 仅字号变化 → JS 动态更新 CSS 变量，不重载 HTML，不触发 scroll 事件
        if context.coordinator.lastAppliedFontSizeAdjustment != readmeFontSizeAdjustment {
            context.coordinator.lastAppliedFontSizeAdjustment = readmeFontSizeAdjustment
            let newFontSize = Self.readmeBodyFontSize(
                for: interfaceScale,
                adjustment: readmeFontSizeAdjustment
            )
            let cssPixels = String(format: "%.2fpx", Double(newFontSize))
            webView.evaluateJavaScript(
                "document.documentElement.style.setProperty('--readme-body-font-size', '\(cssPixels)');"
            )
        }
    }

    private func scrollToTopIfNeeded(in webView: WKWebView, context: Context) {
        guard scrollToTopRequestID != context.coordinator.lastScrollToTopRequestID else { return }
        context.coordinator.lastScrollToTopRequestID = scrollToTopRequestID
        guard scrollToTopRequestID > 0 else { return }
        webView.evaluateJavaScript("window.scrollTo({ top: 0, behavior: 'smooth' });")
    }

    /// 用 WebKit 公开的 `find` API 高亮正文。不能走 `NSTextFinder`：那会在宿主
    /// `WKWebView` 上插入 Find Bar 子视图，和 SwiftUI representable 的布局冲突。
    private func performFindIfNeeded(in webView: WKWebView, context: Context) {
        context.coordinator.onFindResult = onFindResult
        context.coordinator.performFind(findRequest, in: webView)
    }

    /// 将 GitHub 的 HTML 片段包装为完整文档（带 GFM 主题 CSS）。
    static func assembleDocument(
        fragment: String,
        isDark: Bool,
        interfaceScale: InterfaceScale = .standard,
        readmeFontSizeAdjustment: Int = 0
    ) -> String {
        let css = ReadmeCSS.full + "\n" + ReadmeMermaidDOM.css + "\n" + ReadmeTranslationDOM.css + "\n" + ReadmeCSS.readingVariables(
            bodyFontSize: readmeBodyFontSize(
                for: interfaceScale,
                adjustment: readmeFontSizeAdjustment
            ),
            lineHeight: readmeLineHeight
        )
        let bodyClass = isDark ? "markdown-body dark" : "markdown-body"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; media-src https:; object-src 'none'; base-uri 'none';">
        <style>\(css)</style>
        </head>
        <body class="\(bodyClass)">
        <article>\(fragment)</article>
        </body>
        </html>
        """
    }

    /// README 是长文阅读区，标准档比列表正文更偏阅读舒适；用户设置的界面倍率仍统一生效。
    private static let standardReadmeBodyFontSize: CGFloat = 16
    private static let readmeLineHeight: CGFloat = 1.62

    private static func readmeBodyFontSize(for interfaceScale: InterfaceScale, adjustment: Int) -> CGFloat {
        interfaceScale.scaled(standardReadmeBodyFontSize + CGFloat(AppSettings.clampedReadmeFontSizeAdjustment(adjustment)))
    }

    // MARK: - Coordinator

    /// 同时负责导航委托 + 记录上次加载的 HTML（避免重复 load 触发白闪）。
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

        weak var webView: WKWebView?
        var lastLoadedKey: ReadmeKey?
        var lastScrollToTopRequestID = 0
        var onScrollReportChange: (RepoDetailScrollReport) -> Void = { _ in }
        var onTranslationSourceChange: (ReadmeTranslationSourceSnapshot) -> Void = { _ in }
        var onFindResult: (Bool?) -> Void = { _ in }
        var openRepositoryMarkdownInApp = false
        var markdownLinkRepositoryOwner: String?
        var markdownLinkRepositoryName: String?
        var onOpenRepositoryMarkdown: ((RepositoryMarkdownLinkTarget) -> Void)?
        private weak var userContentController: WKUserContentController?
        private var pendingTranslationRenderState: ReadmeTranslationRenderState = .hidden
        private var lastAppliedTranslationRevision: Int?
        /// App 关动画或系统 Reduce Motion 时，DOM 入场一律关掉。
        private var translationReduceMotion = false
        private var mermaidDocumentRevision = 0
        private var mermaidRuntimeTask: Task<Void, Never>?
        private var findTask: Task<Void, Never>?
        private var lastFindGeneration: UInt64 = 0

        /// 在 layout 之外的下一拍执行查找，避免和 SwiftUI `updateNSView` 抢同一轮视图更新。
        func performFind(_ request: ReadmeFindRequest, in webView: WKWebView) {
            guard request.generation != lastFindGeneration else { return }
            lastFindGeneration = request.generation
            guard request.generation > 0 else { return }
            findTask?.cancel()
            let query = request.query
            let backwards = request.backwards
            findTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                let configuration = WKFindConfiguration()
                configuration.backwards = backwards
                configuration.wraps = true
                if query.isEmpty {
                    _ = try? await webView.find("", configuration: configuration)
                    self.onFindResult(nil)
                    return
                }
                let result = try? await webView.find(query, configuration: configuration)
                guard !Task.isCancelled, let result else { return }
                self.onFindResult(result.matchFound)
            }
        }

        func cancelFind() {
            findTask?.cancel()
            findTask = nil
        }

        /// 上次已应用的 README 字号调整量。
        ///
        /// 用于在 `updateNSView` 时检测"仅字号变化"场景：如果内容 key 未变但字号变了，
        /// 走 JS 动态更新 CSS 变量而非 `loadHTMLString` 重载，避免重载触发的 scroll 事件
        /// 把字号面板意外关闭，同时消除白闪。
        var lastAppliedFontSizeAdjustment: Int?

        /// 由 `loadIfNeeded` 在调用 `loadHTMLString` 前置 true，
        /// 用于放行紧接而来的那一次主框架导航；放行后立即置 false。
        /// 之后任何主框架导航（reload / meta refresh / 页内 location）都会被 cancel。
        var expectsInitialLoad: Bool = false

        /// 构造带 README 阅读增强脚本的 content controller。
        ///
        /// 为什么不用 NSScrollView 观察：macOS `WKWebView` 没有公开 `scrollView` 属性，
        /// 并且不同 WebKit 版本的内部 NSView 子树并不稳定。直接从文档里监听 `scroll`
        /// 事件拿 `window.scrollY` 更接近真实阅读位置，也不会依赖私有 view class。
        ///
        /// 安全边界：
        /// - user script 只读取候选段落的可见文本并回传当前进程；未点击翻译前不出本机；
        /// - 只扫描 h1...h6 / p / li / blockquote / td / th / summary / dt / dd，
        ///   明确排除 pre / code / script / style / svg 等非自然语言节点；
        /// - Mermaid handler 只接收 1...100 的图表数量；源码留在 DOM 内并限制单图 50,000 字符；
        /// - HTML 文档里加了 CSP `script-src 'none'`，页面自带 `<script>` / inline handler 不执行。
        /// - message handler 对滚动 payload 和段落数组分别做类型、长度校验。
        func makeUserContentController() -> WKUserContentController {
            let controller = WKUserContentController()
            let script = WKUserScript(
                source: ReadmeWebView.readmeEnhancementScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            controller.addUserScript(script)
            controller.add(self, name: ReadmeWebViewConstants.scrollMessageName)
            controller.add(self, name: ReadmeWebViewConstants.translationSourceMessageName)
            controller.add(self, name: ReadmeWebViewConstants.mermaidRequestMessageName)
            userContentController = controller
            return controller
        }

        /// Swift 6 下 `deinit` 是非隔离上下文，不能直接调用 MainActor 隔离的
        /// `WKUserContentController.removeScriptMessageHandler`。SwiftUI 拆除 NSView 时会在
        /// 主线程调用 `dismantleNSView`，这里集中做 WebKit handler 清理，避免循环持有。
        func removeScriptMessageHandler() {
            userContentController?.removeScriptMessageHandler(forName: ReadmeWebViewConstants.scrollMessageName)
            userContentController?.removeScriptMessageHandler(
                forName: ReadmeWebViewConstants.translationSourceMessageName
            )
            userContentController?.removeScriptMessageHandler(
                forName: ReadmeWebViewConstants.mermaidRequestMessageName
            )
            mermaidRuntimeTask?.cancel()
            mermaidRuntimeTask = nil
            userContentController = nil
        }

        /// 暂停当前 README 的所有媒体；销毁时额外停止尚未完成的网络加载。
        ///
        /// 使用 WebKit 的页面级 API，而不是遍历 DOM 调 `pause()`：即使视频处于全屏等媒体展示态，
        /// WebKit 仍能统一收口；同时不需要把播放器状态复制到 SwiftUI 或 Coordinator。
        func stopMediaPlayback(stopLoading: Bool) {
            guard let webView else { return }
            webView.pauseAllMediaPlayback(completionHandler: nil)
            if stopLoading {
                webView.stopLoading()
            }
        }

        /// 内容或主题重载后，旧 DOM 已消失；导航完成时必须把当前翻译状态重新注入。
        /// 同时取消旧文档尚未完成的 Mermaid 任务，避免切换仓库后把图表写进新 DOM。
        func prepareForDocumentReload() {
            lastAppliedTranslationRevision = nil
            mermaidDocumentRevision &+= 1
            mermaidRuntimeTask?.cancel()
            mermaidRuntimeTask = nil
        }

        /// 保存最新 SwiftUI 状态，并在当前文档已可用时做无重载 DOM 更新。
        func updateTranslationRenderState(
            _ state: ReadmeTranslationRenderState,
            reduceMotion: Bool
        ) {
            pendingTranslationRenderState = state
            translationReduceMotion = reduceMotion
            applyTranslationRenderStateIfNeeded()
        }

        private func applyTranslationRenderStateIfNeeded() {
            guard let webView,
                  lastAppliedTranslationRevision != pendingTranslationRenderState.revision
            else { return }

            let state = pendingTranslationRenderState
            let payload: [[String: String]] = state.translations.map {
                ["id": $0.id, "translation": $0.translatedText]
            }
            let animateEntrance = state.prefersAnimatedEntrance && !translationReduceMotion
            lastAppliedTranslationRevision = state.revision
            Task { @MainActor in
                do {
                    _ = try await webView.callAsyncJavaScript(
                        """
                        if (typeof window.starcatApplyReadmeTranslations === 'function') {
                            window.starcatApplyReadmeTranslations(mode, isVisible, translations, animate);
                        }
                        """,
                        arguments: [
                            "isVisible": state.isVisible,
                            "mode": state.mode.rawValue,
                            "translations": payload,
                            "animate": animateEntrance
                        ],
                        in: nil,
                        contentWorld: .page
                    )
                } catch {
                    AppLog.ui.debug("Readme translation DOM update deferred: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        /// 收到文档端的“存在 Mermaid”信号后才读取并执行约 3.4 MB 的本地运行时。
        ///
        /// 关键约束：
        /// - README 自带脚本仍被 CSP 禁止；这里只通过 WebKit 原生 API 执行 App Bundle 内
        ///   固定版本的 Mermaid，不把任意远端脚本注入页面。
        /// - Bundle IO 放到后台任务，避免长 README 首帧被同步文件读取阻塞。
        /// - `mermaidDocumentRevision` 把异步结果绑定到发起请求的文档；用户快速切仓库或
        ///   切换主题时，旧任务即使晚返回也不能改写新文档。
        /// - Mermaid 使用 `securityLevel: sandbox`，最终 SVG 位于无脚本权限的 data URL
        ///   iframe 内，图表文本不能逃逸到 README 主文档。
        private func loadMermaidRuntimeIfNeeded(sectionCount: Int) {
            guard (1...ReadmeWebViewConstants.maximumMermaidSectionCount).contains(sectionCount),
                  mermaidRuntimeTask == nil,
                  let webView
            else { return }

            let revision = mermaidDocumentRevision
            let failureMessage = String.l10n("readme.mermaid.renderFailed")
            mermaidRuntimeTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }

                do {
                    guard let runtimeURL = Bundle.main.url(
                        forResource: ReadmeWebView.mermaidRuntimeResourceName,
                        withExtension: "js"
                    ) else {
                        throw MermaidRuntimeError.resourceMissing
                    }

                    let runtimeSource = try await Task.detached(priority: .userInitiated) {
                        try String(contentsOf: runtimeURL, encoding: .utf8)
                    }.value

                    try Task.checkCancellation()
                    guard revision == self.mermaidDocumentRevision else { return }

                    // `evaluateJavaScript` 来自 App 进程，不受页面 `script-src 'none'`
                    // 影响；这正是保持 README 页面脚本全禁用的同时提供本地图表渲染的边界。
                    // Bundle 尾表达式会把 `mermaid` 对象赋给 globalThis；额外返回布尔值，
                    // 避免 WebKit 尝试把包含函数的巨大 JS 对象桥接回 Swift。
                    _ = try await webView.evaluateJavaScript(runtimeSource + "\n;true;")
                    try Task.checkCancellation()
                    guard revision == self.mermaidDocumentRevision else { return }

                    _ = try await webView.callAsyncJavaScript(
                        """
                        if (typeof window.starcatRenderMermaidSections !== 'function') {
                            throw new Error('Starcat Mermaid bridge is unavailable');
                        }
                        return await window.starcatRenderMermaidSections(failureMessage);
                        """,
                        arguments: ["failureMessage": failureMessage],
                        in: nil,
                        contentWorld: .page
                    )
                } catch is CancellationError {
                    // 文档切换时主动取消，不属于用户可见错误。
                } catch {
                    guard revision == self.mermaidDocumentRevision else { return }
                    await self.markMermaidSectionsFailed(
                        in: webView,
                        message: failureMessage
                    )
                    AppLog.ui.error(
                        "README Mermaid render failed: \(error.localizedDescription, privacy: .public)"
                    )
                }

                if revision == self.mermaidDocumentRevision {
                    self.mermaidRuntimeTask = nil
                }
            }
        }

        private func markMermaidSectionsFailed(in webView: WKWebView, message: String) async {
            do {
                _ = try await webView.callAsyncJavaScript(
                    """
                    if (typeof window.starcatFailMermaidSections === 'function') {
                        window.starcatFailMermaidSections(message);
                    }
                    """,
                    arguments: ["message": message],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                AppLog.ui.debug(
                    "README Mermaid fallback could not update DOM: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        private enum MermaidRuntimeError: LocalizedError {
            case resourceMissing

            var errorDescription: String? {
                switch self {
                case .resourceMissing:
                    "Bundled Mermaid \(ReadmeWebView.mermaidRendererVersion) resource is missing"
                }
            }
        }

        fileprivate static let readmeEnhancementScript = """
        (function() {
            var lastY = -1;
            var lastOverflow = -1;
            var ticking = false;
            var previewOverlay = null;
            var previewRemoveTimer = null;

            function currentY() {
                return window.scrollY ||
                    document.documentElement.scrollTop ||
                    document.body.scrollTop ||
                    0;
            }

            function currentOverflow() {
                var scrollHeight = Math.max(
                    document.documentElement.scrollHeight || 0,
                    document.body.scrollHeight || 0
                );
                var clientHeight = window.innerHeight ||
                    document.documentElement.clientHeight ||
                    0;
                return Math.max(0, scrollHeight - clientHeight);
            }

            function report() {
                ticking = false;
                var y = currentY();
                var overflow = currentOverflow();
                if (Math.abs(y - lastY) < 1 && Math.abs(overflow - lastOverflow) < 1) { return; }
                lastY = y;
                lastOverflow = overflow;
                window.webkit.messageHandlers.\(ReadmeWebViewConstants.scrollMessageName).postMessage({
                    y: y,
                    scrollHeight: overflow + (window.innerHeight || document.documentElement.clientHeight || 0),
                    clientHeight: window.innerHeight || document.documentElement.clientHeight || 0
                });
            }

            function closeImagePreview() {
                if (!previewOverlay) { return; }
                var overlay = previewOverlay;
                previewOverlay = null;
                overlay.classList.remove('readme-image-preview-open');
                window.clearTimeout(previewRemoveTimer);
                previewRemoveTimer = window.setTimeout(function() {
                    if (overlay.parentNode) {
                        overlay.parentNode.removeChild(overlay);
                    }
                }, 180);
            }

            function openImagePreview(image) {
                var src = image.currentSrc || image.src;
                if (!src) { return; }
                closeImagePreview();

                var overlay = document.createElement('div');
                overlay.className = 'readme-image-preview';
                overlay.setAttribute('role', 'button');
                overlay.setAttribute('aria-label', 'Close image preview');

                var previewImage = document.createElement('img');
                previewImage.src = src;
                previewImage.alt = image.alt || '';
                previewImage.decoding = 'async';
                overlay.appendChild(previewImage);

                overlay.addEventListener('click', closeImagePreview);
                document.body.appendChild(overlay);
                previewOverlay = overlay;
                window.requestAnimationFrame(function() {
                    overlay.classList.add('readme-image-preview-open');
                });
            }

            function enhanceImage(image) {
                if (image.dataset.readmeEnhanced === 'true') { return; }
                image.dataset.readmeEnhanced = 'true';
                image.dataset.readmeZoomable = 'true';

                function markLoaded() {
                    image.classList.add('readme-image-loaded');
                }

                if (image.complete && image.naturalWidth > 0) {
                    markLoaded();
                } else {
                    image.addEventListener('load', markLoaded, { once: true });
                }

                image.addEventListener('click', function(event) {
                    event.preventDefault();
                    event.stopPropagation();
                    openImagePreview(image);
                });
            }

            function enhanceImages() {
                document.body.classList.add('readme-js-ready');
                var images = document.querySelectorAll('.markdown-body img');
                for (var index = 0; index < images.length; index += 1) {
                    enhanceImage(images[index]);
                }
            }

            function enhanceVideo(video) {
                if (video.dataset.readmeVideoEnhanced === 'true') { return; }
                video.dataset.readmeVideoEnhanced = 'true';

                // GitHub HTML 通常已经输出 controls，但这里仍强制统一安全策略：
                // autoplay 由页面内容控制，不应绕过 Starcat 的用户手势播放约束。
                video.removeAttribute('autoplay');
                video.autoplay = false;
                video.controls = true;
                video.preload = 'metadata';
                video.setAttribute('playsinline', '');
            }

            function enhanceVideos() {
                var videos = document.querySelectorAll('.markdown-body video');
                for (var index = 0; index < videos.length; index += 1) {
                    enhanceVideo(videos[index]);
                }
            }

            function mermaidSections() {
                return Array.prototype.slice.call(
                    document.querySelectorAll('section[data-type="mermaid"]'),
                    0,
                    \(ReadmeWebViewConstants.maximumMermaidSectionCount)
                );
            }

            function mermaidSource(section) {
                var target = section.querySelector('.js-render-enrichment-target') || section;
                // GitHub 的 data-json 为了嵌入 HTML attribute 会把 Mermaid 自身实体再
                // 转义一层，例如 `->>` 变成 `-&amp;gt;&amp;gt;`。DOM 解开外层后，
                // JSON.parse 得到的仍是 `-&gt;&gt;`，会被 Mermaid 当作语法错误。
                // data-plain / raw pre 都是浏览器已正确解码的原文，因此必须优先使用。
                var plain = target.getAttribute('data-plain');
                if (typeof plain === 'string' && plain.length > 0) {
                    return plain;
                }
                var raw = target.querySelector('pre[lang="mermaid"], pre');
                if (raw && raw.textContent) {
                    return raw.textContent;
                }

                var json = target.getAttribute('data-json');
                if (!json) { return ''; }
                try {
                    var payload = JSON.parse(json);
                    if (!payload || typeof payload.data !== 'string') { return ''; }
                    // 只有 data-plain 与 raw pre 都缺失时才走旧 JSON 回退。这里仅解码
                    // Mermaid 语法需要的安全字符，不通过 innerHTML 解析不可信 README。
                    return payload.data
                        .replace(/&quot;/gi, '"')
                        .replace(/&#(?:39|x27);/gi, "'")
                        .replace(/&lt;/gi, '<')
                        .replace(/&#(?:60|x3c);/gi, '<')
                        .replace(/&gt;/gi, '>')
                        .replace(/&#(?:62|x3e);/gi, '>')
                        .replace(/&amp;/gi, '&');
                } catch (_) {
                    return '';
                }
            }

            function mermaidSandboxIntrinsicSize(iframe) {
                var source = iframe.getAttribute('src') || '';
                var delimiterIndex = source.indexOf(',');
                if (source.indexOf('data:text/html') !== 0 || delimiterIndex < 0) {
                    return null;
                }

                try {
                    var metadata = source.slice(0, delimiterIndex);
                    var payload = source.slice(delimiterIndex + 1);
                    var markup = /;base64/i.test(metadata)
                        ? window.atob(payload)
                        : decodeURIComponent(payload);
                    // Mermaid 11 sandbox 返回 data URL iframe。这里仅在 inert DOM 中读取
                    // 本地运行时生成的 SVG viewBox，不执行或回填其中的任何 HTML。
                    var parsed = new DOMParser().parseFromString(markup, 'text/html');
                    var svg = parsed.querySelector('svg[viewBox]');
                    if (!svg) { return null; }

                    var values = svg.getAttribute('viewBox').trim().split(/[\\s,]+/);
                    if (values.length !== 4) { return null; }
                    var width = Number(values[2]);
                    var height = Number(values[3]);
                    if (!Number.isFinite(width) || !Number.isFinite(height) ||
                        width <= 0 || height <= 0) {
                        return null;
                    }
                    return { width: width, height: height };
                } catch (_) {
                    return null;
                }
            }

            function makeMermaidSandboxResponsive(rendered) {
                var iframe = rendered.querySelector(':scope > iframe');
                if (!iframe) { return; }

                var size = mermaidSandboxIntrinsicSize(iframe);
                if (!size) { return; }

                // Mermaid 把 SVG 原始高度写成 iframe 固定像素高度；窄详情栏中 SVG 会
                // 等比缩小，但 iframe 不会，因而在图表下方留下大块空白。用 viewBox
                // 建立原始宽高比后，WebKit 会随容器宽度自动调整，无需额外 resize 监听。
                iframe.style.width = '100%';
                iframe.style.maxWidth = size.width + 'px';
                iframe.style.height = 'auto';
                iframe.style.aspectRatio = size.width + ' / ' + size.height;
                iframe.removeAttribute('height');
            }

            function cleanupMermaidRenderArtifacts(renderID) {
                // Mermaid 11 sandbox 模式解析失败时会把临时 iframe `i<renderID>`
                // 留在 document.body。它虽然不在正文位置，却仍进入可访问性树并显示
                // “Syntax error in text”；失败回退前必须显式清理。
                var temporaryIDs = [renderID, 'i' + renderID, 'd' + renderID];
                for (var index = 0; index < temporaryIDs.length; index += 1) {
                    var node = document.getElementById(temporaryIDs[index]);
                    if (node) { node.remove(); }
                }
            }

            function setMermaidFailure(section, message) {
                section.dataset.starcatMermaidState = 'failed';
                var loader = section.querySelector('.js-render-enrichment-loader');
                if (loader) { loader.hidden = true; }

                var raw = section.querySelector('.render-plaintext-hidden');
                if (raw) { raw.hidden = false; }

                var existing = section.querySelector('.starcat-mermaid-error');
                if (!existing) {
                    existing = document.createElement('div');
                    existing.className = 'starcat-mermaid-error';
                    section.appendChild(existing);
                }
                existing.textContent = message;
            }

            window.starcatFailMermaidSections = function(message) {
                var sections = mermaidSections();
                for (var index = 0; index < sections.length; index += 1) {
                    if (sections[index].dataset.starcatMermaidState !== 'ready') {
                        setMermaidFailure(sections[index], message);
                    }
                }
                schedule();
            };

            window.starcatRenderMermaidSections = async function(failureMessage) {
                var sections = mermaidSections();
                if (!window.mermaid || typeof window.mermaid.render !== 'function') {
                    window.starcatFailMermaidSections(failureMessage);
                    return 0;
                }

                if (!window.starcatMermaidInitialized) {
                    window.mermaid.initialize({
                        startOnLoad: false,
                        securityLevel: 'sandbox',
                        theme: document.body.classList.contains('dark') ? 'dark' : 'default',
                        maxTextSize: \(ReadmeWebViewConstants.maximumMermaidSourceLength)
                    });
                    window.starcatMermaidInitialized = true;
                }

                var renderedCount = 0;
                for (var index = 0; index < sections.length; index += 1) {
                    var section = sections[index];
                    if (section.dataset.starcatMermaidState === 'ready') { continue; }

                    var source = mermaidSource(section).trim();
                    if (source.length === 0 ||
                        source.length > \(ReadmeWebViewConstants.maximumMermaidSourceLength)) {
                        setMermaidFailure(section, failureMessage);
                        continue;
                    }

                    section.dataset.starcatMermaidState = 'loading';
                    var renderID = 'starcat-mermaid-' + Date.now() + '-' + index;
                    try {
                        // 逐张 await，避免 Mermaid 的全局临时节点在并发 render 时互相覆盖。
                        var result = await window.mermaid.render(
                            renderID,
                            source
                        );
                        var target = section.querySelector('.js-render-enrichment-target') || section;
                        var existing = target.querySelector(':scope > .starcat-mermaid-rendered');
                        if (existing) { existing.remove(); }

                        var rendered = document.createElement('div');
                        rendered.className = 'starcat-mermaid-rendered';
                        rendered.innerHTML = result.svg;
                        target.insertBefore(rendered, target.firstChild);
                        makeMermaidSandboxResponsive(rendered);
                        if (typeof result.bindFunctions === 'function') {
                            result.bindFunctions(rendered);
                        }

                        var raw = target.querySelector('.render-plaintext-hidden');
                        if (raw) { raw.hidden = true; }
                        var loader = section.querySelector('.js-render-enrichment-loader');
                        if (loader) { loader.hidden = true; }
                        var errorNode = section.querySelector('.starcat-mermaid-error');
                        if (errorNode) { errorNode.remove(); }
                        section.dataset.starcatMermaidState = 'ready';
                        renderedCount += 1;
                    } catch (_) {
                        cleanupMermaidRenderArtifacts(renderID);
                        setMermaidFailure(section, failureMessage);
                    }
                }
                schedule();
                return renderedCount;
            };

            function requestMermaidRendering() {
                var sections = mermaidSections();
                if (sections.length === 0 || window.starcatMermaidRuntimeRequested) { return; }
                window.starcatMermaidRuntimeRequested = true;
                window.webkit.messageHandlers.\(ReadmeWebViewConstants.mermaidRequestMessageName)
                    .postMessage({ count: sections.length });
            }

            function normalizedSegmentText(element) {
                var clone = element.cloneNode(true);

                // 父块和子块分别翻译，先从父块副本移除后代候选，避免同一句重复发送。
                var nestedBlocks = clone.querySelectorAll(
                    'h1, h2, h3, h4, h5, h6, p, li, blockquote, td, th, summary, dt, dd'
                );
                for (var nestedIndex = 0; nestedIndex < nestedBlocks.length; nestedIndex += 1) {
                    nestedBlocks[nestedIndex].remove();
                }

                var excluded = clone.querySelectorAll('pre, script, style, svg, noscript');
                for (var excludedIndex = 0; excludedIndex < excluded.length; excludedIndex += 1) {
                    excluded[excludedIndex].remove();
                }

                // 双语译文是纯文本；用反引号标记内联代码，提醒模型按字面量保留。
                var literals = clone.querySelectorAll('code, kbd, samp');
                for (var literalIndex = 0; literalIndex < literals.length; literalIndex += 1) {
                    var literal = literals[literalIndex];
                    literal.replaceWith(document.createTextNode('`' + (literal.textContent || '') + '`'));
                }

                return (clone.textContent || '').replace(/\\s+/g, ' ').trim();
            }

            function extractTranslationSource() {
                var article = document.querySelector('.markdown-body article') ||
                    document.querySelector('.markdown-body');
                if (!article) { return; }

                // 新文档重抽段：上一份 README 的入场去重表必须丢掉。
                window.starcatReadmeAnimatedTranslationIDs = {};

                var candidates = article.querySelectorAll(
                    'h1, h2, h3, h4, h5, h6, p, li, blockquote, td, th, summary, dt, dd'
                );
                var segments = [];
                window.starcatReadmeSegmentElements = {};
                for (var index = 0; index < candidates.length; index += 1) {
                    var element = candidates[index];
                    if (element.closest('pre, code, kbd, samp, script, style, svg, noscript')) {
                        continue;
                    }
                    var text = normalizedSegmentText(element);
                    if (text.length < 2 || /^https?:\\/\\/\\S+$/.test(text)) {
                        continue;
                    }
                    var id = 'starcat-readme-segment-' + segments.length;
                    element.dataset.starcatTranslationSource = 'true';
                    element.dataset.starcatTranslationId = id;
                    window.starcatReadmeSegmentElements[id] = element;
                    segments.push({ id: id, text: text });
                }

                // 全文模式按 Text node 替换译文，而不是覆盖 element.innerHTML。
                // 这样 inline link、图片、属性和代码节点始终由原 DOM 持有；切回原文时
                // 只需恢复 nodeValue，不需要重载整份 README。
                var fullTextNodes = [];
                window.starcatReadmeFullTextNodes = {};
                var walker = document.createTreeWalker(
                    article,
                    NodeFilter.SHOW_TEXT,
                    {
                        acceptNode: function(node) {
                            var parent = node.parentElement;
                            if (!parent || parent.closest(
                                'pre, code, kbd, samp, script, style, svg, noscript, .starcat-readme-translation'
                            )) {
                                return NodeFilter.FILTER_REJECT;
                            }
                            var text = (node.nodeValue || '').trim();
                            if (text.length < 2 || /^https?:\\/\\/\\S+$/.test(text)) {
                                return NodeFilter.FILTER_REJECT;
                            }
                            return NodeFilter.FILTER_ACCEPT;
                        }
                    }
                );
                var textNode = walker.nextNode();
                while (textNode) {
                    var fullID = 'starcat-readme-text-' + fullTextNodes.length;
                    var original = textNode.nodeValue || '';
                    window.starcatReadmeFullTextNodes[fullID] = {
                        node: textNode,
                        original: original
                    };
                    fullTextNodes.push({ id: fullID, text: original.trim() });
                    textNode = walker.nextNode();
                }

                window.webkit.messageHandlers.\(ReadmeWebViewConstants.translationSourceMessageName)
                    .postMessage({
                        segmented: segments,
                        full: fullTextNodes
                    });
            }

            function restoreFullTranslationTextNodes() {
                var nodes = window.starcatReadmeFullTextNodes || {};
                Object.keys(nodes).forEach(function(id) {
                    var entry = nodes[id];
                    if (entry && entry.node) {
                        entry.node.nodeValue = entry.original;
                    }
                    if (entry && entry.wrapper) {
                        entry.wrapper.classList.remove('is-crossfading');
                    }
                });
            }

            function hideSegmentedTranslations() {
                var existing = document.querySelectorAll('.starcat-readme-translation');
                for (var index = 0; index < existing.length; index += 1) {
                    existing[index].hidden = true;
                    existing[index].classList.remove('is-entering');
                }
            }

            function hasAnimatedTranslation(id) {
                return !!(window.starcatReadmeAnimatedTranslationIDs &&
                    window.starcatReadmeAnimatedTranslationIDs[id]);
            }

            function markAnimatedTranslation(id) {
                window.starcatReadmeAnimatedTranslationIDs =
                    window.starcatReadmeAnimatedTranslationIDs || {};
                window.starcatReadmeAnimatedTranslationIDs[id] = true;
            }

            function ensureFullTranslationWrapper(entry) {
                if (entry.wrapper && entry.wrapper.isConnected) {
                    return entry.wrapper;
                }
                var node = entry.node;
                if (!node || !node.parentNode) { return null; }
                var span = document.createElement('span');
                span.className = 'starcat-readme-full-target';
                node.parentNode.insertBefore(span, node);
                span.appendChild(node);
                entry.wrapper = span;
                return span;
            }

            function playSegmentedEntrance(element, id, animate) {
                if (hasAnimatedTranslation(id)) { return; }
                if (animate) {
                    // 强制重排后再加 class，避免刚插入的节点吃不到 animationstart。
                    void element.offsetWidth;
                    element.classList.add('is-entering');
                }
                markAnimatedTranslation(id);
            }

            function playFullCrossfade(wrapper, id, animate) {
                if (!wrapper || hasAnimatedTranslation(id)) { return; }
                if (animate) {
                    void wrapper.offsetWidth;
                    wrapper.classList.add('is-crossfading');
                }
                markAnimatedTranslation(id);
            }

            window.starcatApplyReadmeTranslations = function(mode, isVisible, translations, animate) {
                // 每次先回到原始 Text node，再应用当前模式，避免全文/分段切换时残留旧 DOM。
                restoreFullTranslationTextNodes();
                if (!isVisible) {
                    hideSegmentedTranslations();
                    schedule();
                    return;
                }

                if (mode === 'full') {
                    hideSegmentedTranslations();
                    var fullNodes = window.starcatReadmeFullTextNodes || {};
                    for (var fullIndex = 0; fullIndex < translations.length; fullIndex += 1) {
                        var fullItem = translations[fullIndex];
                        var entry = fullNodes[fullItem.id];
                        if (!entry || !entry.node) { continue; }

                        // AI 只翻译 trim 后的正文；原节点首尾空白必须保留，否则 inline
                        // element 之间会粘连（例如 "with <a>React</a> and"）。
                        var original = entry.original || '';
                        var leading = (original.match(/^\\s*/) || [''])[0];
                        var trailing = (original.match(/\\s*$/) || [''])[0];
                        var nextValue = leading + fullItem.translation.trim() + trailing;
                        var wrapper = ensureFullTranslationWrapper(entry);
                        playFullCrossfade(wrapper, fullItem.id, !!animate);
                        entry.node.nodeValue = nextValue;
                    }
                    schedule();
                    return;
                }

                var expected = new Set();
                for (var index = 0; index < translations.length; index += 1) {
                    var item = translations[index];
                    expected.add(item.id);
                    var source = window.starcatReadmeSegmentElements
                        ? window.starcatReadmeSegmentElements[item.id]
                        : null;
                    if (!source) { continue; }

                    var translated = source.querySelector(':scope > .starcat-readme-translation');
                    if (!translated) {
                        translated = document.createElement('span');
                        translated.className = 'starcat-readme-translation';
                        translated.setAttribute('aria-label', 'Translation');
                        source.appendChild(translated);
                    }
                    translated.textContent = item.translation;
                    translated.hidden = !isVisible;
                    playSegmentedEntrance(translated, item.id, !!animate);
                }

                var existing = document.querySelectorAll('.starcat-readme-translation');
                for (var existingIndex = 0; existingIndex < existing.length; existingIndex += 1) {
                    var node = existing[existingIndex];
                    var parentID = node.parentElement
                        ? (node.parentElement.dataset.starcatTranslationId || '')
                        : '';
                    if (!expected.has(parentID)) {
                        node.remove();
                    } else {
                        node.hidden = !isVisible;
                    }
                }
                schedule();
            };

            function schedule() {
                if (ticking) { return; }
                ticking = true;
                window.requestAnimationFrame(report);
            }

            function scheduleAfterScroll() {
                closeImagePreview();
                schedule();
            }

            window.addEventListener('scroll', scheduleAfterScroll, { passive: true });
            window.addEventListener('resize', schedule, { passive: true });
            window.addEventListener('keydown', function(event) {
                if (event.key === 'Escape') {
                    closeImagePreview();
                }
            });
            window.addEventListener('load', report);
            enhanceImages();
            enhanceVideos();
            extractTranslationSource();
            requestMermaidRendering();
            setTimeout(report, 0);
        })();
        """

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == ReadmeWebViewConstants.mermaidRequestMessageName {
                guard let payload = message.body as? [String: Any],
                      let count = payload["count"] as? NSNumber
                else { return }
                loadMermaidRuntimeIfNeeded(sectionCount: count.intValue)
                return
            }

            if message.name == ReadmeWebViewConstants.translationSourceMessageName {
                guard let payload = message.body as? [String: Any] else { return }

                func decodeSegments(
                    key: String,
                    idPrefix: String,
                    limit: Int
                ) -> [ReadmeSourceSegment] {
                    guard let items = payload[key] as? [[String: Any]] else { return [] }
                    return items.prefix(limit).compactMap { item -> ReadmeSourceSegment? in
                    guard let id = item["id"] as? String,
                          let text = item["text"] as? String,
                          id.hasPrefix(idPrefix),
                          !text.isEmpty,
                          text.count <= 20_000
                    else { return nil }
                    return ReadmeSourceSegment(id: id, text: text)
                }
                }

                let snapshot = ReadmeTranslationSourceSnapshot(
                    segmented: decodeSegments(
                        key: "segmented",
                        idPrefix: "starcat-readme-segment-",
                        limit: 2_000
                    ),
                    full: decodeSegments(
                        key: "full",
                        idPrefix: "starcat-readme-text-",
                        limit: 8_000
                    )
                )
                Task { @MainActor in
                    self.onTranslationSourceChange(snapshot)
                }
                return
            }

            guard message.name == ReadmeWebViewConstants.scrollMessageName,
                  let payload = message.body as? [String: Any],
                  let yValue = payload["y"] as? NSNumber
            else { return }
            do {
                let scrollHeight = (payload["scrollHeight"] as? NSNumber).map { CGFloat(truncating: $0) }
                let clientHeight = (payload["clientHeight"] as? NSNumber).map { CGFloat(truncating: $0) }
                let overflow: CGFloat?
                if let scrollHeight, let clientHeight {
                    overflow = max(0, scrollHeight - clientHeight)
                } else {
                    overflow = nil
                }
                let report = RepoDetailScrollReport(
                    offsetY: CGFloat(truncating: yValue),
                    scrollOverflow: overflow
                )
                // 避免在 WebKit 回调栈内同步触发 SwiftUI 重排，干扰 loadHTMLString 首帧。
                Task { @MainActor in
                    self.onScrollReportChange(report)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            PerformanceTracer.shared.mark(.readmeWebViewNavigationFinished)
            // `updateNSView` 可能先于 document-end script 完成；导航结束后再补一次当前状态。
            lastAppliedTranslationRevision = nil
            applyTranslationRenderStateIfNeeded()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // 1. 用户点链接 → 一律转系统浏览器
            //
            // 历史 bug：之前默认策略是 `.cancel`，导致 `loadHTMLString(_, baseURL: repo.htmlUrl)`
            // 触发的主框架首次导航（url == baseURL，navigationType == .other）也被 cancel，
            // WebView 直接白屏。修复后改为「除 linkActivated 外有条件允许」。
            if navigationAction.navigationType == .linkActivated {
                if openRepositoryMarkdownIfNeeded(
                    url: url,
                    modifierFlags: navigationAction.modifierFlags
                ) {
                    decisionHandler(.cancel)
                    return
                }
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            // 2. 主框架导航管控
            //
            // 现象：`loadHTMLString(_, baseURL: repo.htmlUrl)` 会把 WebView 的 URL 字段
            // 设为 baseURL（=repo 的 GitHub 页面）。用户在 WebView 上右键 → 重新加载
            // 会触发 `webView.reload()` → 发起对 baseURL 的真实网络请求，整个 GitHub
            // 仓库页面被拉进 README 区域。
            //
            // 修复：只放行 expectsInitialLoad 标记的那一次（loadHTMLString 触发），
            // 后续所有主框架导航一律 cancel。"真正的刷新" 由底栏"刷新"按钮调
            // `ReadmeViewModel.reload()` 走 ETag 缓存路径，由 SwiftUI 重建 view
            // 时再走一遍 loadHTMLString。
            //
            // about: scheme（about:blank 等 WebView 初始化噪音）无条件放行，
            // 不消耗 expectsInitialLoad 标志。
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
            if isMainFrame {
                if url.scheme == "about" {
                    decisionHandler(.allow)
                    return
                }
                if expectsInitialLoad {
                    expectsInitialLoad = false
                    decisionHandler(.allow)
                    return
                }
                AppLog.ui.debug("ReadmeWebView blocked main-frame navigation: \(url.absoluteString, privacy: .public) type=\(String(describing: navigationAction.navigationType), privacy: .public)")
                decisionHandler(.cancel)
                return
            }

            // 3. 非主框架（iframe 等）：放行
            decisionHandler(.allow)
        }

        /// 设置打开且不是 ⌘-点击时，把同仓 Markdown 交给独立窗。
        ///
        /// ⌘-点击故意保留浏览器逃生口，避免偶发误拦。开关关闭时本方法直接 false，
        /// 行为与改之前完全一致。
        private func openRepositoryMarkdownIfNeeded(
            url: URL,
            modifierFlags: NSEvent.ModifierFlags
        ) -> Bool {
            guard openRepositoryMarkdownInApp else { return false }
            guard !modifierFlags.contains(.command) else { return false }
            guard let owner = markdownLinkRepositoryOwner,
                  let repo = markdownLinkRepositoryName,
                  let onOpen = onOpenRepositoryMarkdown
            else { return false }
            guard let target = RepositoryMarkdownLink.classify(url, owner: owner, repo: repo) else {
                return false
            }
            onOpen(target)
            return true
        }

        // 渲染失败日志，方便后续排查（沙箱、CSS、HTML 片段异常都会落在这里）
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            AppLog.ui.error("ReadmeWebView didFail: \(error.localizedDescription, privacy: .public)")
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            AppLog.ui.error("ReadmeWebView didFailProvisional: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum ReadmeWebViewConstants {
    static let scrollMessageName = "readmeScroll"
    static let translationSourceMessageName = "readmeTranslationSource"
    static let mermaidRequestMessageName = "readmeMermaidRequest"
    static let maximumMermaidSectionCount = 100
    static let maximumMermaidSourceLength = 50_000
}

/// GitHub 的 Mermaid enrichment HTML 默认等待 Viewscreen iframe 回填；Starcat 不加载
/// GitHub 页面脚本，因此在原位置提供本地加载态、沙箱 iframe 与失败时 raw code 回退样式。
private enum ReadmeMermaidDOM {
    static let css = """
    .markdown-body section[data-type="mermaid"] {
        min-width: 0;
        margin: 0 0 16px;
    }
    .markdown-body section[data-type="mermaid"] .render-plaintext-hidden {
        display: none;
    }
    .markdown-body section[data-type="mermaid"][data-starcat-mermaid-state="failed"]
        .render-plaintext-hidden {
        display: block;
    }
    .markdown-body .js-render-enrichment-loader {
        display: flex;
        align-items: center;
        gap: 8px;
        min-height: 36px;
        color: var(--muted);
    }
    .markdown-body .js-render-enrichment-loader[hidden] {
        display: none;
    }
    .markdown-body .js-render-enrichment-loader .octospinner {
        width: 20px;
        height: 20px;
        color: var(--muted);
    }
    .markdown-body .js-render-enrichment-loader .anim-rotate {
        animation: starcat-mermaid-spin 1s linear infinite;
    }
    .markdown-body .sr-only {
        position: absolute;
        width: 1px;
        height: 1px;
        padding: 0;
        margin: -1px;
        overflow: hidden;
        clip: rect(0, 0, 0, 0);
        white-space: nowrap;
        border: 0;
    }
    .markdown-body .starcat-mermaid-rendered {
        width: 100%;
        max-width: 100%;
        overflow-x: auto;
    }
    .markdown-body .starcat-mermaid-rendered iframe {
        display: block;
        width: 100%;
        max-width: 100%;
        border: 0;
        background: transparent;
    }
    .markdown-body .starcat-mermaid-error {
        margin-top: 8px;
        color: var(--muted);
        font-size: 0.88em;
    }
    @keyframes starcat-mermaid-spin {
        to { transform: rotate(360deg); }
    }
    @media (prefers-reduced-motion: reduce) {
        .markdown-body .js-render-enrichment-loader .anim-rotate {
            animation: none;
        }
    }
    """
}

/// 双语译文只作为原文块的次级说明，不改变原 README 的字号层级和链接结构。
private enum ReadmeTranslationDOM {
    static let css = """
    .starcat-readme-translation {
        display: block;
        margin: 0.42em 0 0.18em;
        padding: 0.28em 0 0.28em 0.72em;
        border-left: 2px solid color-mix(in srgb, var(--color-accent-fg) 45%, transparent);
        color: var(--fgColor-muted, #656d76);
        font-size: 0.92em;
        font-weight: 400;
        line-height: 1.58;
        white-space: pre-wrap;
    }
    .dark .starcat-readme-translation {
        color: var(--fgColor-muted, #8b949e);
    }
    .starcat-readme-translation[hidden] {
        display: none;
    }
    /* 分段：新译文第一次出现时 fade + 轻微上移。同一段再次显示不加重播。 */
    .starcat-readme-translation.is-entering {
        animation: starcat-readme-segment-enter 180ms ease-out both;
    }
    /* 全文：同位置替换，只做短淡入，模拟 crossfade，禁止位移以免正文晃。 */
    .starcat-readme-full-target.is-crossfading {
        animation: starcat-readme-full-crossfade 160ms ease-out both;
    }
    @keyframes starcat-readme-segment-enter {
        from { opacity: 0; transform: translateY(6px); }
        to { opacity: 1; transform: translateY(0); }
    }
    @keyframes starcat-readme-full-crossfade {
        from { opacity: 0; }
        to { opacity: 1; }
    }
    @media (prefers-reduced-motion: reduce) {
        .starcat-readme-translation.is-entering,
        .starcat-readme-full-target.is-crossfading {
            animation: none;
        }
    }
    """
}

private struct ReadmeFindBar: View {
    @Binding var query: String
    var hasMatch: Bool?
    var isFindFieldFocused: FocusState<Bool>.Binding
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("readme.find.placeholder", text: $query)
                .textFieldStyle(.plain)
                .focused(isFindFieldFocused)
                .onSubmit(onNext)
            if let hasMatch, !query.isEmpty, !hasMatch {
                Text("readme.find.noMatch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            findStepButton(
                systemImage: "chevron.up",
                helpKey: "readme.find.previous",
                action: onPrevious
            )
            findStepButton(
                systemImage: "chevron.down",
                helpKey: "readme.find.next",
                action: onNext
            )
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("readme.find.close")
            .accessibilityLabel(Text("readme.find.close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // 不能顶满详情栏铺一条矩形：宿主顶部是圆角，材质会跟着切圆，底边却仍是直角。
        // 四角同一套 continuous 圆角，并与字号浮窗留白对齐。
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.09), radius: 8, x: 0, y: 4)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .onExitCommand(perform: onClose)
        .onAppear {
            isFindFieldFocused.wrappedValue = true
        }
    }

    private func findStepButton(
        systemImage: String,
        helpKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(query.isEmpty ? Color.secondary.opacity(0.38) : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(query.isEmpty)
        .help(helpKey)
        .accessibilityLabel(Text(helpKey))
    }
}

private struct ReadmeFloatingToolbar: View {
    let fontSizeAdjustment: Int
    let isExpanded: Bool
    let toggleExpanded: () -> Void
    let decreaseFontSize: () -> Void
    let resetFontSize: () -> Void
    let increaseFontSize: () -> Void

    /// 「在新窗口打开 README」回调。nil 时隐藏该按钮（独立窗口不提供此操作）。
    let openInNewWindow: (() -> Void)?

    /// 「导出 README Markdown」回调。nil 时隐藏该按钮。
    let onExportMarkdown: (() -> Void)?

    /// 鼠标是否悬停在浮窗上。
    ///
    /// dong4j 2026-07-04：浮窗默认占用 README 阅读区右下角，长期 100% 不透明会与正文抢戏。
    /// 在「hover / 展开 / 用户已调整过字号」三种状态下保持 100%，其余降到 45%，
    /// 既不抢阅读视线，也保证在意这个工具的用户能稳定看到反馈。
    @State private var isHovering = false

    private var canDecrease: Bool {
        fontSizeAdjustment > AppSettings.readmeFontSizeAdjustmentRange.lowerBound
    }

    private var canIncrease: Bool {
        fontSizeAdjustment < AppSettings.readmeFontSizeAdjustmentRange.upperBound
    }

    private var isIdle: Bool {
        !isHovering && !isExpanded && fontSizeAdjustment == 0
    }

    var body: some View {
        VStack(spacing: 5) {
            if isExpanded {
                toolbarButton(
                    systemImage: "textformat.size.smaller",
                    helpKey: "readme.toolbar.fontSmaller",
                    isDisabled: !canDecrease,
                    action: decreaseFontSize
                )
                toolbarButton(
                    systemImage: "textformat.size",
                    helpKey: "readme.toolbar.fontReset",
                    isDisabled: fontSizeAdjustment == 0,
                    action: resetFontSize
                )
                toolbarButton(
                    systemImage: "textformat.size.larger",
                    helpKey: "readme.toolbar.fontLarger",
                    isDisabled: !canIncrease,
                    action: increaseFontSize
                )
                Divider()
                    .frame(width: 16)
                    .padding(.vertical, 1)
                    .transition(.opacity)
                if let onExportMarkdown {
                    toolbarButton(
                        systemImage: "arrow.down.doc",
                        helpKey: "readme.toolbar.exportMarkdown",
                        isDisabled: false,
                        assetImage: "markdown",
                        action: onExportMarkdown
                    )
                    Divider()
                        .frame(width: 16)
                        .padding(.vertical, 1)
                        .transition(.opacity)
                }
                if let openInNewWindow {
                    toolbarButton(
                        systemImage: "rectangle.on.rectangle",
                        helpKey: "readme.toolbar.openInNewWindow",
                        isDisabled: false,
                        action: openInNewWindow
                    )
                    Divider()
                        .frame(width: 16)
                        .padding(.vertical, 1)
                        .transition(.opacity)
                }
            }
            toolbarButton(
                systemImage: "gearshape",
                helpKey: "readme.toolbar.fontMenu",
                isDisabled: false,
                isActive: isExpanded || fontSizeAdjustment != 0,
                action: toggleExpanded
            )
        }
        .padding(isExpanded ? 4 : 3)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: isExpanded ? 12 : 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isExpanded ? 12 : 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.09), radius: 8, x: 0, y: 4)
        .animation(.easeInOut(duration: 0.16), value: isExpanded)
        // idle 变淡：避免常驻浮窗与 README 正文抢视线；hover / 展开 / 已调过字号 时保持不淡。
        .opacity(isIdle ? 0.45 : 1.0)
        .animation(.easeInOut(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
    }

    private func toolbarButton(
        systemImage: String,
        helpKey: LocalizedStringKey,
        isDisabled: Bool,
        isActive: Bool = false,
        assetImage: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let assetImage {
                Image(assetImage)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(isDisabled ? Color.secondary.opacity(0.38) : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isDisabled ? Color.secondary.opacity(0.38) : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(isDisabled)
        .help(helpKey)
        .accessibilityLabel(Text(helpKey))
    }
}

private struct ReadmeBackToTopButton: View {
    let action: () -> Void

    /// 右下角浮动按钮常驻在阅读区，默认弱化；只有鼠标指向时才完整显示，避免压住 README 正文。
    @State private var isHovering = false
    @State private var bounceToken = 0

    var body: some View {
        Button {
            bounceToken &+= 1
            action()
        } label: {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 30, height: 30)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.16), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .symbolEffect(.bounce, value: bounceToken)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("readme.toolbar.backToTop")
        .accessibilityLabel(Text("readme.toolbar.backToTop"))
        .shadow(color: Color.black.opacity(0.09), radius: 8, x: 0, y: 4)
        .opacity(isHovering ? 1.0 : 0.45)
        .animation(.easeInOut(duration: 0.18), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private extension NSView {
    /// 在 WebKit 这类内部视图层级里查找标准 AppKit 子视图。
    ///
    /// 只按公开类型递归，不匹配私有 class name；这样即使 WebKit 内部层级微调，
    /// 找不到时也只是保持系统默认滚动条，不会影响 README 正文渲染。
    func firstDescendant<ViewType: NSView>(ofType type: ViewType.Type) -> ViewType? {
        for subview in subviews {
            if let match = subview as? ViewType {
                return match
            }
            if let match = subview.firstDescendant(ofType: type) {
                return match
            }
        }
        return nil
    }
}

/// README 页内查找请求。generation 变化才真正执行，避免 SwiftUI 每帧重复 find。
struct ReadmeFindRequest: Equatable {
    var query = ""
    var generation: UInt64 = 0
    var backwards = false
}

/// 缓存键：轻量文档身份 + base URL + 主题，用于判断是否需要重新 loadHTMLString。
///
/// 字号调整不在此键中：字号变化时通过 JS 动态更新 CSS 变量 `--readme-body-font-size`，
/// 避免 `loadHTMLString` 重载触发 scroll 事件导致字号面板意外关闭。
struct ReadmeKey: Equatable {
    let documentID: String
    let baseURL: URL?
    let isDark: Bool
    let interfaceScale: InterfaceScale
}

// MARK: - GFM CSS

/// 内嵌 GFM 主题 CSS（精简版）。
///
/// 设计：
/// - 完全离线（不引用任何 CDN）
/// - 同时定义亮/暗变量，通过 body.dark 切换
/// - 与 GitHub 渲染好的 HTML 类名对齐（.markdown-body / .highlight / .anchor 等）
/// - 字体大小、行距与 GitHub 网页保持相近，方便用户上下文切换
/// - 暗色 `--code-bg` / `--border` 用半透明白相对系统窗底抬升，不用 GitHub 画布色
enum ReadmeCSS {
    static let full: String = """
    :root {
        --bg: #ffffff;
        --fg: #1f2328;
        --muted: #59636e;
        --link: #0969da;
        --border: #d0d7de;
        --code-bg: #f6f8fa;
        --blockquote-fg: #59636e;
        --blockquote-border: #d0d7de;
        --image-preview-bg: rgba(246, 248, 250, 0.86);
        --image-preview-shadow: rgba(31, 35, 40, 0.24);
    }
    body.dark {
        --bg: #0d1117;
        --fg: #e6edf3;
        --muted: #8b949e;
        --link: #4493f8;
        /* 相对透明页透出的系统窗底抬升，跟随真实底色（含 Sequoia 偏紫灰），避免 GitHub #161b22 沉成黑坑 */
        --border: rgba(255, 255, 255, 0.14);
        --code-bg: rgba(255, 255, 255, 0.08);
        --blockquote-fg: #8b949e;
        --blockquote-border: rgba(255, 255, 255, 0.14);
        --image-preview-bg: rgba(13, 17, 23, 0.88);
        --image-preview-shadow: rgba(0, 0, 0, 0.42);
    }
    /*
     * 背景刻意设为 transparent：
     * 配合 WKWebView 的 `drawsBackground = false`（见 ReadmeWebView.makeNSView），
     * 让 SwiftUI 宿主（详情页系统暗灰 `NSColor.windowBackgroundColor`）的底色透上来，
     * 避免 README 区与上方元信息卡片之间出现色差（GitHub `#0d1117` ↔ macOS 系统暗灰）。
     * 亮色下系统底色 ≈ 纯白，效果也一致。
     * `--bg` 变量保留给后续可能用到的局部组件，不在此处画背景。
     * 代码块 / 表格线用 `--code-bg` / `--border`；暗色是半透明白，叠在这层透明底上才会相对窗底抬升。
     */
    html, body {
        margin: 0;
        padding: 0;
        background: transparent;
        color: var(--fg);
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Helvetica Neue", Arial, sans-serif;
        font-size: var(--readme-body-font-size, 16px);
        line-height: var(--readme-line-height, 1.62);
        -webkit-text-size-adjust: 100%;
        -webkit-font-smoothing: antialiased;
    }
    article.markdown-body, .markdown-body {
        max-width: 100%;
        padding: 16px 24px 64px 24px;
        word-wrap: break-word;
    }
    /* 标题 */
    .markdown-body h1,
    .markdown-body h2,
    .markdown-body h3,
    .markdown-body h4,
    .markdown-body h5,
    .markdown-body h6 {
        margin-top: 24px;
        margin-bottom: 16px;
        font-weight: 600;
        line-height: 1.25;
    }
    .markdown-body h1 { font-size: 1.8em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
    .markdown-body h2 { font-size: 1.45em; border-bottom: 1px solid var(--border); padding-bottom: 0.3em; }
    .markdown-body h3 { font-size: 1.2em; }
    .markdown-body h4 { font-size: 1.0em; }
    .markdown-body h5 { font-size: 0.9em; }
    .markdown-body h6 { font-size: 0.85em; color: var(--muted); }
    /* 段落 / 列表 */
    .markdown-body p,
    .markdown-body ul,
    .markdown-body ol,
    .markdown-body blockquote,
    .markdown-body table,
    .markdown-body pre {
        margin-top: 0;
        margin-bottom: 16px;
    }
    .markdown-body ul, .markdown-body ol { padding-left: 2em; }
    /* 链接 */
    .markdown-body a { color: var(--link); text-decoration: none; }
    .markdown-body a:hover { text-decoration: underline; }
    /* anchor 链接（GitHub 在标题前生成的不可见 anchor） */
    .markdown-body .anchor { display: none; }
    /* 代码 */
    .markdown-body code, .markdown-body tt {
        padding: 0.2em 0.4em;
        margin: 0;
        font-size: 85%;
        background: var(--code-bg);
        border-radius: 6px;
        font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
    }
    .markdown-body pre {
        padding: 12px 16px;
        overflow: auto;
        background: var(--code-bg);
        border-radius: 6px;
        line-height: 1.45;
    }
    /* GitHub 带语言 fence 会包一层 .highlight；底色只画在外层，避免暗色 rgba 叠两次变黑 */
    .markdown-body .highlight {
        background: var(--code-bg);
        border-radius: 6px;
        overflow: auto;
    }
    .markdown-body .highlight pre {
        background: transparent;
        margin-bottom: 0;
    }
    .markdown-body pre code {
        padding: 0;
        background: transparent;
        border-radius: 0;
        font-size: 100%;
    }
    /* 引用 */
    .markdown-body blockquote {
        padding: 0 1em;
        color: var(--blockquote-fg);
        border-left: 0.25em solid var(--blockquote-border);
    }
    /* 表格 */
    .markdown-body table {
        border-collapse: collapse;
        display: block;
        overflow: auto;
    }
    .markdown-body table th, .markdown-body table td {
        padding: 6px 13px;
        border: 1px solid var(--border);
    }
    .markdown-body table tr:nth-child(2n) { background: var(--code-bg); }
    /* 图片 */
    .markdown-body img {
        max-width: 100%;
        background: transparent;
        border-radius: 4px;
        opacity: 1;
        transition: opacity 180ms ease, filter 180ms ease, transform 180ms ease;
    }
    body.readme-js-ready .markdown-body img[data-readme-zoomable="true"] {
        cursor: zoom-in;
    }
    body.readme-js-ready .markdown-body img:not(.readme-image-loaded) {
        opacity: 0;
        filter: blur(6px);
        transform: translateY(2px);
    }
    body.readme-js-ready .markdown-body img.readme-image-loaded {
        opacity: 1;
        filter: blur(0);
        transform: translateY(0);
    }
    /* 视频使用 WebKit 原生 controls；这里只约束正文布局，不自绘播放器。 */
    .markdown-body video {
        display: block;
        width: auto;
        max-width: 100%;
        height: auto;
        max-height: 640px;
        margin: 0 0 16px;
        background: #000000;
        border-radius: 8px;
        object-fit: contain;
    }
    .readme-image-preview {
        position: fixed;
        inset: 0;
        z-index: 9999;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 24px;
        box-sizing: border-box;
        background: var(--image-preview-bg);
        -webkit-backdrop-filter: blur(10px);
        backdrop-filter: blur(10px);
        opacity: 0;
        cursor: zoom-out;
        transition: opacity 180ms ease;
    }
    .readme-image-preview-open {
        opacity: 1;
    }
    .readme-image-preview img {
        max-width: calc(100vw - 48px);
        max-height: calc(100vh - 48px);
        object-fit: contain;
        border-radius: 8px;
        box-shadow: 0 18px 60px var(--image-preview-shadow);
    }
    @media (prefers-reduced-motion: reduce) {
        .markdown-body img,
        .readme-image-preview {
            transition: none;
        }
    }
    /* 水平线 */
    .markdown-body hr {
        height: 0.25em;
        padding: 0;
        margin: 24px 0;
        background: var(--border);
        border: 0;
    }
    /* 任务列表 */
    .markdown-body .task-list-item { list-style-type: none; }
    .markdown-body .task-list-item input[type=checkbox] {
        margin: 0 0.2em 0.25em -1.4em;
        vertical-align: middle;
    }
    /* GitHub alert（>[!NOTE] 等） */
    .markdown-body .markdown-alert {
        padding: 8px 16px;
        margin-bottom: 16px;
        border-left: 4px solid var(--border);
        background: var(--code-bg);
        border-radius: 4px;
    }
    """

    /// README 文档由 WebKit 渲染，不能直接套 SwiftUI `Font`；这里用 CSS variables
    /// 把 Starcat 的 `InterfaceScale` 注入 GFM 样式，同时保留标题和代码块的 em 层级。
    static func readingVariables(bodyFontSize: CGFloat, lineHeight: CGFloat) -> String {
        """
        :root {
            --readme-body-font-size: \(cssPixels(bodyFontSize));
            --readme-line-height: \(String(format: "%.2f", Double(lineHeight)));
        }
        """
    }

    private static func cssPixels(_ value: CGFloat) -> String {
        String(format: "%.2fpx", Double(value))
    }
}
