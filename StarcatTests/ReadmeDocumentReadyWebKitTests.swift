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
    @Test("本机 Skill 正文就绪但不启动图片附件请求")
    func localTextOnlyDoesNotLoadImages() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.prepare("local")
        fixture.coordinator.lastLoadedKey?.resourcePolicy = .localTextOnly
        fixture.loadPrepared("local")
        try await fixture.wait("local body ready") { fixture.readyDocuments == ["local"] }
        try await fixture.wait("local navigation finished") { fixture.finishedDocuments == ["local"] }
        // 复用生产 HTML/CSP 与真实 WebKit；自定义 scheme 能直接观察有没有开始读附件。
        #expect(fixture.media.pending.isEmpty)
        #expect(fixture.failedDocuments.isEmpty)
        let size = try await fixture.webView.evaluateJavaScript("getComputedStyle(document.querySelector('article p')).fontSize") as? String
        #expect(size == "16px")
    }

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

    @Test("无翻译消费者时正文就绪不提取也不上桥")
    func skipsTranslationWithoutConsumer() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.load("plain", fragment: "<p>README body with <em>inline text</em></p>")
        try await fixture.wait { fixture.finishedDocuments == ["plain"] }

        let extraction = try await fixture.webView.evaluateJavaScript("""
        ({ walks: window.readmeTestWalks, clones: window.readmeTestDeepClones,
           hasSegmentTargets: !!window.starcatReadmeSegmentElements,
           hasFullTargets: !!window.starcatReadmeFullTextNodes })
        """) as? [String: Any]
        #expect(extraction?["walks"] as? Int == 0)
        #expect(extraction?["clones"] as? Int == 0)
        #expect(extraction?["hasSegmentTargets"] as? Bool == false)
        #expect(extraction?["hasFullTargets"] as? Bool == false)
        #expect(fixture.translationMessages.isEmpty)
    }

    /// 构造一条可见的译文渲染状态，供各用例按需选择模式 / 目标 ID / 版本。
    private func visibleState(
        mode: ReadmeTranslationMode,
        id: String,
        text: String,
        revision: Int
    ) -> ReadmeTranslationRenderState {
        ReadmeTranslationRenderState(
            isVisible: true,
            mode: mode,
            translations: [ReadmeRenderedTranslation(id: id, translatedText: text)],
            revision: revision,
            prefersAnimatedEntrance: false
        )
    }

    @Test("分段消费者只建分段 targets，桥接只携带分段原文")
    func extractsSegmentedOnlyForSegmentedConsumer() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.coordinator.updateTranslationConsumerMode(.segmented)
        fixture.load("seg-only", fragment: "<h1>标题甲</h1><p>分段正文内容</p>")
        try await fixture.wait { fixture.readyDocuments == ["seg-only"] }
        try await fixture.wait { !fixture.translationMessages.isEmpty }

        let extraction = try await fixture.webView.evaluateJavaScript("""
        ({ walks: window.readmeTestWalks, clones: window.readmeTestDeepClones,
           segmentTargets: Object.keys(window.starcatReadmeSegmentElements || {}).length,
           fullTargets: Object.keys(window.starcatReadmeFullTextNodes || {}).length })
        """) as? [String: Any]
        // 分段走候选块克隆，不碰 TreeWalker；另一模式的 targets 必须保持为空。
        #expect(extraction?["walks"] as? Int == 0)
        #expect((extraction?["clones"] as? Int ?? 0) > 0)
        #expect(extraction?["segmentTargets"] as? Int == 2)
        #expect(extraction?["fullTargets"] as? Int == 0)

        let message = try #require(fixture.translationMessages.last)
        #expect(message["mode"] as? String == "segmented")
        #expect(message["segmented"] == nil && message["full"] == nil)
        #expect((message["request"] as? NSNumber)?.intValue == fixture.coordinator.translationRequestID)
        let items = try #require(message["items"] as? [[String: Any]])
        #expect(items.count == 2)
        #expect((items.first?["id"] as? String)?.hasPrefix("starcat-readme-segment-") == true)
    }

    @Test("全文消费者只走树遍历，不克隆候选块")
    func extractsFullOnlyForFullConsumer() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.coordinator.updateTranslationConsumerMode(.full)
        fixture.load("full-only", fragment: "<h1>标题乙</h1><p>全文正文内容</p>")
        try await fixture.wait { fixture.readyDocuments == ["full-only"] }
        try await fixture.wait { !fixture.translationMessages.isEmpty }

        let extraction = try await fixture.webView.evaluateJavaScript("""
        ({ walks: window.readmeTestWalks, clones: window.readmeTestDeepClones,
           segmentTargets: Object.keys(window.starcatReadmeSegmentElements || {}).length,
           fullTargets: Object.keys(window.starcatReadmeFullTextNodes || {}).length })
        """) as? [String: Any]
        // 全文走 TreeWalker；候选块深克隆一次都不该发生。
        #expect((extraction?["walks"] as? Int ?? 0) >= 1)
        #expect(extraction?["clones"] as? Int == 0)
        #expect(extraction?["segmentTargets"] as? Int == 0)
        #expect(extraction?["fullTargets"] as? Int == 2)

        let message = try #require(fixture.translationMessages.last)
        #expect(message["mode"] as? String == "full")
        let items = try #require(message["items"] as? [[String: Any]])
        #expect(items.count == 2)
        #expect((items.first?["id"] as? String)?.hasPrefix("starcat-readme-text-") == true)
    }

    @Test("同一导航内切模式先恢复原文再按新模式重抽")
    func switchingModeRestoresOriginalDOMAndReextracts() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.coordinator.updateTranslationConsumerMode(.segmented)
        fixture.load("mode-switch", fragment: "<h1>切换标题</h1><p>切换正文段落</p>")
        try await fixture.wait { fixture.readyDocuments == ["mode-switch"] }
        try await fixture.wait { fixture.translationMessages.first?["mode"] as? String == "segmented" }

        // 应用分段可见译文，确认译文行确实上屏（候选：h1=seg-0、p=seg-1）。
        fixture.coordinator.updateTranslationRenderState(
            visibleState(mode: .segmented, id: "starcat-readme-segment-1", text: "切换后的段落译文", revision: 1),
            reduceMotion: true
        )
        try await fixture.wait {
            (try? await fixture.webView.evaluateJavaScript(
                "document.querySelectorAll('.starcat-readme-translation').length"
            )) as? Int == 1
        }

        // 切到全文：旧译文行必须先删掉，不能从译文 DOM 上重抽原文。
        fixture.coordinator.updateTranslationConsumerMode(.full)
        try await fixture.wait { fixture.translationMessages.last?["mode"] as? String == "full" }
        let dom = try await fixture.webView.evaluateJavaScript("""
        ({ lines: document.querySelectorAll('.starcat-readme-translation').length,
           fullTargets: Object.keys(window.starcatReadmeFullTextNodes || {}).length,
           segmentTargets: Object.keys(window.starcatReadmeSegmentElements || {}).length })
        """) as? [String: Any]
        #expect(dom?["lines"] as? Int == 0)
        #expect((dom?["fullTargets"] as? Int ?? 0) >= 1)
        #expect(dom?["segmentTargets"] as? Int == 0)
    }

    @Test("缓存译文等待当前模式 targets 就绪后回放")
    func cachedTranslationsWaitForTargets() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.coordinator.updateTranslationConsumerMode(.full)
        // 页面尚未加载：可见状态因 targets 未就绪被挂起；若 revision 此时被记账，
        // 正文就绪后会把「已应用」误判为跳过，译文永远回放不了（旧实现的红线）。
        fixture.coordinator.updateTranslationRenderState(
            visibleState(mode: .full, id: "starcat-readme-text-0", text: "缓存好的标题", revision: 1),
            reduceMotion: true
        )
        fixture.load("cached-apply", fragment: "<h1>原始标题</h1><p>原始正文段落</p>")
        try await fixture.wait { fixture.readyDocuments == ["cached-apply"] }
        try await fixture.wait { !fixture.translationMessages.isEmpty }

        // targets 就绪后挂起状态自动回放：轮询到译文替换 h1 原文为止。
        try await fixture.wait {
            (try? await fixture.webView.evaluateJavaScript(
                "document.querySelector('article h1')?.textContent"
            )) as? String == "缓存好的标题"
        }
        let wrapped = try await fixture.webView.evaluateJavaScript(
            "!!document.querySelector('.starcat-readme-full-target')"
        ) as? Bool
        #expect(wrapped == true)
    }

    @Test("模式往返后同一 revision 的译文重新回放")
    func modeRoundTripReplaysSameRevision() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.coordinator.updateTranslationConsumerMode(.full)
        fixture.load("round-trip", fragment: "<h1>原始标题</h1><p>原始正文段落</p>")
        try await fixture.wait { fixture.readyDocuments == ["round-trip"] }
        try await fixture.wait { !fixture.translationMessages.isEmpty }

        // 显示译文并确认上屏（VM 缓存命中发布的 revision 恒为 1）。
        fixture.coordinator.updateTranslationRenderState(
            visibleState(mode: .full, id: "starcat-readme-text-0", text: "往返标题译文", revision: 1),
            reduceMotion: true
        )
        try await fixture.wait {
            (try? await fixture.webView.evaluateJavaScript(
                "document.querySelector('article h1')?.textContent"
            )) as? String == "往返标题译文"
        }

        // 源码↔渲染往返：nil 只作废请求（不发提取），切回 full 才重建 targets。
        // 旧实现保留「revision 1 已应用」记账，切回后同一 revision 被挡住，译文消失。
        fixture.coordinator.updateTranslationConsumerMode(nil)
        fixture.coordinator.updateTranslationConsumerMode(.full)
        try await fixture.wait {
            (try? await fixture.webView.evaluateJavaScript(
                "document.querySelector('article h1')?.textContent"
            )) as? String == "原始标题"
        }
        try await fixture.wait { fixture.translationMessages.count == 2 }

        // 消费者用同一 revision 重新发布可见状态：记账已清零，必须再次回放。
        fixture.coordinator.updateTranslationRenderState(
            visibleState(mode: .full, id: "starcat-readme-text-0", text: "往返标题译文", revision: 1),
            reduceMotion: true
        )
        try await fixture.wait {
            (try? await fixture.webView.evaluateJavaScript(
                "document.querySelector('article h1')?.textContent"
            )) as? String == "往返标题译文"
        }
    }

    @Test("旧导航令牌、旧序号或旧模式的翻译源消息不覆盖当前快照")
    func discardsStaleTranslationSourceMessages() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.coordinator.updateTranslationConsumerMode(.segmented)
        // 正常提取的交付走主 actor 异步 Task，可能晚于 translationMessages 的记录；
        // load 前先把交付接到独立数组并等它落地，再切换回调做迟到断言，
        // 否则正常快照会混进下方 snapshots，让 isEmpty 判定变成时序竞态。
        var deliveredSnapshots: [ReadmeTranslationSourceSnapshot] = []
        fixture.coordinator.onTranslationSourceChange = { deliveredSnapshots.append($0) }
        fixture.load("stale-msg", fragment: "<h1>丢弃标题</h1><p>丢弃正文段落</p>")
        try await fixture.wait { fixture.readyDocuments == ["stale-msg"] }
        try await fixture.wait { !deliveredSnapshots.isEmpty }

        var snapshots: [ReadmeTranslationSourceSnapshot] = []
        fixture.coordinator.onTranslationSourceChange = { snapshots.append($0) }
        let token = try await fixture.webView.evaluateJavaScript(
            "document.body.dataset.readmeDocumentToken"
        ) as? String
        let currentRequest = fixture.coordinator.translationRequestID

        // 从页面侧注入三类迟到消息：旧请求序号、旧模式、伪造导航令牌。
        func post(_ payload: String) async {
            _ = try? await fixture.webView.evaluateJavaScript(
                "window.webkit.messageHandlers.readmeTranslationSource.postMessage(\(payload));"
            )
        }
        await post("{ token: '\(token ?? "")', mode: 'segmented', request: \(currentRequest - 1), items: [] }")
        await post("{ token: '\(token ?? "")', mode: 'full', request: \(currentRequest), items: [] }")
        await post("{ token: 'wrong-token', mode: 'segmented', request: \(currentRequest), items: [] }")
        // 全部真实到达 Coordinator 后快照仍为空，说明三类身份校验都拒绝了交付。
        try await fixture.wait { fixture.translationMessages.count == 4 }
        #expect(snapshots.isEmpty)

        // 当前身份（同一导航令牌 + 当前序号 + 当前模式）的合法消息才交付，
        // 且快照只填消费者选择的模式。
        await post("""
        { token: '\(token ?? "")', mode: 'segmented', request: \(currentRequest),
          items: [{ id: 'starcat-readme-segment-0', text: '合法段落文本' }] }
        """)
        try await fixture.wait { snapshots.count == 1 }
        #expect(snapshots[0].segmented.count == 1)
        #expect(snapshots[0].full.isEmpty)
    }

    @Test("分段提取到达 2000 候选上限即停")
    func segmentedExtractionStopsAtQuota() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        let paragraphs = (0..<2_010).map { "<p>段落\($0)的正文文本</p>" }.joined()
        fixture.coordinator.updateTranslationConsumerMode(.segmented)
        fixture.load("seg-quota", fragment: paragraphs)
        try await fixture.wait { fixture.readyDocuments == ["seg-quota"] }
        try await fixture.wait { !fixture.translationMessages.isEmpty }

        let message = try #require(fixture.translationMessages.last)
        let items = try #require(message["items"] as? [[String: Any]])
        #expect(items.count == 2_000)
        #expect(items.last?["id"] as? String == "starcat-readme-segment-1999")
        #expect((message["request"] as? NSNumber)?.intValue == fixture.coordinator.translationRequestID)
    }

    @Test("超长候选占名额但跳号，后续合法项保留原 DOM 序号")
    func oversizedSegmentKeepsSlotWithoutSending() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        // 20,001 个字素：超出 20,000 上限，占名额但不进发送列表。
        let oversized = String(repeating: "超", count: 20_001)
        let fragment = "<p>合法段落一号</p><p>\(oversized)</p><p>合法段落二号</p>"
        fixture.coordinator.updateTranslationConsumerMode(.segmented)
        fixture.load("seg-skip", fragment: fragment)
        try await fixture.wait { fixture.readyDocuments == ["seg-skip"] }
        try await fixture.wait { !fixture.translationMessages.isEmpty }

        let message = try #require(fixture.translationMessages.last)
        let items = try #require(message["items"] as? [[String: Any]])
        // 中间的超长项消耗 slot 1；首尾合法项保留 0 与 2，不补位。
        #expect(items.compactMap { $0["id"] as? String } == [
            "starcat-readme-segment-0", "starcat-readme-segment-2"
        ])
        #expect(items.first?["text"] as? String == "合法段落一号")
        #expect(items.last?["text"] as? String == "合法段落二号")
    }

    @Test("全文提取到达 8000 文本节点上限即停")
    func fullExtractionStopsAtQuota() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        let paragraphs = (0..<8_010).map { "<p>节点\($0)</p>" }.joined()
        fixture.coordinator.updateTranslationConsumerMode(.full)
        fixture.load("full-quota", fragment: paragraphs)
        try await fixture.wait { fixture.readyDocuments == ["full-quota"] }
        try await fixture.wait { !fixture.translationMessages.isEmpty }

        let message = try #require(fixture.translationMessages.last)
        let items = try #require(message["items"] as? [[String: Any]])
        #expect(items.count == 8_000)
        #expect(items.last?["id"] as? String == "starcat-readme-text-7999")
    }

    @Test("图片浏览请求只接受当前文档的完整列表与有效索引")
    func imagePreviewRequestFollowsCurrentDocument() async throws {
        let fixture = DocumentFixture()
        defer { fixture.close() }
        fixture.load("A")
        try await fixture.wait { fixture.readyDocuments == ["A"] && fixture.media.pending["/A.gif"] != nil }
        let oldToken = try #require(
            try await fixture.webView.evaluateJavaScript("document.body.dataset.readmeDocumentToken") as? String
        )
        let images = [["src": "starcat-ready-test://fixture/A.gif", "alt": "Diagram"]]
        let oldPayload: [String: Any] = ["token": oldToken, "images": images, "index": 0]
        let request = try #require(fixture.coordinator.imagePreviewRequest(from: oldPayload))
        #expect(request.index == 0)
        #expect(request.images.first?.src == images[0]["src"])
        #expect(request.images.first?.alt == "Diagram")
        #expect(fixture.coordinator.imagePreviewRequest(from: [
            "token": oldToken, "images": images, "index": 1
        ]) == nil)
        #expect(fixture.coordinator.imagePreviewRequest(from: [
            "token": oldToken, "images": [["alt": "Missing source"]], "index": 0
        ]) == nil)

        // 旧 DOM 的点击可能晚于下一次加载准备到达，不能在新文档上打开旧图片。
        fixture.prepare("B")
        #expect(fixture.coordinator.imagePreviewRequest(from: oldPayload) == nil)
        fixture.loadPrepared("B")
        try await fixture.wait { fixture.readyDocuments == ["A", "B"] }
        let currentToken = try #require(
            try await fixture.webView.evaluateJavaScript("document.body.dataset.readmeDocumentToken") as? String
        )
        #expect(currentToken != oldToken)
        #expect(fixture.coordinator.imagePreviewRequest(from: oldPayload) == nil)
        #expect(fixture.coordinator.imagePreviewRequest(from: [
            "token": currentToken, "images": [["src": "starcat-ready-test://fixture/B.gif"]], "index": 0
        ]) != nil)

        fixture.coordinator.updateTranslationRenderState(.hidden, reduceMotion: true)
        let reduced = try await fixture.webView.evaluateJavaScript(
            "document.body.classList.contains('readme-reduce-motion')"
        ) as? Bool
        #expect(reduced == true)
    }
}

/// 直接挂接生产 Coordinator；仅观察 didFinish，不替换生产的 ready / failure 行为。
@MainActor
private final class DocumentFixture: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let coordinator = ReadmeWebContentView.Coordinator()
    let media = PendingMedia()
    let webView: WKWebView
    var readyDocuments: [String] = []
    var failedDocuments: [String] = []
    var finishedDocuments: [String] = []
    var translationMessages: [[String: Any]] = []
    private static let translationMessageName = "readmeTranslationSource"

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
        // 在 Swift 截断前观察真实桥接消息，再转交生产 Coordinator。
        let controller = configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.translationMessageName)
        controller.add(self, name: Self.translationMessageName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let payload = message.body as? [String: Any] {
            translationMessages.append(payload)
        }
        coordinator.userContentController(userContentController, didReceive: message)
    }

    /// 与生产 loadIfNeeded 相同，先更新身份、重置桥接，再开始 HTML 导航。
    func prepare(_ documentID: String) {
        coordinator.lastLoadedKey = ReadmeKey(documentID: documentID, baseURL: nil, isDark: false, interfaceScale: .standard)
        coordinator.prepareForDocumentReload()
    }

    func load(_ documentID: String, fragment: String? = nil) {
        prepare(documentID)
        loadPrepared(documentID, fragment: fragment)
    }

    /// 使用生产 HTML 包装与可控图片源，让正文和整页加载具有独立的完成时机。
    func loadPrepared(_ documentID: String, fragment: String? = nil) {
        if fragment != nil {
            // 从 document-start 观察实际扫描和深克隆，区分「没提取」和「提取了但没发送」。
            webView.configuration.userContentController.addUserScript(WKUserScript(source: """
            window.readmeTestWalks = 0;
            window.readmeTestDeepClones = 0;
            const createTreeWalker = document.createTreeWalker;
            document.createTreeWalker = function(...args) {
                window.readmeTestWalks++;
                return createTreeWalker.apply(this, args);
            };
            const cloneNode = Node.prototype.cloneNode;
            Node.prototype.cloneNode = function(deep) {
                if (deep) window.readmeTestDeepClones++;
                return cloneNode.call(this, deep);
            };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let html = ReadmeWebView.assembleDocument(
            fragment: fragment ?? """
            <h1>\(documentID)</h1><p>Cached README body</p>
            <img src="starcat-ready-test://fixture/\(documentID).gif" width="600" height="240">
            """,
            isDark: false,
            resourcePolicy: coordinator.lastLoadedKey?.resourcePolicy ?? .repository
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

    /// 等待需要查询页面 JS / DOM 的条件；查询抛错按未成立继续轮询。
    /// 与同步版共存：闭包里出现 await 时自动选择本重载。
    func wait(_ phase: String = "js condition", _ condition: () async -> Bool) async throws {
        for _ in 0..<150 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ReadmeDocumentReady", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "\(phase): ready=\(readyDocuments), finished=\(finishedDocuments), messages=\(translationMessages.count)"
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
