//
//  DailyRecommendationWebView.swift
//  Starcat
//
//  将本地每日发现页面嵌入透明覆盖层。原生发送完整展示快照，网页回传受限操作，
//  不复用 README 导航，也不让网页加载外部文档或持久化另一份业务状态。
//

import SwiftUI
import WebKit

/// WebKit 生命周期独立于推荐 Store；更新内容不能重新加载页面或丢失当前阅读位置。
struct DailyRecommendationWebView: NSViewRepresentable {
    let snapshot: DailyRecommendationWebSnapshot
    let onAction: (DailyRecommendationWebAction) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(snapshot: snapshot, onAction: onAction, onFailure: onFailure)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "dailyDiscovery")
        let web = WKWebView(frame: .zero, configuration: configuration)
        // 与项目现有 WebView 一致：首次文档提交前也保持透明，让 AppKit 材质采样真实主窗。
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "daily-discovery", withExtension: "html") {
            context.coordinator.initialURL = url
            web.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            let coordinator = context.coordinator
            DispatchQueue.main.async { coordinator.onFailure() }
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.snapshot = snapshot
        context.coordinator.onAction = onAction
        context.coordinator.onFailure = onFailure
        context.coordinator.flush()
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.ready = false
        coordinator.sendTask?.cancel()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "dailyDiscovery")
        web.evaluateJavaScript("window.starcatDiscovery?.destroy()")
        web.stopLoading()
        web.navigationDelegate = nil
    }

    /// weak WebView 打断 userContentController → handler → WebView 的保留环。
    /// 完整快照串行发送；发送期间产生的新快照合并为最新值，避免旧数据越过新数据。
    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var web: WKWebView?
        var snapshot: DailyRecommendationWebSnapshot
        var onAction: (DailyRecommendationWebAction) -> Void
        var onFailure: () -> Void
        var initialURL: URL?
        var ready = false
        var sendTask: Task<Void, Never>?
        private var sentSnapshot: DailyRecommendationWebSnapshot?
        private var sending = false
        private var initialNavigationAllowed = false

        init(snapshot: DailyRecommendationWebSnapshot,
             onAction: @escaping (DailyRecommendationWebAction) -> Void,
             onFailure: @escaping () -> Void) {
            self.snapshot = snapshot
            self.onAction = onAction
            self.onFailure = onFailure
        }

        /// 只接受本页面主 frame 的消息；动作解析再次校验账户/批次身份与真实候选 ID。
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView === web, message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any] else { return }
            if body["type"] as? String == "ready" {
                guard !ready else { return }
                ready = true
                flush()
                return
            }
            guard ready else { return }
            if body["type"] as? String == "error" { onFailure(); return }
            guard let action = DailyRecommendationWebAction(
                body: body, context: snapshot.context,
                allowedIDs: Set(snapshot.items.compactMap { Int64($0.id) })
            ) else { return }
            onAction(action)
        }

        /// 通过结构化参数传值，仓库简介中的引号、HTML 或脚本片段都只是文本。
        func flush() {
            guard ready, !sending, snapshot != sentSnapshot, let web else { return }
            let next = snapshot
            sending = true
            sendTask = Task { @MainActor [weak self, weak web] in
                guard let self, let web else { return }
                do {
                    let data = try JSONEncoder().encode(next)
                    let payload = try JSONSerialization.jsonObject(with: data)
                    _ = try await web.callAsyncJavaScript(
                        "window.starcatDiscovery.update(payload)",
                        arguments: ["payload": payload], in: nil, contentWorld: .page
                    )
                    guard !Task.isCancelled, ready else { return }
                    sentSnapshot = next
                    sending = false
                    flush()
                } catch {
                    sending = false
                    if !Task.isCancelled, ready { onFailure() }
                }
            }
        }

        /// 只放行一次初始本地文档；详情由原生回调打开，不在卡片 WebView 中导航。
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let allowed = !initialNavigationAllowed && navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.request.url == initialURL
            if allowed { initialNavigationAllowed = true }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 文档可能成功加载而脚本未初始化，必须提供重试入口，不能留下透明空页。
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    let initialized = try await webView.evaluateJavaScript("Boolean(window.starcatDiscovery)")
                    if initialized as? Bool == true {
                        // 本地页面装载后接收左右键与 S；不依赖用户先点击 WebView。
                        if webView.window?.isKeyWindow == true { webView.window?.makeFirstResponder(webView) }
                    } else { onFailure() }
                } catch {
                    onFailure()
                }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure() }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onFailure()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onFailure()
        }
    }
}
