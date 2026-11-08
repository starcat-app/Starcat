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

    private static func renderNode(_ node: any Markup) -> String {
        let children = { node.children.map { renderNode($0) }.joined() }
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
                    "<img class=\"repository-avatar\" src=\"\(escape(avatar))\" alt=\"\" loading=\"lazy\">" +
                    "\(escape(repository))</a>"
            }
            return "<a href=\"\(escape(url.absoluteString))\">\(children())</a>"
        case let image as Markdown.Image:
            guard let raw = image.source, let url = safeURL(raw), url.scheme == "https" else { return escape(image.plainText) }
            return "<img src=\"\(escape(url.absoluteString))\" alt=\"\(escape(image.plainText))\">"
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.starcatInterfaceScale) private var scale

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
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let key = "\(identity)|\(colorScheme)|\(scale.scaled(16))"
        guard context.coordinator.identity != key else { return }
        context.coordinator.identity = key
        let session = UUID().uuidString
        context.coordinator.session = session
        let html = DailyRadarMarkdownRenderer.render(markdown)
        let dark = colorScheme == .dark
        // CSP 只授权这一份 nonce 脚本；正文来自白名单 AST，不允许 style、脚本或子 frame。
        let document = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https:; style-src 'unsafe-inline'; script-src 'nonce-\(session)'; base-uri 'none'; form-action 'none'">
        <style>
        html{color-scheme:\(dark ? "dark" : "light");overflow:hidden}
        body{margin:0;font:\(scale.scaled(16))px -apple-system;line-height:1.75;color:\(dark ? "#f5f5f7" : "#1d1d1f");overflow-wrap:anywhere}
        main{display:flow-root}
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
        </style></head>
        <body><main>\(html)</main><script nonce="\(session)">const content=document.querySelector("main");const send=()=>window.webkit.messageHandlers.dailyHeight.postMessage({session:"\(session)",height:Math.ceil(content.getBoundingClientRect().height)});new ResizeObserver(send).observe(content);window.addEventListener("load",send);document.addEventListener("toggle",send,true);send();</script></body></html>
        """
        webView.loadHTMLString(document, baseURL: nil)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "dailyHeight")
    }

    /// 纵向交给文章宿主；横向留给 WebKit 命中表格或代码块的局部滚动区。
    final class PassthroughWebView: WKWebView {
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
        init(parent: DailyRadarMarkdownView) { self.parent = parent }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.name == "dailyHeight",
                  let body = message.body as? [String: Any], body["session"] as? String == session,
                  let number = body["height"] as? Double, number.isFinite, number > 0 else { return }
            let height = max(1, number)
            guard abs(parent.height - height) > 0.5 else { return }
            // 消息发生于 WebKit 布局回调，下一轮发布避免在 SwiftUI update 中回写状态。
            Task { @MainActor [weak self] in
                guard let self, self.session == body["session"] as? String else { return }
                self.parent.height = height
            }
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
