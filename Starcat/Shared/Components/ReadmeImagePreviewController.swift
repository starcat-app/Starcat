//
//  ReadmeImagePreviewController.swift
//  Starcat
//
//  README 图片浏览器的窗口级宿主。只传递资源地址与当前索引，独立 WebView
//  继续使用 README 的图片浏览脚本与内容图片缓存，不移动原阅读器、不经 NSImage 转码，保留 GIF 动画。
//

import AppKit
import WebKit

/// 点击时冻结当前主题可见的图片顺序，避免浏览期间正文换源改变索引含义。
struct ReadmeImagePreviewRequest: Codable, Equatable {
    struct Image: Codable, Equatable {
        let src: String
        let alt: String
    }

    let images: [Image]
    let index: Int

    /// 桥接只接受完整的图片列表；不能丢弃单项后仍沿用原索引。
    init?(messageBody: Any) {
        guard let payload = messageBody as? [String: Any],
              let entries = payload["images"] as? [[String: String]],
              let index = payload["index"] as? Int,
              entries.indices.contains(index),
              entries.allSatisfy({ !($0["src"] ?? "").isEmpty }) else { return nil }
        images = entries.map { Image(src: $0["src"]!, alt: $0["alt"] ?? "") }
        self.index = index
    }
}

/// 在来源窗口的 AppKit 容器中覆盖三栏与标题栏，而不是挂到右侧 README 的父视图。
///
/// 原 WKWebView 保留 DOM、滚动位置与焦点。浏览层使用独立 WebView，以相同账户
/// 注册附件 scheme；关闭、换文档和拆除阅读器都显式移除 handler，避免循环持有。
@MainActor
final class ReadmeImagePreviewController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    nonisolated static let messageName = "readmeImagePreview"

    let webView: WKWebView
    private let backdrop = NSVisualEffectView()
    private weak var sourceView: NSView?
    private weak var previousFirstResponder: NSResponder?
    private var reduceMotion: Bool
    private var isClosing = false
    var onDismiss: () -> Void = {}

    init(
        request: ReadmeImagePreviewRequest,
        accountID: Int64?,
        isDark: Bool,
        interfaceScale: InterfaceScale,
        reduceMotion: Bool
    ) {
        self.reduceMotion = reduceMotion
        webView = WKWebView(
            frame: .zero,
            configuration: Self.configuration(request: request, accountID: accountID, reduceMotion: reduceMotion)
        )
        super.init()
        webView.configuration.userContentController.add(self, name: Self.messageName)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(
            ReadmeWebView.assembleDocument(fragment: "", isDark: isDark, interfaceScale: interfaceScale),
            baseURL: nil
        )
    }

    /// 同一份浏览脚本运行在独立文档中；JSON 放在 user script，绝不拼进 HTML 属性。
    /// 保持 internal，让无窗口测试也能验证生产配置与真实 WebKit 行为。
    static func configuration(
        request: ReadmeImagePreviewRequest,
        accountID: Int64?,
        reduceMotion: Bool,
        imageCache: ReadmeAttachmentImageCache = .shared
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            ReadmeAttachmentImageSchemeHandler(accountID: accountID, cache: imageCache),
            forURLScheme: ReadmeAttachmentImageURL.scheme
        )
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        ReadmeWebView.configureMediaPlayback(configuration)
        let payload = (try? JSONEncoder().encode(request)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            window.starcatImagePreviewRequest = \(payload);
            document.body.classList.add('readme-image-viewer');
            document.body.classList.toggle('readme-reduce-motion', \(reduceMotion));
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        configuration.userContentController.addUserScript(WKUserScript(
            source: ReadmeWebView.readmeEnhancementScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        return configuration
    }

    /// 布局锚定整个窗口容器，连同顶部工具栏一起覆盖，关闭浮层后恢复原窗口。
    func present(over contentView: NSView, restoringFocusTo sourceView: NSView) {
        self.sourceView = sourceView
        previousFirstResponder = sourceView.window?.firstResponder
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.alphaValue = 0
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.setAccessibilityElement(true)
        backdrop.setAccessibilityRole(.group)
        backdrop.setAccessibilityLabel(String.l10n("readme.imagePreview.title"))
        backdrop.setAccessibilityModal(true)
        webView.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(webView)
        // NSHostingView 会在 SwiftUI 状态更新时重排手工添加的子视图，可能把浮层压成零尺寸。
        // 将浮层放到内容视图的同级 AppKit 容器并覆盖其完整边界，避免顶部工具栏及底色露出。
        let container = contentView.superview ?? contentView
        container.addSubview(backdrop, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            webView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            webView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        sourceView.window?.makeFirstResponder(webView)
    }

    /// App 动效设置变更直接作用于当前浏览器，不重载图片。
    func updateReduceMotion(_ reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        webView.evaluateJavaScript("document.body.classList.toggle('readme-reduce-motion', \(reduceMotion));")
    }

    /// 先收口 WebKit 资源再淡出宿主；结束后回到原响应者，不改正文滚动位置。
    func dismiss(animated: Bool = true) {
        guard !isClosing else { return }
        isClosing = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
        // 显式保留主 actor 与 Sendable 约束，才能安全跨过 AppKit 的动画完成回调。
        let finish: @MainActor @Sendable () -> Void = { [self] in
            backdrop.removeFromSuperview()
            if let window = sourceView?.window {
                window.makeFirstResponder(previousFirstResponder ?? sourceView)
            }
            onDismiss()
        }
        guard animated && !reduceMotion else {
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            backdrop.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
    }

    /// DOM 已建立即可呈现骨架与控件，不等待图片下载完成；关闭消息只接受当前主文档。
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !isClosing, message.webView === webView, message.frameInfo.isMainFrame,
              let payload = message.body as? [String: Any],
              let visible = payload["visible"] as? Bool else { return }
        if visible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? 0 : 0.18
                backdrop.animator().alphaValue = 1
            }
        } else {
            dismiss()
        }
    }

    /// 只有 app-owned 空文档能导航，图片子资源仍交给 WebKit 和附件 scheme 加载。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dismiss(animated: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        dismiss(animated: false)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        dismiss(animated: false)
    }
}
