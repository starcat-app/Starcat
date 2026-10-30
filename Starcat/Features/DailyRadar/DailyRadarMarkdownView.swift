//
//  DailyRadarMarkdownView.swift
//  Starcat
//
//  日报专用安全 Markdown 适配：AST 只输出允许元素，源 HTML 只保留
//  details/summary/br。WebView 自适应高度并转交滚轮，整篇继续使用原生单滚动。
//

import SwiftUI
import WebKit
import Markdown

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
            return "<a href=\"\(escape(url.absoluteString))\">\(children())</a>"
        case let image as Markdown.Image:
            guard let raw = image.source, let url = safeURL(raw), url.scheme == "https" else { return escape(image.plainText) }
            return "<img src=\"\(escape(url.absoluteString))\" alt=\"\(escape(image.plainText))\">"
        case is Markdown.Table: return "<div class=\"table\"><table>\(children())</table></div>"
        case is Markdown.Table.Head: return "<thead><tr>\(children())</tr></thead>"
        case is Markdown.Table.Body: return "<tbody>\(children())</tbody>"
        case is Markdown.Table.Row: return "<tr>\(children())</tr>"
        case is Markdown.Table.Cell: return "<td>\(children())</td>"
        case let html as HTMLBlock: return safeHTML(html.rawHTML)
        case let html as InlineHTML: return safeHTML(html.rawHTML)
        default: return children()
        }
    }

    /// 未知标签成为可读文字，所有属性丢弃；源脚本、事件、iframe、SVG 永不执行。
    private static func safeHTML(_ raw: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]*>") else { return escape(raw) }
        let source = raw as NSString
        var end = 0
        var result = ""
        for match in regex.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
            result += escape(source.substring(with: NSRange(location: end, length: match.range.location - end)))
            let token = source.substring(with: match.range).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            switch token {
            case "<details>", "<details open>": result += token
            case "</details>", "<summary>", "</summary>", "<br>", "<br/>", "<br />": result += token
            default: result += escape(source.substring(with: match.range))
            }
            end = match.range.location + match.range.length
        }
        result += escape(source.substring(from: end))
        return result
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
        <style>html{color-scheme:\(dark ? "dark" : "light");overflow:hidden}body{margin:0;font:\(scale.scaled(16))px -apple-system;line-height:1.75;color:\(dark ? "#f5f5f7" : "#1d1d1f");overflow-wrap:anywhere}main{display:flow-root}h1,h2,h3{line-height:1.35;margin:1.5em 0 .6em}p{margin:.8em 0}a{color:#007aff}img{max-width:100%;height:auto}pre,.table{overflow-x:auto;max-width:100%}pre{padding:16px;background:\(dark ? "#2c2c2e" : "#f5f5f7");border-radius:8px}code{font:0.88em ui-monospace,monospace}table{border-collapse:collapse;width:100%}td,th{padding:8px 12px;border:1px solid \(dark ? "#444" : "#ddd")}blockquote{margin-left:0;padding-left:16px;border-left:3px solid #888}summary{cursor:pointer}details{padding:10px 0}</style></head>
        <body><main>\(html)</main><script nonce="\(session)">const content=document.querySelector("main");const send=()=>window.webkit.messageHandlers.dailyHeight.postMessage({session:"\(session)",height:Math.ceil(content.getBoundingClientRect().height)});new ResizeObserver(send).observe(content);window.addEventListener("load",send);document.addEventListener("toggle",send,true);send();</script></body></html>
        """
        webView.loadHTMLString(document, baseURL: nil)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "dailyHeight")
    }

    /// WebKit 内部滚动交给文章宿主，避免正文与原生项目列表形成两个纵向滚动区。
    final class PassthroughWebView: WKWebView {
        override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
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
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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
