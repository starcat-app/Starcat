//
//  ReadmeDocumentReadyWebKitTests.swift
//  StarcatTests
//
//  使用真实生产 Coordinator 与可控图片响应，验证正文交接不依赖整页 load。
//  不建立窗口、不截图、不访问网络；图片只有在测试明确放行后才结束。
//

import Foundation
import Testing
import WebKit
@testable import Starcat

/// 覆盖正文先于慢图片就绪，以及导航切换时旧信号不能触发新文档入场。
@MainActor
@Suite("README document ready WebKit", .serialized)
struct ReadmeDocumentReadyWebKitTests {
    @Test("正文在图片仍挂起时就绪，整页完成不重复回调")
    func readyBeforeImageFinishes() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.load("cached")
        try await fixture.wait("image request") { fixture.media.pending["/cached.gif"] != nil }
        try await fixture.wait("body ready") { fixture.readyDocuments == ["cached"] }

        let layout = try await fixture.webView.evaluateJavaScript("""
        ({
            text: document.querySelector('article h1').textContent,
            height: document.querySelector('article').getBoundingClientRect().height,
            imageComplete: document.querySelector('img').complete,
            readyState: document.readyState
        })
        """) as? [String: Any]
        #expect(layout?["text"] as? String == "cached")
        #expect((layout?["height"] as? NSNumber)?.doubleValue ?? 0 > 0)
        #expect(layout?["imageComplete"] as? Bool == false)
        #expect(layout?["readyState"] as? String != "complete")
        #expect(fixture.finishedDocuments.isEmpty)
        #expect(fixture.failedDocuments.isEmpty)

        try fixture.media.finish("/cached.gif")
        try await fixture.wait("navigation finished") { fixture.finishedDocuments == ["cached"] }
        #expect(fixture.readyDocuments == ["cached"])
        #expect(fixture.failedDocuments.isEmpty)
    }

    @Test("快速切文档忽略旧就绪信号，同一导航只交接一次")
    func ignoresStaleAndDuplicateReadySignals() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.load("A")
        try await fixture.wait { fixture.readyDocuments == ["A"] }
        let oldScript = try #require(fixture.webView.configuration.userContentController.userScripts.last?.source)

        // 先切换生产导航身份但保留旧 DOM，模拟旧文档消息晚于下一次加载准备到达。
        fixture.prepare("B")
        _ = try await fixture.webView.evaluateJavaScript(oldScript)
        fixture.loadPrepared("B")
        try await fixture.wait { fixture.readyDocuments.last == "B" }
        #expect(fixture.readyDocuments == ["A", "B"])

        let currentScript = try #require(fixture.webView.configuration.userContentController.userScripts.last?.source)
        _ = try await fixture.webView.evaluateJavaScript(currentScript)
        try await fixture.wait { fixture.media.pending["/B.gif"] != nil }
        try fixture.media.finish("/B.gif")
        try await fixture.wait { fixture.finishedDocuments == ["B"] }
        #expect(fixture.readyDocuments == ["A", "B"])
        #expect(fixture.failedDocuments.isEmpty)
    }
}

/// 直接挂接生产 Coordinator；仅观察 didFinish，不替换生产的 ready / failure 行为。
@MainActor
private final class DocumentFixture: NSObject, WKNavigationDelegate {
    let coordinator = ReadmeWebContentView.Coordinator()
    let media = PendingMedia()
    let webView: WKWebView
    var readyDocuments: [String] = []
    var failedDocuments: [String] = []
    var finishedDocuments: [String] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = coordinator.makeUserContentController()
        configuration.setURLSchemeHandler(media, forURLScheme: "starcat-ready-test")
        ReadmeWebView.configureMediaPlayback(configuration)
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        super.init()
        coordinator.webView = webView
        coordinator.onDocumentReady = { [weak self] in self?.readyDocuments.append($0) }
        coordinator.onDocumentFailed = { [weak self] in self?.failedDocuments.append($0) }
        webView.navigationDelegate = self
    }

    /// 与生产 loadIfNeeded 相同，先更新身份、重置桥接，再开始 HTML 导航。
    func prepare(_ documentID: String) {
        coordinator.lastLoadedKey = ReadmeKey(documentID: documentID, baseURL: nil, isDark: false, interfaceScale: .standard)
        coordinator.prepareForDocumentReload()
    }

    func load(_ documentID: String) {
        prepare(documentID)
        loadPrepared(documentID)
    }

    /// 使用生产 HTML 包装与可控图片源，让正文和整页加载具有独立的完成时机。
    func loadPrepared(_ documentID: String) {
        let html = ReadmeWebView.assembleDocument(
            fragment: """
            <h1>\(documentID)</h1><p>Cached README body</p>
            <img src="starcat-ready-test://fixture/\(documentID).gif" width="600" height="240">
            """,
            isDark: false
        )
        coordinator.expectsInitialLoad = true
        coordinator.documentNavigation = webView.loadHTMLString(html, baseURL: nil)
    }

    /// 等待实际事件，超时只用于判定失败；不靠固定延时决定正文就绪。
    func wait(_ phase: String = "document event", _ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let state = try? await webView.evaluateJavaScript("""
        ({
            readyState: document.readyState,
            imageComplete: document.querySelector('img')?.complete
        })
        """)
        throw NSError(domain: "ReadmeDocumentReady", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(phase): ready=\(readyDocuments), finished=\(finishedDocuments), pending=\(media.pending.keys.sorted()), DOM=\(String(describing: state))"
        ])
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        coordinator.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        coordinator.webView(webView, didFinish: navigation)
        if navigation === coordinator.documentNavigation, let documentID = coordinator.lastLoadedKey?.documentID {
            finishedDocuments.append(documentID)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        coordinator.webView(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        coordinator.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    /// 显式拆除 handler 以释放其对生产 Coordinator 的引用，取消测试的所有挂起请求。
    func close() {
        coordinator.stopMediaPlayback(stopLoading: true)
        coordinator.removeScriptMessageHandler()
        webView.navigationDelegate = nil
    }
}

/// 主线程上保存未完成的图片响应，避免网络快慢影响测试判定。
@MainActor
private final class PendingMedia: NSObject, WKURLSchemeHandler {
    var pending: [String: any WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        pending[urlSchemeTask.request.url!.path] = urlSchemeTask
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        pending.removeValue(forKey: urlSchemeTask.request.url!.path)
    }

    /// 固定 GIF 响应让整页最终完成，用于证明 didFinish 不会再次交接。
    func finish(_ path: String) throws {
        let pendingTask = pending.removeValue(forKey: path)
        let task = try #require(pendingTask)
        let data = try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "image/gif",
                                   expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }
}
