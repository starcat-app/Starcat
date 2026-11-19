// 标签画布的离线 WebKit 桥。业务身份、选择和精确计数由 Swift 持有。
import SwiftUI
import WebKit

/// 明确传入快照和视角命令，使同一模型对象内部的更新也能送达 WebKit。
struct TagGraphCanvas: NSViewRepresentable {
    struct State: Equatable {
        let graph: TagGraphSnapshot
        let session: UUID
        let generation: Int
        let selected: [String]
        let minimum: Int
        let camera: Int
        let focus: String?
        let dark: Bool
        let reduced: Bool
    }
    let state: State
    let onSelect: (UUID, Int, [String]) -> Void
    let onPaint: () -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let bridge = context.coordinator
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(bridge, name: "tagGraph")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = bridge
        bridge.web = web
        if let url = Bundle.main.url(forResource: "tag-graph", withExtension: "html") {
            bridge.pageURL = url
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { DispatchQueue.main.async { onFailure() } }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        let bridge = context.coordinator
        bridge.onSelect = onSelect
        bridge.onPaint = onPaint
        bridge.onFailure = onFailure
        bridge.pending = state
        bridge.flush()
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.web = nil
        web.configuration.userContentController.removeScriptMessageHandler(forName: "tagGraph")
        web.evaluateJavaScript("window.tagGraph?.destroy()")
        web.stopLoading()
        web.navigationDelegate = nil
    }

    /// 每次只发送一帧，WebKit 忙时保留最新状态，元数据未变就不再编码图或图标。
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var web: WKWebView?
        var pageURL: URL?
        var pending: State?
        var onSelect: ((UUID, Int, [String]) -> Void)?
        var onPaint: (() -> Void)?
        var onFailure: (() -> Void)?
        private var delivered: State?
        private var ready = false
        private var sending = false
        private var loadedIcons = Set<String>()

        func flush() {
            guard ready, !sending, let web, let state = pending, state != delivered else { return }
            var args: [String: Any] = ["session": state.session.uuidString, "generation": state.generation,
                "selected": state.selected, "minimum": state.minimum, "dark": state.dark, "reduced": state.reduced,
                "camera": state.camera, "focus": state.focus as Any? ?? NSNull()]
            if state.graph != delivered?.graph {
                do { args["data"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.graph)) }
                catch { onFailure?(); return }
                var icons = [String: String]()
                for icon in state.graph.nodes.compactMap(\.icon) where loadedIcons.insert(icon).inserted {
                    guard let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil),
                          let data = image.withSymbolConfiguration(.init(pointSize: 25, weight: .medium))?.tiffRepresentation,
                          let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { continue }
                    icons[icon] = "data:image/png;base64," + png.base64EncodedString()
                }
                args["icons"] = icons
            }
            sending = true
            web.callAsyncJavaScript("window.tagGraph.apply(state)", arguments: ["state": args], in: nil, in: .page) { [weak self] result in
                guard let self, self.web != nil else { return }
                self.sending = false
                switch result {
                case .success: self.delivered = state; self.flush()
                case .failure: self.ready = false; self.onFailure?()
                }
            }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView === web, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            if kind == "ready" { ready = true; flush(); return }
            if kind == "painted" { onPaint?(); return }
            guard kind == "select", let raw = body["session"] as? String, let session = UUID(uuidString: raw),
                  let generation = body["generation"] as? Int, let ids = body["ids"] as? [String] else { return }
            onSelect?(session, generation, ids)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.targetFrame?.isMainFrame == true && action.request.url == pageURL ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 本地 HTML 可独立于 JS 成功加载，缺少产物也要给用户可恢复的失败状态。
            guard !ready else { return }
            webView.evaluateJavaScript("typeof window.tagGraph?.apply === 'function'") { [weak self] value, _ in
                guard let self, self.web != nil else { return }
                if value as? Bool == true { self.ready = true; self.flush() }
                else { self.onFailure?() }
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure?() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure?() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure?() }
    }
}
