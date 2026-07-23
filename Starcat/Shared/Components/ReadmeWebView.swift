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
//     例外：注入一个 app-owned isolated user script，只用于 README 阅读体验增强：
//     滚动上报、图片加载态、图片点击预览；不执行 README 自带脚本。
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

    /// GitHub 返回的 HTML 片段（不含 <html>/<head>/<body>）。
    let htmlFragment: String

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

    /// 当前双语分段渲染状态。默认隐藏，普通 README 调用方无需感知翻译能力。
    var translationRenderState: ReadmeTranslationRenderState = .hidden

    /// WebView 完成 DOM 分段后回传可翻译文本。只在本机内存流转，用户点击翻译后才发给 AI。
    var onTranslationSegmentsChange: ([ReadmeSourceSegment]) -> Void = { _ in }

    @Environment(AppSettings.self) private var settings
    @State private var scrollToTopRequestID = 0
    @State private var isFontToolbarExpanded = false

    var body: some View {
        ReadmeWebContentView(
            htmlFragment: htmlFragment,
            baseURL: baseURL,
            onScrollReportChange: handleScrollReport,
            readmeFontSizeAdjustment: settings.readmeFontSizeAdjustment,
            scrollToTopRequestID: scrollToTopRequestID,
            translationRenderState: translationRenderState,
            onTranslationSegmentsChange: onTranslationSegmentsChange
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func toggleFontToolbar() {
        withAnimation(.easeInOut(duration: 0.16)) {
            isFontToolbarExpanded.toggle()
        }
    }

    private func handleScrollReport(_ report: RepoDetailScrollReport) {
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
    let baseURL: URL?
    var onScrollReportChange: (RepoDetailScrollReport) -> Void
    let readmeFontSizeAdjustment: Int
    let scrollToTopRequestID: Int
    let translationRenderState: ReadmeTranslationRenderState
    var onTranslationSegmentsChange: ([ReadmeSourceSegment]) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var interfaceScale

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // 透明背景，跟随系统主题底色
        configureScrollbar(for: webView)

        context.coordinator.webView = webView
        context.coordinator.onScrollReportChange = onScrollReportChange
        context.coordinator.onTranslationSegmentsChange = onTranslationSegmentsChange
        context.coordinator.updateTranslationRenderState(translationRenderState)
        loadIfNeeded(into: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onScrollReportChange = onScrollReportChange
        context.coordinator.onTranslationSegmentsChange = onTranslationSegmentsChange
        context.coordinator.updateTranslationRenderState(translationRenderState)
        loadIfNeeded(into: webView, context: context)
        scrollToTopIfNeeded(in: webView, context: context)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
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
            fragment: htmlFragment,
            isDark: colorScheme == .dark,
            interfaceScale: interfaceScale
        )

        // 内容或主题变化 → 完整重载 HTML（含初始字号）
        if context.coordinator.lastLoadedKey != contentKey {
            context.coordinator.lastLoadedKey = contentKey
            context.coordinator.lastAppliedFontSizeAdjustment = readmeFontSizeAdjustment
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

    /// 将 GitHub 的 HTML 片段包装为完整文档（带 GFM 主题 CSS）。
    static func assembleDocument(
        fragment: String,
        isDark: Bool,
        interfaceScale: InterfaceScale = .standard,
        readmeFontSizeAdjustment: Int = 0
    ) -> String {
        let css = ReadmeCSS.full + "\n" + ReadmeTranslationDOM.css + "\n" + ReadmeCSS.readingVariables(
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
        <meta http-equiv="Content-Security-Policy" content="script-src 'none'; object-src 'none'; base-uri 'none';">
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
        var onTranslationSegmentsChange: ([ReadmeSourceSegment]) -> Void = { _ in }
        private weak var userContentController: WKUserContentController?
        private var pendingTranslationRenderState: ReadmeTranslationRenderState = .hidden
        private var lastAppliedTranslationRevision: Int?

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
        /// - HTML 文档里加了 CSP `script-src 'none'`，页面自带 `<script>` / inline handler 不执行。
        /// - message handler 对滚动 payload 和段落数组分别做类型、长度校验。
        func makeUserContentController() -> WKUserContentController {
            let controller = WKUserContentController()
            let script = WKUserScript(
                source: Self.readmeEnhancementScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            controller.addUserScript(script)
            controller.add(self, name: ReadmeWebViewConstants.scrollMessageName)
            controller.add(self, name: ReadmeWebViewConstants.translationSegmentsMessageName)
            userContentController = controller
            return controller
        }

        /// Swift 6 下 `deinit` 是非隔离上下文，不能直接调用 MainActor 隔离的
        /// `WKUserContentController.removeScriptMessageHandler`。SwiftUI 拆除 NSView 时会在
        /// 主线程调用 `dismantleNSView`，这里集中做 WebKit handler 清理，避免循环持有。
        func removeScriptMessageHandler() {
            userContentController?.removeScriptMessageHandler(forName: ReadmeWebViewConstants.scrollMessageName)
            userContentController?.removeScriptMessageHandler(
                forName: ReadmeWebViewConstants.translationSegmentsMessageName
            )
            userContentController = nil
        }

        /// 内容或主题重载后，旧 DOM 已消失；导航完成时必须把当前翻译状态重新注入。
        func prepareForDocumentReload() {
            lastAppliedTranslationRevision = nil
        }

        /// 保存最新 SwiftUI 状态，并在当前文档已可用时做无重载 DOM 更新。
        func updateTranslationRenderState(_ state: ReadmeTranslationRenderState) {
            pendingTranslationRenderState = state
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
            lastAppliedTranslationRevision = state.revision
            Task { @MainActor in
                do {
                    _ = try await webView.callAsyncJavaScript(
                        """
                        if (typeof window.starcatApplyReadmeTranslations === 'function') {
                            window.starcatApplyReadmeTranslations(isVisible, translations);
                        }
                        """,
                        arguments: [
                            "isVisible": state.isVisible,
                            "translations": payload
                        ],
                        in: nil,
                        contentWorld: .page
                    )
                } catch {
                    AppLog.ui.debug("Readme translation DOM update deferred: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        private static let readmeEnhancementScript = """
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

            function extractTranslationSegments() {
                var article = document.querySelector('.markdown-body article') ||
                    document.querySelector('.markdown-body');
                if (!article) { return; }

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
                window.webkit.messageHandlers.\(ReadmeWebViewConstants.translationSegmentsMessageName)
                    .postMessage(segments);
            }

            window.starcatApplyReadmeTranslations = function(isVisible, translations) {
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
            extractTranslationSegments();
            setTimeout(report, 0);
        })();
        """

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == ReadmeWebViewConstants.translationSegmentsMessageName {
                guard let payload = message.body as? [[String: Any]] else { return }
                let segments = payload.prefix(2_000).compactMap { item -> ReadmeSourceSegment? in
                    guard let id = item["id"] as? String,
                          let text = item["text"] as? String,
                          id.hasPrefix("starcat-readme-segment-"),
                          !text.isEmpty,
                          text.count <= 20_000
                    else { return nil }
                    return ReadmeSourceSegment(id: id, text: text)
                }
                Task { @MainActor in
                    self.onTranslationSegmentsChange(segments)
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
    static let translationSegmentsMessageName = "readmeTranslationSegments"
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
    """
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

/// 缓存键：HTML 片段 + 主题，用于 updateNSView 时判断是否需要重新 loadHTMLString。
///
/// 字号调整不在此键中：字号变化时通过 JS 动态更新 CSS 变量 `--readme-body-font-size`，
/// 避免 `loadHTMLString` 重载触发 scroll 事件导致字号面板意外关闭。
struct ReadmeKey: Equatable {
    let fragment: String
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
        --border: #30363d;
        --code-bg: #161b22;
        --blockquote-fg: #8b949e;
        --blockquote-border: #30363d;
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
