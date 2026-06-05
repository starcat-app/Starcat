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
//     例外：注入一个 app-owned isolated user script，只用于把 window.scrollY 回传给 SwiftUI，
//     让详情页能在 README 滚动时折叠顶部信息面板。
//  4. 图片相对路径重写（rewriteAssetURLs）：
//     - GitHub 的 HTML render 端点对 Markdown `![]()` 会做 camo 代理重写，
//       但对原生 HTML `<img src="./xx">` 不重写，原样吐回相对路径
//     - 我们的 baseURL 是 `https://github.com/owner/repo`，浏览器把 `./logo.PNG`
//       解析成 `https://github.com/owner/logo.PNG` → 404
//     - 修复：HTML 注入前用正则把所有 `<img src="相对路径">` 重写为
//       `https://raw.githubusercontent.com/{owner}/{repo}/HEAD/...`
//       （绝对 URL / data: / 协议相对 // 不动）。`HEAD` 自动指向默认分支，
//       无需知道 default branch。
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
//  - baseURL 传 repo htmlUrl（如 https://github.com/owner/repo），用于解析极少数遗漏的相对路径
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

struct ReadmeWebView: NSViewRepresentable {

    /// GitHub 返回的 HTML 片段（不含 <html>/<head>/<body>）。
    let htmlFragment: String

    /// 用于解析 HTML 内相对 URL 的基地址。
    /// 通常传 repo.htmlUrl（https://github.com/owner/repo）。
    let baseURL: URL?

    /// 仓库 owner（用于把图片相对路径重写为 raw URL）。nil 时跳过重写。
    let owner: String?

    /// 仓库 name（同上）。
    let repo: String?

    /// README 内部滚动位置变化回调。
    ///
    /// 背景：README 由 WKWebView 自己滚动，外层 SwiftUI 看不到 ScrollView offset。
    /// 详情页需要在用户阅读时收起顶部元信息面板，所以这里把 WebView 的 scroll offset
    /// 作为一个窄回调往外透出；不把 WKWebView / NSScrollView 暴露给业务层。
    var onScrollOffsetChange: (CGFloat) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

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

        context.coordinator.webView = webView
        context.coordinator.onScrollOffsetChange = onScrollOffsetChange
        loadIfNeeded(into: webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onScrollOffsetChange = onScrollOffsetChange
        loadIfNeeded(into: webView, context: context)
    }

    // MARK: - Private

    /// 仅在 html 内容或主题变化时重新 loadHTML。
    ///
    /// 调用 `loadHTMLString` 前会把 `expectsInitialLoad` 置 true，让 Coordinator
    /// 放行紧接而来的那一次主框架导航，之后所有主框架导航全部 cancel
    /// （挡住右键菜单"重新加载"会把整页 GitHub 拉进来的副作用）。
    private func loadIfNeeded(into webView: WKWebView, context: Context) {
        let key = ReadmeKey(fragment: htmlFragment, isDark: colorScheme == .dark)
        guard context.coordinator.lastLoadedKey != key else { return }
        context.coordinator.lastLoadedKey = key

        let rewritten = Self.rewriteAssetURLs(in: htmlFragment, owner: owner, repo: repo)
        let fullHTML = Self.assembleDocument(fragment: rewritten, isDark: colorScheme == .dark)
        context.coordinator.expectsInitialLoad = true
        webView.loadHTMLString(fullHTML, baseURL: baseURL)
    }

    /// 将 GitHub 的 HTML 片段包装为完整文档（带 GFM 主题 CSS）。
    static func assembleDocument(fragment: String, isDark: Bool) -> String {
        let css = ReadmeCSS.full
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

    // MARK: - 图片相对路径重写

    /// 把 HTML 中所有 `<img src="相对路径">` 重写为 raw.githubusercontent.com 绝对 URL。
    ///
    /// 触发原因：GitHub HTML render 端点对原生 HTML `<img>` 不做 URL 重写，
    /// 用 `repo.htmlUrl` 作 baseURL 时 `./logo.PNG` 会被浏览器解析为
    /// `https://github.com/owner/logo.PNG` → 404。
    ///
    /// 策略：
    /// - 完整 URL（http(s):// / data: / 协议相对 //） → 不动
    /// - 其余视作相对路径 → 拼到 `https://raw.githubusercontent.com/{owner}/{repo}/HEAD/`
    ///   - HEAD 自动指向 default branch，无需额外查询
    ///   - 去掉前导 `./` 与 `/`，与 GitHub 仓库根对齐
    /// - owner/repo 缺失 → 直接原样返回（保守，宁可坏图不要错重写）
    ///
    /// 正则只匹配双引号包裹的 src（GitHub render 出来稳定用双引号），
    /// 不做完整 HTML 解析以避免引入新依赖（SwiftSoup 等）。
    static func rewriteAssetURLs(in html: String, owner: String?, repo: String?) -> String {
        guard let owner, let repo, !owner.isEmpty, !repo.isEmpty else { return html }
        let rawBase = "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/"

        // <img ...src="xxx"...> ；捕获 1 = src 前的属性串，捕获 2 = src 值
        let pattern = #"<img\b([^>]*?)\bsrc\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let nsHtml = html as NSString
        let matches = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsHtml.length))
        guard !matches.isEmpty else { return html }

        var result = ""
        var cursor = 0
        for m in matches {
            // 复制 match 之前未变的部分
            let unchanged = NSRange(location: cursor, length: m.range.location - cursor)
            result += nsHtml.substring(with: unchanged)

            let prefix = nsHtml.substring(with: m.range(at: 1))
            let originalSrc = nsHtml.substring(with: m.range(at: 2))
            let rewritten = rewriteOneAssetURL(originalSrc, rawBase: rawBase)
            result += "<img\(prefix)src=\"\(rewritten)\""

            cursor = m.range.location + m.range.length
        }
        result += nsHtml.substring(from: cursor)
        return result
    }

    /// 单个 src 重写。绝对/协议相对/data URI 一律放过，其余拼到 rawBase。
    static func rewriteOneAssetURL(_ src: String, rawBase: String) -> String {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("//") || lower.hasPrefix("data:")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("javascript:") {
            return trimmed
        }
        var clean = Substring(trimmed)
        if clean.hasPrefix("./") { clean = clean.dropFirst(2) }
        while clean.hasPrefix("/") { clean = clean.dropFirst() }
        return rawBase + String(clean)
    }

    // MARK: - Coordinator

    /// 同时负责导航委托 + 记录上次加载的 HTML（避免重复 load 触发白闪）。
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

        weak var webView: WKWebView?
        var lastLoadedKey: ReadmeKey?
        var onScrollOffsetChange: (CGFloat) -> Void = { _ in }
        private weak var userContentController: WKUserContentController?

        /// 由 `loadIfNeeded` 在调用 `loadHTMLString` 前置 true，
        /// 用于放行紧接而来的那一次主框架导航；放行后立即置 false。
        /// 之后任何主框架导航（reload / meta refresh / 页内 location）都会被 cancel。
        var expectsInitialLoad: Bool = false

        deinit {
            userContentController?.removeScriptMessageHandler(forName: Self.scrollMessageName)
        }

        private static let scrollMessageName = "readmeScroll"

        /// 构造带滚动上报脚本的 content controller。
        ///
        /// 为什么不用 NSScrollView 观察：macOS `WKWebView` 没有公开 `scrollView` 属性，
        /// 并且不同 WebKit 版本的内部 NSView 子树并不稳定。直接从文档里监听 `scroll`
        /// 事件拿 `window.scrollY` 更接近真实阅读位置，也不会依赖私有 view class。
        ///
        /// 安全边界：
        /// - user script 只读 `scrollY` 并 postMessage 一个数字，不读 README 内容。
        /// - HTML 文档里加了 CSP `script-src 'none'`，页面自带 `<script>` / inline handler 不执行。
        /// - message handler 只接收 Number，其余 body 直接忽略。
        func makeUserContentController() -> WKUserContentController {
            let controller = WKUserContentController()
            let script = WKUserScript(
                source: Self.scrollReportingScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            controller.addUserScript(script)
            controller.add(self, name: Self.scrollMessageName)
            userContentController = controller
            return controller
        }

        private static let scrollReportingScript = """
        (function() {
            var lastY = -1;
            var ticking = false;

            function currentY() {
                return window.scrollY ||
                    document.documentElement.scrollTop ||
                    document.body.scrollTop ||
                    0;
            }

            function report() {
                ticking = false;
                var y = currentY();
                if (Math.abs(y - lastY) < 1) { return; }
                lastY = y;
                window.webkit.messageHandlers.\(scrollMessageName).postMessage(y);
            }

            function schedule() {
                if (ticking) { return; }
                ticking = true;
                window.requestAnimationFrame(report);
            }

            window.addEventListener('scroll', schedule, { passive: true });
            window.addEventListener('load', report);
            setTimeout(report, 0);
        })();
        """

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.scrollMessageName else { return }
            if let value = message.body as? NSNumber {
                onScrollOffsetChange(CGFloat(truncating: value))
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
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

/// 缓存键：HTML 片段 + 主题，用于 updateNSView 时判断是否需要重新 loadHTMLString。
struct ReadmeKey: Equatable {
    let fragment: String
    let isDark: Bool
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
        font-size: 14px;
        line-height: 1.6;
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
    /*
     * 滚动条美化（webkit only）。
     * WKWebView 不走 SwiftUI / NSScrollView 的滚动条样式；这里用 8px 贴近 repo List
     * 原生 overlay scroller 的视觉厚度，避免详情页 README 比中栏列表显得更粗。
     */
    ::-webkit-scrollbar { width: 8px; height: 8px; }
    ::-webkit-scrollbar-thumb {
        background: var(--border);
        border-radius: 4px;
    }
    """
}
