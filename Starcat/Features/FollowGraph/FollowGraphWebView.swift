//
//  FollowGraphWebView.swift
//  Starcat
//
//  离线渲染桥：只接受当前页面主 frame 的受控消息。GitHub 网络请求和所有业务规则
//  留在原生侧；JSON 通过 callAsyncJavaScript 参数传递，禁止字符串拼接执行。
//

import SwiftUI
import WebKit

/// 共用的离线 2D 画布。每个遮盖层有独立 WebKit 会话，数据由各自的宿主提供。
struct FollowGraphWebView: NSViewRepresentable {
    struct Input {
        /// 标签图没有中心账号。每个批次都携带相同的根，以区分两种交互语义。
        let rootID: String?
        var relation: FollowGraphRelation? = nil
        let revision: Int
        var selectedID: String? = nil
        var selectionRevision = 0
        var path: [String] = []
        var viewport: FollowGraphViewport? = nil
        var viewportRevision = 0
        var focusID: String? = nil
        var avatarUpdate: (revision: Int, id: String, source: String)? = nil
        // 只在图版本改变时编码节点和边。搜索、主题或计数变化不应遍历整图。
        let graph: () -> (nodes: [[String: Any]], links: [[String: String]])
    }

    struct Events {
        let isCurrent: () -> Bool
        let onPresented: () -> Void
        let onError: (Bool) -> Void
        var onSelect: ((String?) -> Input?)? = nil
        var onViewport: ((FollowGraphViewport) -> Void)? = nil
        var onProgress: ((Int, Int, Int, String?, Int, Int) -> Void)? = nil
    }

    let input: Input?
    let events: Events
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> Coordinator { Coordinator(events: events) }
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
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in coordinator?.reportFailure() }
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.input = input
        context.coordinator.events = events
        context.coordinator.dark = colorScheme == .dark
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.active = scenePhase == .active
        context.coordinator.flush()
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
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
        var input: Input?
        var events: Events
        var initialURL: URL?
        var ready = false
        var dark = false
        var reduceMotion = false
        var active = true
        private let session = UUID().uuidString
        private var invalidated = false
        private var sentRevision = -1
        private var sentSelection: String?
        private var sentSelectionRevision = -1
        private var sentAvatarRevision = 0
        private var sentViewportRevision = -1
        private var sentAppearance = ""
        private var initialNavigationAllowed = false
        private var sequence = 0
        private var pendingPayload: [String: Any] = [:]
        private var isSending = false

        init(events: Events) {
            self.events = events
        }

        private var isCurrent: Bool { !invalidated && events.isCurrent() }

        func invalidate() {
            invalidated = true
            ready = false
            pendingPayload = [:]
        }

        func reportFailure() {
            guard isCurrent else { return }
            events.onError(true)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isCurrent, message.webView === web, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" {
                guard !ready else { return }
                ready = true
                events.onError(false)
                flush()
                return
            }
            guard ready, body["session"] as? String == session else { return }
            switch type {
            case "presented":
                // ready 只表示脚本装载完成。宿主等真实首帧后才显示画布。
                events.onPresented()
            case "select":
                guard let onSelect = events.onSelect else { return }
                let id = body["id"] as? String
                guard id.map({ $0.count < 64 }) ?? (body["id"] is NSNull), let next = onSelect(id) else { return }
                // 关注者的卡片与路径同批更新。标签图的点击只在本地画布处理。
                input = next
                flush()
            case "viewport":
                if let values = body["value"] as? [Double],
                   let viewport = FollowGraphViewport(values: values) { events.onViewport?(viewport) }
            case "progress":
                if let nodes = body["nodes"] as? Int, let edges = body["edges"] as? Int,
                   let revision = body["revision"] as? Int,
                   let selectionRevision = body["selectionRevision"] as? Int,
                   let selectedCount = body["selectedCount"] as? Int,
                   body["selected"] is NSNull || body["selected"] is String {
                    events.onProgress?(nodes, edges, revision, body["selected"] as? String,
                                       selectionRevision, selectedCount)
                }
            case "error": reportFailure()
            default: break
            }
        }

        /// 每批数据最多一次序列化；选择、主题和视口指令不重复传整图。
        func flush() {
            guard ready, isCurrent, let input else { return }
            sequence += 1
            var payload: [String: Any] = ["session": session, "root": input.rootID as Any? ?? NSNull(), "sequence": sequence]
            if let update = input.avatarUpdate, sentAvatarRevision != update.revision {
                payload["avatarReady"] = ["id": update.id, "source": update.source, "revision": update.revision] as [String: Any]
                sentAvatarRevision = update.revision
            }
            if sentRevision != input.revision {
                payload["revision"] = input.revision
                payload["relation"] = input.relation?.rawValue
                let graph = input.graph()
                payload["nodes"] = graph.nodes
                payload["links"] = graph.links
                sentRevision = input.revision
            }
            // 标签图的数据库更新不得覆盖 Canvas 刚发生的点击。只有搜索会发送选择命令。
            if sentSelection != input.selectedID || sentSelectionRevision != input.selectionRevision ||
                (input.rootID != nil && payload["nodes"] != nil) {
                payload["selected"] = input.selectedID as Any? ?? NSNull()
                payload["selectionRevision"] = input.selectionRevision
                payload["path"] = input.path
                sentSelection = input.selectedID
                sentSelectionRevision = input.selectionRevision
            }
            if sentViewportRevision != input.viewportRevision {
                // 首帧没有显式指令时使用固定初始镜头；只有主动重置才发送空 focus 做全图适配。
                if sentViewportRevision != -1 || input.focusID != nil {
                    payload["focus"] = input.focusID as Any? ?? NSNull()
                }
                if sentViewportRevision == -1, let viewport = input.viewport {
                    payload["viewport"] = viewport.values
                }
                sentViewportRevision = input.viewportRevision
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
            guard ready, isCurrent, !isSending, !pendingPayload.isEmpty, let web else { return }
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
                    self?.reportFailure()
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
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reportFailure() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 构造 Canvas renderer 可能在 ready 消息之前失败；避免留下没有恢复入口的空画布。
            Task { @MainActor [weak self, weak webView] in
                guard let webView else { return }
                let initialized = try? await webView.evaluateJavaScript("Boolean(window.followGraph)")
                if initialized as? Bool != true { self?.reportFailure() }
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportFailure()
        }
    }
}
