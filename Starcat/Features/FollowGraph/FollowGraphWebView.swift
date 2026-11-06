//
//  FollowGraphWebView.swift
//  Starcat
//
//  离线渲染桥：只接受当前页面主 frame 的受控消息。GitHub 网络请求和所有业务规则
//  留在原生侧；JSON 通过 callAsyncJavaScript 参数传递，禁止字符串拼接执行。
//

import SwiftUI
import WebKit

/// 一个遮盖层对应一个临时 WebView，缓存与会话视口由外部模型持有。
struct FollowGraphWebView: NSViewRepresentable {
    @Bindable var model: FollowGraphViewModel
    // 显式值输入让 SwiftUI 比较真正的渲染身份，而非只比较同一个引用模型。
    let graphRevision: Int
    let selectionID: String?
    let viewportRevision: Int
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.avatars, forURLScheme: FollowGraphAvatarURL.scheme)
        configuration.userContentController.add(context.coordinator, name: "followGraph")
        let web = WKWebView(frame: .zero, configuration: configuration)
        // 复用 README WebView 的透明底色策略，文档首次提交前不绘制 WebKit 默认白底。
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "follow-graph", withExtension: "html") {
            context.coordinator.initialURL = url
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async { model.rendererError = true }
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.model = model
        context.coordinator.dark = colorScheme == .dark
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.active = scenePhase == .active
        context.coordinator.flush()
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.ready = false
        coordinator.avatars.cancelAll()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "followGraph")
        web.evaluateJavaScript("window.followGraph?.destroy()")
        web.stopLoading()
        web.navigationDelegate = nil
    }

    /// Coordinator 不持有 WebView；避免 userContentController → handler → web 的保留环。
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var web: WKWebView?
        let avatars = FollowGraphAvatarSchemeHandler()
        var model: FollowGraphViewModel
        var initialURL: URL?
        var ready = false
        var dark = false
        var reduceMotion = false
        var active = true
        private let session = UUID().uuidString
        private var sentRevision = -1
        private var sentSelection: String?
        private var sentViewportRevision = -1
        private var sentAppearance = ""
        private var initialNavigationAllowed = false
        private var sequence = 0
        private var pendingPayload: [String: Any] = [:]
        private var isSending = false

        init(model: FollowGraphViewModel) { self.model = model }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView === web, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" {
                guard !ready else { return }
                ready = true
                model.rendererError = false
                flush()
                return
            }
            guard ready, body["session"] as? String == session else { return }
            switch type {
            case "presented":
                // ready 只表示脚本已装载；必须等主题、数据和本人节点的首帧绘制完成才显示。
                model.rendererPresented = true
            case "select":
                if let id = body["id"] as? String, id.count < 64, model.snapshot?.nodes[id] != nil {
                    model.select(id, expand: true)
                } else if body["id"] is NSNull { model.select(nil, expand: false) }
                // 文本卡片与 WebView 必须同批更新完整路径，不依赖宿主下一次重算。
                flush()
            case "viewport":
                if let values = body["value"] as? [Double],
                   let viewport = FollowGraphViewport(values: values) { model.viewport = viewport }
            case "progress":
                if let nodes = body["nodes"] as? Int, let edges = body["edges"] as? Int,
                   let revision = body["revision"] as? Int {
                    model.reportRenderedCounts(nodes: nodes, edges: edges, revision: revision)
                }
            case "error": model.rendererError = true
            default: break
            }
        }

        /// 每批数据最多一次序列化；选择、主题和视口指令不重复传整图。
        func flush() {
            guard ready, let snapshot = model.displayedSnapshot else { return }
            sequence += 1
            var payload: [String: Any] = ["session": session, "root": snapshot.rootID, "sequence": sequence]
            if sentRevision != model.revision {
                payload["revision"] = model.revision
                payload["nodes"] = snapshot.nodes.values.map {
                    ["id": $0.id, "login": $0.login, "name": $0.name ?? $0.login,
                     "avatar": FollowGraphAvatarURL.source($0.avatarURL)] as [String: Any]
                }
                payload["links"] = snapshot.edges.map { ["source": $0.source, "target": $0.target] }
                sentRevision = model.revision
            }
            if sentSelection != model.selectedID || payload["nodes"] != nil {
                payload["selected"] = model.selectedID as Any? ?? NSNull()
                payload["path"] = model.path
                sentSelection = model.selectedID
            }
            if sentViewportRevision != model.viewportRevision {
                // 首帧没有显式指令时使用固定初始镜头；只有主动重置才发送空 focus 做全图适配。
                if sentViewportRevision != -1 || model.focusID != nil {
                    payload["focus"] = model.focusID as Any? ?? NSNull()
                }
                if sentViewportRevision == -1, let viewport = model.viewport {
                    payload["viewport"] = viewport.values
                }
                sentViewportRevision = model.viewportRevision
            }
            let appearance = "\(dark)-\(reduceMotion)-\(active)"
            if appearance != sentAppearance {
                payload["dark"] = dark
                payload["reduceMotion"] = reduceMotion
                payload["active"] = active
                sentAppearance = appearance
            }
            // 合并尚未发出的字段并串行发送，防止较新的选择消息越过包含节点的旧批次。
            // 仅靠序号丢弃旧消息会同时丢掉那批节点，因此不能并发调用渲染桥。
            // 坐标更新仅影响 SwiftUI 浮层，不能反向触发空批次形成桥接重绘循环。
            guard payload.count > 3 else { return }
            pendingPayload.merge(payload) { _, new in new }
            sendNext()
        }

        private func sendNext() {
            guard ready, !isSending, !pendingPayload.isEmpty, let web else { return }
            let payload = pendingPayload
            pendingPayload = [:]
            isSending = true
            Task { @MainActor [weak self, weak web] in
                guard let web else { return }
                do {
                    _ = try await web.callAsyncJavaScript(
                        "window.followGraph.update(payload)", arguments: ["payload": payload],
                        in: nil, contentWorld: .page
                    )
                } catch {
                    self?.model.rendererError = true
                }
                self?.isSending = false
                self?.sendNext()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let allowed = !initialNavigationAllowed && navigationAction.targetFrame?.isMainFrame == true &&
                navigationAction.request.url == initialURL
            if allowed { initialNavigationAllowed = true }
            decisionHandler(allowed ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { model.rendererError = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 构造 Canvas renderer 可能在 ready 消息之前失败；避免留下没有恢复入口的空画布。
            Task { @MainActor [weak self, weak webView] in
                guard let webView else { return }
                let initialized = try? await webView.evaluateJavaScript("Boolean(window.followGraph)")
                if initialized as? Bool != true { self?.model.rendererError = true }
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            model.rendererError = true
        }
    }
}
