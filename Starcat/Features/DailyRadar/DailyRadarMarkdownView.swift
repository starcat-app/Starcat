//
//  DailyRadarMarkdownView.swift
//  Starcat
//
//  日报专用安全 Markdown 适配：AST 与来源 HTML 只输出允许的展示元素。
//  WebView 自适应高度，纵向滚动交给原生宿主，宽表保留局部横向滚动。
//

import SwiftUI
import WebKit
import Markdown

/// 周报元数据来自固定 Markdown；语言由文件名与请求选择，不进入可见文章头。
struct DailyRadarArticle: Decodable {
    let articleFormat: Int
    let title: String
    let summary: String
    let editionDate: String
    let readingMinutes: Int
    var body = ""

    private enum CodingKeys: String, CodingKey {
        case articleFormat = "article_format", title, summary
        case editionDate = "edition_date", readingMinutes = "reading_minutes"
    }

    /// H1 留在可独立阅读的 Markdown 中；宿主已有原生标题，正文渲染只取其后的内容。
    static func parse(_ markdown: String) -> Self? {
        guard markdown.hasPrefix("---\n") else { return nil }
        let start = markdown.index(markdown.startIndex, offsetBy: 4)
        guard let end = markdown.range(of: "\n---\n", range: start..<markdown.endIndex),
              let data = String(markdown[markdown.index(markdown.startIndex, offsetBy: 4)..<end.lowerBound])
                .data(using: .utf8),
              var article = try? JSONDecoder().decode(Self.self, from: data),
              article.articleFormat == 1, !article.title.isEmpty, !article.summary.isEmpty,
              (1...1000).contains(article.readingMinutes) else { return nil }
        let body = String(markdown[end.upperBound...]).trimmingCharacters(in: .newlines)
        let heading = "# \(article.title)\n\n"
        guard body.hasPrefix(heading) else { return nil }
        article.body = String(body.dropFirst(heading.count))
        return article
    }
}

/// 不使用通用 HTMLFormatter：其原始 HTML、code 与链接属性不承担来源安全校验。
enum DailyRadarMarkdownRenderer {
    static func render(_ markdown: String) -> String { renderNode(Document(parsing: markdown)) }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func renderNode(_ node: any Markup, insideLink: Bool = false) -> String {
        let children = { node.children.map { renderNode($0, insideLink: insideLink || node is Markdown.Link) }.joined() }
        switch node {
        case let text as Markdown.Text: return escape(text.string)
        case let code as InlineCode: return "<code>\(escape(code.code))</code>"
        case let block as CodeBlock: return "<pre><code>\(escape(block.code))</code></pre>"
        case let heading as Heading: return "<h\(heading.level)>\(children())</h\(heading.level)>"
        case is Paragraph: return "<p>\(children())</p>"
        case is Strong: return "<strong>\(children())</strong>"
        case is Emphasis: return "<em>\(children())</em>"
        case is Strikethrough: return "<del>\(children())</del>"
        case is BlockQuote: return "<blockquote>\(children())</blockquote>"
        case is UnorderedList: return "<ul>\(children())</ul>"
        case is OrderedList: return "<ol>\(children())</ol>"
        case is ListItem: return "<li>\(children())</li>"
        case is SoftBreak: return "\n"
        case is LineBreak: return "<br>"
        case is ThematicBreak: return "<hr>"
        case let link as Markdown.Link:
            guard let raw = link.destination, let url = safeURL(raw) else { return children() }
            // 只增强仓库首页链接，不把 Issue、Release 或带业务含义的链接文字改成仓库名。
            if let repository = repositoryName(url), ["GitHub", repository].contains(link.plainText) {
                let owner = String(repository.split(separator: "/")[0])
                let avatar = "https://github.com/\(owner).png?size=48"
                return "<a class=\"repository\" href=\"\(escape(url.absoluteString))\">" +
                    renderImage(avatar, alt: "", repository: true) +
                    "\(escape(repository))</a>"
            }
            return "<a href=\"\(escape(url.absoluteString))\">\(children())</a>"
        case let image as Markdown.Image:
            return renderImage(image.source ?? "", alt: image.plainText, insideLink: insideLink)
        case let table as Markdown.Table:
            let className = isFourColumnMetadataTable(table) ? " class=\"metadata\"" : ""
            return "<div class=\"table\"><table\(className)>\(children())</table></div>"
        case let head as Markdown.Table.Head:
            // 表头使用真实 th：浏览器可按列语义计算宽度，也便于辅助技术识别表头。
            let cells = head.children.compactMap { $0 as? Markdown.Table.Cell }
                // Cell 的通用分支会包一层 td；表头需要直接聚合内部内容，避免 th 中嵌套 td。
                .map { "<th>\($0.children.map { renderNode($0) }.joined())</th>" }
                .joined()
            return "<thead><tr>\(cells)</tr></thead>"
        case is Markdown.Table.Body: return "<tbody>\(children())</tbody>"
        case is Markdown.Table.Row: return "<tr>\(children())</tr>"
        case let cell as Markdown.Table.Cell:
            // 数字不可继承正文的 anywhere 换行，否则窄列会把 548 排成三行。
            let value = cell.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            let numeric = value.range(
                of: #"^[+-]?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?%?$"#,
                options: .regularExpression
            ) != nil
            let className = numeric ? " class=\"numeric\"" : ""
            return "<td\(className)>\(repairedDiscussionLink(in: cell) ?? children())</td>"
        case let html as HTMLBlock: return DailyRadarSafeHTML.render(html.rawHTML)
        case let html as InlineHTML: return DailyRadarSafeHTML.render(html.rawHTML)
        default: return children()
        }
    }

    /// 正文图片与仓库头像共用真实懒加载；头像仅装饰，失败不另建链接，仓库文本始终可读可点。
    /// 不写 src/srcset：全文高度的 WebView 会把远处图片也视为可见，原生裁切区到达后才赋值。
    /// 只重建固定属性，来源 HTML 仍走 SafeHTML，不能携带事件、样式或其他图源。
    private static func renderImage(
        _ raw: String, alt: String, repository: Bool = false, insideLink: Bool = false
    ) -> String {
        guard let url = safeURL(raw), url.scheme == "https" else { return escape(alt) }
        let source = escape(url.absoluteString)
        let text = escape(alt)
        // Markdown 图片可能已包在来源链接中，回退不可再嵌套 a，避免浏览器重组后改变跳转语义。
        let fallbackTag = insideLink ? "span" : "a"
        let fallbackHref = insideLink ? "" : " href=\"\(source)\""
        let fallback = repository ? "" :
            "<\(fallbackTag) class=\"image-fallback\"\(fallbackHref)>\(alt.isEmpty ? source : text)</\(fallbackTag)>"
        let slotClass = repository ? "article-image repository-image" : "article-image"
        let imageClass = repository ? " class=\"repository-avatar\"" : ""
        return "<span class=\"\(slotClass)\" data-state=\"pending\" aria-busy=\"true\">" +
            "<img\(imageClass) data-source=\"\(source)\" alt=\"\(text)\" decoding=\"async\">" +
            "<span class=\"image-placeholder\" aria-hidden=\"true\"><span class=\"image-spinner\"></span></span>" +
            "\(fallback)</span>"
    }

    /// 严格匹配 owner/repo，查询、片段和下级路径继续沿用原链接展示。
    private static func repositoryName(_ url: URL) -> String? {
        guard url.scheme == "https", url.host?.lowercased() == "github.com",
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }
        let name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard name.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#,
                         options: .regularExpression) != nil else { return nil }
        return name
    }

    /// 日报里常见“主体 + 两个短指标 + Summary”的四列表；项目表与文章表都使用同一布局规则。
    /// 自动布局会被长 Summary 挤压成“R-e-a-c-t-i-o-n-s”这类竖排字符；固定比例和最小宽度能保持短指标列可读。
    private static func isFourColumnMetadataTable(_ table: Markdown.Table) -> Bool {
        guard let head = table.child(at: 0) as? Markdown.Table.Head else { return false }
        // Table.Head 的直接子节点就是 Cell；这里不能套 Row，否则所有表头都会被误判为空。
        let cells = head.children.compactMap { $0 as? Markdown.Table.Cell }
        guard cells.count == 4 else { return false }
        // Cell 不能单独调用 format()：swift-markdown 要求表格作为整体格式化，单独格式化会触发 fatal error。
        let headers = cells.map { $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasSummary = headers.last?.contains("summary") == true ||
            headers.last?.contains("摘要") == true ||
            headers.last?.contains("说明") == true
        let shortMetricHeaders = [
            "lang", "language", "stars", "reactions", "comments", "score", "votes",
            "语言", "星标", "星数", "反应", "评论", "票数", "评分", "得分"
        ]
        let hasShortMetrics = headers.dropFirst().dropLast().contains { header in
            shortMetricHeaders.contains { header.contains($0) }
        }
        return hasSummary && hasShortMetrics
    }

    /// 部分来源把“· discuss”误写进主链接的圆括号；仅修复表格中明确的三节点结构。
    /// 不全局替换 Markdown，避免误改代码、正常括号 URL 或普通段落中的原始文字。
    private static func repairedDiscussionLink(in cell: Markdown.Table.Cell) -> String? {
        let nodes = Array(cell.children)
        guard nodes.count == 3, let prefix = nodes[0] as? Markdown.Text,
              let discussion = nodes[1] as? Markdown.Link,
              let suffix = nodes[2] as? Markdown.Text, suffix.string == ")",
              let rawDiscussion = discussion.destination, let discussionURL = safeURL(rawDiscussion),
              let expression = try? NSRegularExpression(
                pattern: #"^\[([^\[\]\n]+)\]\((https?://\S+)[\t ]+([·•])[\t ]+$"#
              ) else { return nil }
        let source = prefix.string as NSString
        guard let match = expression.firstMatch(
            in: prefix.string, range: NSRange(location: 0, length: source.length)
        ), let url = safeURL(source.substring(with: match.range(at: 2))) else { return nil }
        let title = escape(source.substring(with: match.range(at: 1)))
        let separator = source.substring(with: match.range(at: 3))
        let discussionTitle = discussion.children.map { renderNode($0) }.joined()
        return "<a href=\"\(escape(url.absoluteString))\">\(title)</a> \(separator) " +
            "<a href=\"\(escape(discussionURL.absoluteString))\">\(discussionTitle)</a>"
    }

    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.host != nil else { return nil }
        return url
    }
}

/// 只承载文章正文，不继承仓库 README 的命令、分享或主窗口选择路由。
struct DailyRadarMarkdownView: NSViewRepresentable {
    let markdown: String
    let identity: String
    let onLink: (URL) -> Void
    @Binding var height: CGFloat
    var onReady: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var scale
    @Environment(\.starcatReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "dailyHeight")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let webView = PassthroughWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.onVisibleRangeChange = { [weak coordinator = context.coordinator] in
            coordinator?.publishVisibleRange()
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // Reader 的骨架覆盖/透明度变化不一定引发布局；下一轮重取裁切区，不在 update 中回写状态。
        (webView as? PassthroughWebView)?.scheduleVisibilityUpdate()
        let key = "\(identity)|\(colorScheme)|\(scale.scaled(16))|\(reduceMotion)"
        guard context.coordinator.identity != key else { return }
        context.coordinator.identity = key
        let session = UUID().uuidString
        context.coordinator.session = session
        let document = DailyRadarMarkdownDocument.render(
            markdown, session: session, dark: colorScheme == .dark,
            fontSize: scale.scaled(16), reduceMotion: reduceMotion
        )
        webView.loadHTMLString(document, baseURL: nil)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // 先让排队的布局/可见性任务失效，再断开 WebKit 和外层滚动通知。
        coordinator.session = ""
        coordinator.webView = nil
        (nsView as? PassthroughWebView)?.stopObservingVisibility()
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "dailyHeight")
    }

    /// 纵向交给文章宿主；横向留给 WebKit 命中表格或代码块的局部滚动区。
    /// WebView 自身等高于全文，JS viewport/IntersectionObserver 无法识别外层 ScrollView 的裁切。
    /// 这里只观察祖先（不观察 WebKit 内部滚动区），把原生真实可见范围转换为从文档顶部开始的坐标。
    final class PassthroughWebView: WKWebView {
        var onVisibleRangeChange: (() -> Void)?
        private var visibilityObservers: [NSObjectProtocol] = []
        private var visibilityUpdateScheduled = false
        private var observesVisibility = true

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            observeAncestors()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeAncestors()
        }

        override func layout() {
            super.layout()
            scheduleVisibilityUpdate()
        }

        /// clipView 滚动、祖先移动及全文高度变化都会改变裁切；合并同一轮布局的通知。
        private func observeAncestors() {
            removeVisibilityObservers()
            guard observesVisibility else { return }
            var ancestor = superview
            while let view = ancestor {
                view.postsFrameChangedNotifications = true
                observe(NSView.frameDidChangeNotification, object: view)
                if let clip = view as? NSClipView {
                    clip.postsBoundsChangedNotifications = true
                    observe(NSView.boundsDidChangeNotification, object: clip)
                }
                ancestor = view.superview
            }
            scheduleVisibilityUpdate()
        }

        private func observe(_ name: Notification.Name, object: NSView) {
            visibilityObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: object, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleVisibilityUpdate() }
            })
        }

        func scheduleVisibilityUpdate() {
            guard observesVisibility, !visibilityUpdateScheduled else { return }
            visibilityUpdateScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.visibilityUpdateScheduled = false
                self.onVisibleRangeChange?()
            }
        }

        /// visibleRect 已考虑祖先裁切，再显式相交 clipView，避免拿全文 bounds 当成视口。
        var visibleDocumentRange: CGRect {
            guard window != nil, !isHiddenOrHasHiddenAncestor else { return .zero }
            var rect = visibleRect.intersection(bounds)
            var ancestor = superview
            while let view = ancestor {
                if let clip = view as? NSClipView {
                    rect = rect.intersection(convert(clip.bounds, from: clip))
                }
                ancestor = view.superview
            }
            guard !rect.isNull, !rect.isEmpty else { return .zero }
            let top = isFlipped ? rect.minY - bounds.minY : bounds.maxY - rect.maxY
            return CGRect(x: 0, y: top, width: bounds.width, height: rect.height)
        }

        private func removeVisibilityObservers() {
            visibilityObservers.forEach { NotificationCenter.default.removeObserver($0) }
            visibilityObservers.removeAll()
        }

        func stopObservingVisibility() {
            observesVisibility = false
            onVisibleRangeChange = nil
            removeVisibilityObservers()
        }

        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
                super.scrollWheel(with: event)
            } else {
                nextResponder?.scrollWheel(with: event)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: DailyRadarMarkdownView
        var identity = ""
        var session = ""
        weak var webView: PassthroughWebView?
        private var readySession: String?

        init(parent: DailyRadarMarkdownView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.name == "dailyHeight",
                  let body = message.body as? [String: Any],
                  let incomingSession = body["session"] as? String, incomingSession == session,
                  let number = body["height"] as? Double else { return }
            // 消息发生于 WebKit 布局回调，下一轮发布；旧页面排队的消息不能覆盖新报告或触发 ready。
            Task { @MainActor [weak self] in
                self?.publishLayout(height: number, session: incomingSession)
            }
        }

        /// 初始布局不依赖 window.load 或图片请求；即使高度数值未变，也必须每会话通知一次 Reader。
        /// 与高度发布放在同一 MainActor 任务，宿主收起骨架时已经拿到有效正文高度。
        func publishLayout(height: Double, session incomingSession: String) {
            guard !session.isEmpty, incomingSession == session, height.isFinite, height > 0 else { return }
            if abs(parent.height - height) > 0.5 { parent.height = height }
            if readySession != session {
                readySession = session
                parent.onReady()
            }
            publishVisibleRange()
        }

        /// session 同时在 JS 端核对，防止导航切换时跨进程排队的旧可见范围启动新页面图片。
        func publishVisibleRange() {
            guard !session.isEmpty, let webView else { return }
            let rect = webView.visibleDocumentRange
            guard rect.minY.isFinite, rect.maxY.isFinite, rect.width.isFinite else { return }
            webView.evaluateJavaScript(
                "window.dailyRadarSetVisibleRange?.('\(session)',\(rect.minY),\(rect.maxY),\(rect.width));",
                completionHandler: nil
            )
        }

        // 与 WKNavigationDelegate 的主线程回调签名一致，确保安全链接由宿主处理，
        // 而不是因可选协议方法未匹配而直接在日报 WebView 内打开外部页面。
        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .other, action.request.url?.absoluteString == "about:blank" {
                decisionHandler(.allow)
            } else if action.navigationType == .linkActivated,
                      let url = action.request.url,
                      let safe = DailyRadarMarkdownRenderer.safeURL(url.absoluteString) {
                parent.onLink(safe)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

/// 日报独立的可信文档壳；仅此 nonce 脚本可为白名单图片设置 src，不扩展通用 README 执行能力。
enum DailyRadarMarkdownDocument {
    static func render(
        _ markdown: String, session: String, dark: Bool, fontSize: CGFloat, reduceMotion: Bool
    ) -> String {
        let html = DailyRadarMarkdownRenderer.render(markdown)
        // CSP 只授权这一份 nonce 脚本；正文来自白名单 AST，不允许 style、脚本或子 frame。
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https:; style-src 'unsafe-inline'; script-src 'nonce-\(session)'; base-uri 'none'; form-action 'none'">
        <style>
        html{color-scheme:\(dark ? "dark" : "light");overflow:hidden}
        body{margin:0;font:\(fontSize)px -apple-system;line-height:1.75;color:\(dark ? "#f5f5f7" : "#1d1d1f");overflow-wrap:anywhere}
        main{display:flow-root;min-height:1px}
        h1,h2,h3{line-height:1.35;margin:1.5em 0 .6em}
        p{margin:.8em 0}a{color:#007aff}img{max-width:100%;height:auto}
        a.repository{display:inline-flex;align-items:center;gap:.45em}
        img.repository-avatar{width:1.25em;height:1.25em;border-radius:50%;object-fit:cover;flex-shrink:0}
        pre,.table{overflow-x:auto;max-width:100%}
        pre{padding:16px;background:\(dark ? "#2c2c2e" : "#f5f5f7");border-radius:8px}
        code{font:0.88em ui-monospace,monospace}
        table{border-collapse:collapse;width:100%}
        td,th{padding:8px 12px;border:1px solid \(dark ? "#444" : "#ddd");text-align:left;vertical-align:top}
        th,td.numeric{white-space:nowrap;overflow-wrap:normal;word-break:normal}
        /* 最小宽度随正文字号缩放，窄视口局部横滚，不牺牲指标列和长英文表头。 */
        table.metadata{table-layout:fixed;min-width:52em}
        table.metadata th:nth-child(1),table.metadata td:nth-child(1){width:26%}
        table.metadata th:nth-child(2),table.metadata td:nth-child(2){width:13%}
        table.metadata th:nth-child(3),table.metadata td:nth-child(3){width:13%}
        table.metadata th:nth-child(4),table.metadata td:nth-child(4){width:48%}
        table.metadata th:nth-child(2),table.metadata th:nth-child(3),table.metadata td:nth-child(2),table.metadata td:nth-child(3){overflow-wrap:normal;word-break:normal}
        blockquote{margin-left:0;padding-left:16px;border-left:3px solid #888}
        summary{cursor:pointer}details{padding:10px 0}
        \(imageStyles)
        </style></head>
        <body data-reduce-motion="\(reduceMotion)"><main>\(html)</main>
        <script nonce="\(session)">\(imageScript(session: session))</script></body></html>
        """
    }

    /// 未知图片尺寸先预留 16:9，加载中才运动；失败立即撤掉占位，保留可读原图链接。
    static let imageStyles = """
        .article-image{display:block;position:relative;overflow:hidden;border-radius:8px;margin:.8em 0;-webkit-user-select:none}
    .article-image[data-state="pending"],.article-image[data-state="loading"]{aspect-ratio:16/9;min-height:120px;background:rgba(128,128,128,.12)}
    .article-image>img{display:block;margin:0 auto;opacity:0;transition:opacity .3s ease}
    .article-image:not([data-state="loaded"])>img{position:absolute;visibility:hidden}
    .article-image[data-state="loaded"]>img{opacity:1}
    .image-placeholder{position:absolute;inset:0;display:grid;place-items:center}
    .image-placeholder::before{content:"";position:absolute;inset:0;background:linear-gradient(100deg,transparent 20%,rgba(128,128,128,.18) 50%,transparent 80%);transform:translateX(-100%)}
    .image-spinner{width:22px;height:22px;border:2px solid rgba(128,128,128,.25);border-top-color:currentColor;border-radius:50%}
    .article-image[data-state="loading"] .image-placeholder::before{animation:image-shimmer 1.6s ease-in-out infinite}
    .article-image[data-state="loading"] .image-spinner{animation:image-spin .85s linear infinite}
    .article-image[data-state="loaded"] .image-placeholder,.article-image[data-state="error"] .image-placeholder{display:none}
    .image-fallback{display:none;padding:16px;border:1px dashed currentColor;border-radius:8px;overflow-wrap:anywhere}
    .article-image[data-state="error"] .image-fallback{display:block}
    .article-image.repository-image{display:inline-block;width:1.25em;height:1.25em;min-height:0;aspect-ratio:auto;flex-shrink:0;margin:0;border-radius:50%;background:rgba(128,128,128,.12)}
    .repository-image .image-spinner{width:.5em;height:.5em;border-width:1px}
    @keyframes image-shimmer{to{transform:translateX(100%)}}
    @keyframes image-spin{to{transform:rotate(360deg)}}
    body[data-reduce-motion="true"] .article-image>img{transition:none}
    body[data-reduce-motion="true"] .image-placeholder::before{display:none}
    body[data-reduce-motion="true"] .image-spinner{animation:none!important}
    @media(prefers-reduced-motion:reduce){
        .article-image>img{transition:none}
        .image-placeholder::before{display:none}
        .image-spinner{animation:none!important}
    }
    """

    /// 不用 WebKit viewport，也不在 window.load 后才 ready。只有原生传入裁切范围才启动图源，
    /// ResizeObserver 及 details toggle 会复查最新范围，避免图片撑高后继续加载已被推远的图片。
    static func imageScript(session: String) -> String {
        """
        const session="\(session)";
        const content=document.querySelector("main");
        const images=Array.from(content.querySelectorAll(".article-image"));
        let visibleRange=null;
        let queued=false;
        const send=()=>window.webkit.messageHandlers.dailyHeight.postMessage({
            session,height:Math.ceil(content.getBoundingClientRect().height)
        });
        const schedule=()=>{
            if(queued)return;
            queued=true;
            requestAnimationFrame(()=>{queued=false;loadNearImages();});
        };
        const finish=(slot,state)=>{
            slot.dataset.state=state;
            slot.setAttribute("aria-busy","false");
            send();
            schedule();
        };
        const loadNearImages=()=>{
            if(!visibleRange)return;
            const {top,bottom,width}=visibleRange;
            if(bottom<=top||width<=0)return;
            const ratio=window.innerWidth/width;
            for(const slot of images){
                if(slot.dataset.state!=="pending"||!slot.getClientRects().length)continue;
                const rect=slot.getBoundingClientRect();
                const y=rect.top+window.scrollY;
                if(rect.height<=0||rect.width<=0||y+rect.height<top*ratio-320||y>bottom*ratio+320)continue;
                const image=slot.querySelector("img");
                // data-source 只能来自 Swift safeURL + HTTPS 检查；再次限制协议，拒绝脚本或 data 图源。
                const source=image.dataset.source;
                let url;
                try{url=new URL(source);}catch{finish(slot,"error");continue;}
                if(url.protocol!=="https:"||url.username||url.password){finish(slot,"error");continue;}
                slot.dataset.state="loading";
                image.addEventListener("load",()=>finish(slot,"loaded"),{once:true});
                image.addEventListener("error",()=>finish(slot,"error"),{once:true});
                image.src=source;
            }
        };
        window.dailyRadarSetVisibleRange=(incoming,top,bottom,width)=>{
            if(incoming!==session||![top,bottom,width].every(Number.isFinite))return;
            visibleRange={top,bottom,width};
            schedule();
        };
        // 日报图片只用于阅读，不允许 WebKit 图片菜单 / 拖拽打断报告浏览；
        // 不拦截正文和链接菜单，保留用户对文字与来源的正常操作。
        const isArticleImageTarget=(target)=>Boolean(
            target&&typeof target.closest==="function"&&target.closest(".article-image")
        );
        document.addEventListener("contextmenu",(event)=>{
            if(isArticleImageTarget(event.target))event.preventDefault();
        },true);
        document.addEventListener("dragstart",(event)=>{
            if(isArticleImageTarget(event.target))event.preventDefault();
        },true);
        new ResizeObserver(()=>{send();schedule();}).observe(content);
        document.addEventListener("toggle",()=>{send();schedule();},true);
        send();
        """
    }
}
