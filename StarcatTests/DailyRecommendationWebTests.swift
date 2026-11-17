//
//  DailyRecommendationWebTests.swift
//  StarcatTests
//
//  检查网页与原生的展示边界，不创建窗口或执行 GUI 自动化。
//  覆盖跨批次点击、未推荐 ID、Int64 精度、缺失字段与打包后的页面资源。
//

import Foundation
import Testing
import WebKit
@testable import Starcat

@Suite("每日发现网页契约")
@MainActor
struct DailyRecommendationWebTests {
    @Test("当前候选可以触发原生操作", arguments: ["presented", "star", "details", "dismiss"])
    func acceptsCurrentItem(type: String) {
        let action = DailyRecommendationWebAction(
            body: ["type": type, "context": "account/batch", "id": "42"],
            context: "account/batch", allowedIDs: [42]
        )
        #expect(action != nil)
    }

    @Test("旧账号或旧批次操作被拒绝", arguments: ["presented", "star", "details", "dismiss", "nextBatch", "autoShow"])
    func rejectsStaleContext(type: String) {
        let action = DailyRecommendationWebAction(
            body: ["type": type, "context": "old-account", "id": "42", "value": true],
            context: "new-account", allowedIDs: [42]
        )
        #expect(action == nil)
    }

    @Test("网页不能指定非候选仓库或不精确的数字 ID", arguments: [
        ["type": "star", "context": "c", "id": "999"],
        ["type": "details", "context": "c", "id": "<script>"],
        ["type": "dismiss", "context": "c", "fullName": "other/repo"],
        ["type": "fetch", "context": "c", "id": "42"]
    ])
    func rejectsUntrustedItem(body: [String: String]) {
        #expect(DailyRecommendationWebAction(body: body, context: "c", allowedIDs: [42]) == nil)
    }

    @Test("数字 ID 不经 Double 转换，非法开关值不被当成确认")
    func rejectsInvalidPayloadTypes() {
        #expect(DailyRecommendationWebAction(
            body: ["type": "star", "context": "c", "id": 42], context: "c", allowedIDs: [42]
        ) == nil)
        #expect(DailyRecommendationWebAction(
            body: ["type": "autoShow", "context": "c", "value": "false"], context: "c", allowedIDs: []
        ) == nil)
        #expect(DailyRecommendationWebAction(
            body: ["type": "autoShow", "context": "c", "value": false], context: "c", allowedIDs: []
        ) == .setAutoShow(false))
    }

    @Test("Int64 ID、原始描述和统计在序列化后完整保留")
    func preservesDataWithoutGeneratedClaims() throws {
        let id: Int64 = 9_007_199_254_740_993
        let description = #"<img src=x onerror="alert(1)"> "quoted" \ text"#
        let item = candidate(id: id, description: description)
        let payload = DailyRecommendationWebSnapshot.Item(item, revealed: true)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(object["id"] as? String == String(id))
        #expect(object["description"] as? String == description)
        #expect(object["stars"] as? Int == 123)
        #expect(object["forks"] as? Int == 7)
        #expect(object["coverImageURL"] == nil)
        #expect(object["coverImageDataURI"] == nil)
        #expect(object["score"] == nil)
        #expect(object["source"] == nil)
        #expect(object["signals"] == nil)
        #expect(object["summary"] == nil)
        #expect(DailyRecommendationWebAction(
            body: ["type": "star", "context": "c", "id": String(id)], context: "c", allowedIDs: [id]
        ) == .star(id))
    }

    @Test("卡面只传已准备图片，不构造远端请求")
    func coverUsesOwnerAvatar() {
        let dataURI = "data:image/png;base64,cHJlcGFyZWQ="
        let original = DailyRecommendationWebSnapshot.Item(
            candidate(fullName: "qbittorrent/qBittorrent"), revealed: false, coverImageDataURI: dataURI
        )
        let refreshed = DailyRecommendationWebSnapshot.Item(
            candidate(fullName: "qbittorrent/qBittorrent"), revealed: true, explanation: "updated",
            coverImageDataURI: dataURI
        )
        let failed = DailyRecommendationWebSnapshot.Item(
            candidate(fullName: "qbittorrent/qBittorrent"), revealed: false
        )
        #expect(original.coverImageDataURI == dataURI)
        #expect(original.coverImageDataURI == refreshed.coverImageDataURI)
        #expect(failed.coverImageDataURI == nil)
    }

    @Test("缺失仓库路径时封面回退，不构造无效图片请求", arguments: ["", "owner", "/project", "owner/"])
    func missingCoverPath(fullName: String) {
        let item = DailyRecommendationWebSnapshot.Item(candidate(fullName: fullName), revealed: false)
        #expect(item.coverImageDataURI == nil)
        #expect(DailyRecommendationAvatarStore.imageURL(for: candidate(fullName: fullName)) == nil)
    }

    @Test("空简介与未知理由不补写个性化证据")
    func missingMetadata() {
        let item = DailyRecommendationWebSnapshot.Item(
            candidate(description: nil, reasons: ["unknown <script>"]), revealed: false
        )
        #expect(item.description.isEmpty)
        #expect(item.language == nil)
        #expect(item.reason == String.l10n("recommendations.daily.reason"))
        #expect(item.reasonDetail == String.l10n("recommendations.history.reasonUnavailable"))
        #expect(item.compactReason)
        #expect(!item.revealed)
    }

    @Test("已知理由提供固定机制解释，不透传未知字符串")
    func explainsKnownReason() {
        let item = DailyRecommendationWebSnapshot.Item(
            candidate(reasons: ["unknown", "time_decayed_costar"]), revealed: false
        )
        #expect(item.reason == String.l10n("recommendations.daily.reasonCoStar"))
        #expect(item.reasonDetail == String.l10n("recommendations.daily.reasonCoStarDetail"))
        #expect(item.reason != item.reasonDetail)
        #expect(!item.compactReason)
    }

    @Test("通用模型说明与未知理由不伪装成详细依据", arguments: [
        ["基于自研推荐模型"], ["unknown"]
    ])
    func generalReasonUsesCompactPresentation(reasons: [String]) {
        let item = DailyRecommendationWebSnapshot.Item(candidate(reasons: reasons), revealed: false)
        #expect(item.compactReason)
        #expect(!item.reasonDetail.isEmpty)
    }

    @Test("账号、数据库和新批次分别改变网页身份")
    func contextTracksAccountAndBatch() {
        var state = DailyRecommendationState()
        state.day = "2026-11-14"
        state.generatedAt = Date(timeIntervalSince1970: 100)
        let original = DailyRecommendationWebSnapshot.context(accountID: 1, revision: 1, state: state)
        #expect(original != DailyRecommendationWebSnapshot.context(accountID: 2, revision: 1, state: state))
        #expect(original != DailyRecommendationWebSnapshot.context(accountID: 1, revision: 2, state: state))
        state.generatedAt = Date(timeIntervalSince1970: 101)
        #expect(original != DailyRecommendationWebSnapshot.context(accountID: 1, revision: 1, state: state))
    }

    @Test("实际应用包包含透明本地页面，头像只读原生内嵌数据")
    func bundledRenderer() throws {
        let url = try #require(Bundle.main.url(forResource: "daily-discovery", withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)
        #expect(html.contains("window.starcatDiscovery"))
        #expect(html.contains("border-radius: 16px"))
        #expect(html.contains("--sd-luster: .55"))
        #expect(html.contains("background: transparent"))
        #expect(html.contains("connect-src 'none'"))
        #expect(html.contains("img-src data:;"))
        #expect(html.contains("item?.coverImageDataURI"))
        #expect(!html.contains("coverImageURL"))
        #expect(!html.contains("opengraph.githubassets.com"))
        #expect(!html.contains("cover-monogram"))
        #expect(!html.contains("field(\"avatar\").textContent"))
        #expect(!html.contains("astral-sh"))
        #expect(!html.contains("window.openai"))
        #expect(!html.contains("localStorage"))
        #expect(!html.contains("fetch("))
    }

    @Test("换批只改变按钮文案，成功与失败后恢复操作且保留真实错误", arguments: [1.0, 1.3])
    func batchLoadingKeepsLayout(scale: Double) async throws {
        let renderer = try DailyDiscoveryRendererFixture()
        defer { renderer.close() }
        try await renderer.waitUntilReady()
        let items = [DailyRecommendationWebSnapshot.Item(candidate(), revealed: true)]
        try await renderer.update(rendererSnapshot(items: items, scale: scale))
        let originalLayout = try await renderer.layout()

        try await renderer.update(rendererSnapshot(items: items, loading: true, scale: scale))
        #expect(try await renderer.layout() == originalLayout)
        let preparing = try await renderer.webView.evaluateJavaScript("""
            (() => {
                const button = document.querySelector('[data-action="nextBatch"]');
                return button.disabled && button.getAttribute('aria-busy') === 'true'
                    && getComputedStyle(button.querySelector('[data-label="loading"]')).visibility === 'visible'
                    && button.querySelector('[data-label="loading"]').getAttribute('aria-hidden') === 'false'
                    && document.querySelector('.sd-status').hidden;
            })()
            """) as? Bool
        #expect(preparing == true)
        _ = try await renderer.webView.evaluateJavaScript(
            "document.querySelector('[data-action=\"nextBatch\"]').click(); true"
        )
        #expect(!renderer.messages.contains { $0["type"] as? String == "nextBatch" })

        try await renderer.update(rendererSnapshot(items: items, scale: scale))
        #expect(try await renderer.layout() == originalLayout)
        let ready = try await renderer.webView.evaluateJavaScript("""
            (() => {
                const button = document.querySelector('[data-action="nextBatch"]');
                return !button.disabled && button.getAttribute('aria-busy') === 'false'
                    && getComputedStyle(button.querySelector('[data-label="nextBatch"]')).visibility === 'visible';
            })()
            """) as? Bool
        #expect(ready == true)

        try await renderer.update(rendererSnapshot(items: items, message: "Retry this batch", scale: scale))
        let failed = try await renderer.webView.evaluateJavaScript("""
            !document.querySelector('.sd-status').hidden
                && document.querySelector('[data-field="message"]').textContent === 'Retry this batch'
                && !document.querySelector('.sd-status [data-action="retry"]').hidden
                && !document.querySelector('[data-action="nextBatch"]').disabled
            """) as? Bool
        #expect(failed == true)
        try await renderer.update(rendererSnapshot(items: [], loading: true, scale: scale))
        let emptyLoading = try await renderer.webView.evaluateJavaScript("""
            !document.querySelector('.sd-empty').hidden
                && !document.querySelector('.sd-empty .sd-spinner').hidden
                && document.querySelector('.sd-status').hidden
            """) as? Bool
        #expect(emptyLoading == true)
    }

    @Test("Details 图标在快照更新后保留，点击引用正在浏览的仓库")
    func detailsUsesCurrentCard() async throws {
        let renderer = try DailyDiscoveryRendererFixture()
        defer { renderer.close() }
        try await renderer.waitUntilReady()
        let first = candidate(id: 42, fullName: "first/project")
        let second = candidate(id: 43, fullName: "qbittorrent/qBittorrent")
        let snapshot = rendererSnapshot(items: [first, second].map { .init($0, revealed: true) })
        try await renderer.update(snapshot)
        _ = try await renderer.webView.evaluateJavaScript("document.querySelector('.sd-next').click(); true")
        try await renderer.update(snapshot)
        let hasIcon = try await renderer.webView.evaluateJavaScript("""
            document.querySelector('[data-action="details"] svg') !== null
                && document.querySelector('[data-action="details"] [data-label="details"]').textContent === 'Details'
            """) as? Bool
        #expect(hasIcon == true)
        _ = try await renderer.webView.evaluateJavaScript(
            "document.querySelector('[data-action=\"details\"]').click(); true"
        )
        for _ in 0..<100 {
            if renderer.messages.contains(where: { $0["type"] as? String == "details" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let body = try #require(renderer.messages.last { $0["type"] as? String == "details" })
        #expect(DailyRecommendationWebAction(
            body: body, context: snapshot.context, allowedIDs: [first.repoID, second.repoID]
        ) == .details(second.repoID))
        #expect(second.githubURL?.absoluteString == "https://github.com/qbittorrent/qBittorrent")
    }

    @Test("汇总列表使用圆形缓存头像、交替底纹和聚焦反馈，完成按钮右对齐",
           arguments: [false, true], [1.0, 1.3])
    func summaryListPresentation(dark: Bool, scale: Double) async throws {
        let renderer = try DailyDiscoveryRendererFixture()
        defer { renderer.close() }
        try await renderer.waitUntilReady()
        let avatar = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        let items = [
            DailyRecommendationWebSnapshot.Item(
                candidate(), revealed: false, coverImageDataURI: avatar
            ),
            DailyRecommendationWebSnapshot.Item(candidate(id: 43, fullName: "another/project"), revealed: false),
            DailyRecommendationWebSnapshot.Item(
                candidate(id: 44, fullName: "broken/avatar"), revealed: false,
                coverImageDataURI: "data:image/png;base64,broken"
            )
        ]
        try await renderer.update(rendererSnapshot(items: items, scale: scale, dark: dark))
        _ = try await renderer.webView.evaluateJavaScript(
            "document.querySelector('[data-action=\"revealAll\"]').click(); true"
        )
        // 等待真实 data URI 解码与失败回退，避免仅检查节点就漏掉破图或占位尺寸变化。
        var avatarsSettled = false
        for _ in 0..<100 {
            avatarsSettled = try await renderer.webView.evaluateJavaScript("""
                document.querySelector('[data-select="42"] img')?.naturalWidth > 0
                    && !document.querySelector('[data-select="44"] img')
                """) as? Bool == true
            if avatarsSettled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(avatarsSettled)
        let presentation = try await renderer.webView.evaluateJavaScript("""
            (() => {
                const summary = document.querySelector('.sd-summary');
                const rows = [...summary.querySelectorAll('[data-select]')];
                const avatars = rows.map(row => row.querySelector('.sd-summary-avatar'));
                const first = rows[0].getBoundingClientRect();
                const last = rows.at(-1).getBoundingClientRect();
                const done = summary.querySelector('[data-action="close"]').getBoundingClientRect();
                return !summary.hidden && !summary.querySelector('h2')
                    && rows.length === 3
                    && rows[0].textContent === 'owner/project'
                    && avatars.every(avatar => {
                        const rect = avatar.getBoundingClientRect();
                        return Math.abs(rect.width - 32 * \(scale)) < .1
                            && Math.abs(rect.width - rect.height) < .1
                            && getComputedStyle(avatar).borderRadius === '50%';
                    })
                    && avatars[0].querySelector('img').src.startsWith('data:image/png;base64,')
                    && !avatars[1].querySelector('img') && !avatars[2].querySelector('img')
                    && getComputedStyle(rows[0]).backgroundColor !== getComputedStyle(rows[1]).backgroundColor
                    && getComputedStyle(rows[0]).backgroundColor === getComputedStyle(rows[2]).backgroundColor
                    && Math.abs(first.top - summary.getBoundingClientRect().top - 27) < 1
                    && Math.abs(last.right - done.right) < 1
                    && getComputedStyle(rows[0]).transitionDuration === '0s';
            })()
            """) as? Bool
        #expect(presentation == true)
        // 无窗口 WebView 不激活系统焦点伪类；分别验证 DOM 聚焦与真实样式表的状态级联。
        // 临时把悬停／焦点伪类映射为属性，只驱动 CSS 状态，不模拟桌面输入或改变产品样式。
        let feedback = try await renderer.webView.evaluateJavaScript("""
            (() => {
                const row = document.querySelector('.sd-summary [data-select="43"]');
                row.focus();
                if (document.activeElement !== row
                    || !CSS.supports('selector(:hover)') || !CSS.supports('selector(:focus-visible)')) return false;
                const rules = [...document.styleSheets].flatMap(sheet => [...sheet.cssRules])
                    .filter(rule => rule.selectorText?.includes('.sd-summary-list')
                        && rule.selectorText.includes(':hover') && rule.selectorText.includes(':focus-visible'));
                if (!rules.length) return false;
                rules.forEach(rule => {
                    rule.selectorText = rule.selectorText
                        .replaceAll(':hover', '[data-test-hover]').replaceAll(':focus-visible', '[data-test-focus]');
                });
                return [...document.querySelectorAll('.sd-summary [data-select]')].every(button => {
                    const normal = getComputedStyle(button).backgroundColor;
                    button.setAttribute('data-test-hover', '');
                    const hovered = getComputedStyle(button).backgroundColor;
                    button.removeAttribute('data-test-hover');
                    button.setAttribute('data-test-focus', '');
                    const focused = getComputedStyle(button).backgroundColor;
                    button.disabled = true;
                    const disabled = getComputedStyle(button).backgroundColor;
                    button.disabled = false;
                    button.removeAttribute('data-test-focus');
                    return hovered !== normal && focused === hovered && disabled === normal;
                });
            })()
            """) as? Bool
        #expect(feedback == true)
        _ = try await renderer.webView.evaluateJavaScript(
            "document.querySelector('.sd-summary [data-select=\"43\"]').click(); true"
        )
        let selected = try await renderer.webView.evaluateJavaScript("""
            document.querySelector('.sd-summary').hidden
                && document.querySelector('[data-field="owner"]').textContent === 'another'
            """) as? Bool
        #expect(selected == true)
    }

    @Test("翻页动画不置灰控件，内部拦截重复导航和项目操作，业务忙碌仍禁用",
           arguments: ["next", "previous"])
    func navigationKeepsControlsEnabled(direction: String) async throws {
        let renderer = try DailyDiscoveryRendererFixture()
        defer { renderer.close() }
        try await renderer.waitUntilReady()
        let items = [candidate(), candidate(id: 43, fullName: "next/project"), candidate(id: 44, fullName: "last/project")]
            .map { DailyRecommendationWebSnapshot.Item($0, revealed: false) }
        if direction == "previous" {
            try await renderer.update(rendererSnapshot(items: items))
            _ = try await renderer.webView.evaluateJavaScript(
                "document.querySelector('[data-select=\"44\"]').click(); true"
            )
        }
        try await renderer.update(rendererSnapshot(items: items, reduceMotion: false))
        // 暂停真实 Web Animations，稳定覆盖出场和入场两阶段，不依赖测试机器的帧率。
        _ = try await renderer.webView.evaluateJavaScript("""
            const main = document.querySelector('.sd-main');
            const animate = main.animate.bind(main);
            window.testPageAnimations = [];
            main.animate = (...parameters) => {
                const animation = animate(...parameters);
                animation.pause();
                window.testPageAnimations.push(animation);
                return animation;
            };
            document.querySelector('.sd-bottom [data-action="\(direction)"]').click();
            true
            """)
        let leaving = try await renderer.webView.evaluateJavaScript("""
            (() => {
                const actions = ['next', 'star', 'details', 'dismiss', 'nextBatch', 'revealAll'];
                const control = action => document.querySelector(action === 'next' ? '.sd-next' : `[data-action="${action}"]`);
                const enabled = actions.every(action => !control(action).disabled)
                    && [...document.querySelectorAll('.sd-progress-track button')].every(button => !button.disabled)
                    && !document.querySelector('[data-action="autoShow"]').disabled;
                actions.forEach(action => control(action).click());
                document.querySelector('.sd-bottom [data-action="previous"]').click();
                document.querySelector('[data-select="44"]').click();
                document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }));
                document.querySelector('[data-action="autoShow"]').click();
                return enabled && window.testPageAnimations.length === 1
                    && document.querySelector('.sd-bottom [data-action="previous"]').disabled === \(direction == "next")
                    && document.querySelector('[data-field="owner"]').textContent === '\(direction == "next" ? "owner" : "last")'
                    && document.querySelector('[data-action="autoShow"]').checked;
            })()
            """) as? Bool
        #expect(leaving == true)
        _ = try await renderer.webView.evaluateJavaScript("window.testPageAnimations[0].finish(); true")
        var entering = false
        for _ in 0..<100 {
            entering = try await renderer.webView.evaluateJavaScript(
                "window.testPageAnimations.length === 2"
            ) as? Bool == true
            if entering { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(entering)
        let arriving = try await renderer.webView.evaluateJavaScript("""
            document.querySelector('[data-field="owner"]').textContent === 'next'
                && !document.querySelector('.sd-bottom [data-action="previous"]').disabled
                && !document.querySelector('.sd-next').disabled
                && !document.querySelector('[data-action="star"]').disabled
            """) as? Bool
        #expect(arriving == true)
        _ = try await renderer.webView.evaluateJavaScript("window.testPageAnimations[1].finish(); true")
        var finished = false
        for _ in 0..<100 {
            finished = try await renderer.webView.evaluateJavaScript(
                "document.querySelector('.sd-page').getAttribute('aria-busy') === 'false'"
            ) as? Bool == true
            if finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(finished)
        _ = try await renderer.webView.evaluateJavaScript(
            "document.querySelector('[data-action=\"details\"]').click(); true"
        )
        for _ in 0..<100 {
            if renderer.messages.contains(where: { $0["type"] as? String == "details" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let details = renderer.messages.filter { $0["type"] as? String == "details" }
        #expect(details.count == 1)
        #expect(details.first?["id"] as? String == "43")
        #expect(!renderer.messages.contains {
            ["star", "dismiss", "nextBatch", "revealAll", "autoShow"].contains($0["type"] as? String ?? "")
        })
        try await renderer.update(rendererSnapshot(items: items, loading: true))
        let businessBusy = try await renderer.webView.evaluateJavaScript("""
            [...document.querySelectorAll('button[data-action]:not([data-action="close"]), .sd-progress-track button')]
                .every(button => button.disabled) && document.querySelector('[data-action="autoShow"]').disabled
            """) as? Bool
        #expect(businessBusy == true)
    }

    /// 固定长短两种按钮文案，验证状态切换时预留尺寸，而非依赖测试机器的语言设置。
    private func rendererSnapshot(
        items: [DailyRecommendationWebSnapshot.Item], loading: Bool = false,
        message: String? = nil, scale: Double = 1, dark: Bool = false, reduceMotion: Bool = true
    ) -> DailyRecommendationWebSnapshot {
        var labels = DailyRecommendationWebSnapshot.localizedLabels
        labels["nextBatch"] = "Another batch"
        labels["loading"] = "Preparing your cards..."
        labels["details"] = "Details"
        return DailyRecommendationWebSnapshot(
            context: "test-account/current-batch", items: items, labels: labels, date: "",
            locale: "en", dark: dark, reduceMotion: reduceMotion, scale: scale,
            loading: loading, busy: loading, message: message, emptyMessage: "No cards",
            canRetry: true, canChangeBatch: true, canSetAutoShow: true, showsOnLaunch: true
        )
    }

    private func candidate(id: Int64 = 42, fullName: String = "owner/project",
                           description: String? = nil, reasons: [String] = []) -> RepoRecommendationItem {
        RepoRecommendationItem(
            repoID: id, fullName: fullName, description: description, language: nil,
            stars: 123, forks: 7, archived: false, score: 0.9, source: "starcat_trained", reasons: reasons
        )
    }
}

/// 在不创建窗口、不操作桌面的 WebView 中运行随包网页，验证真实 DOM 和布局行为。
@MainActor
private final class DailyDiscoveryRendererFixture: NSObject, WKScriptMessageHandler {
    let webView: WKWebView
    private(set) var messages: [[String: Any]] = []

    init(bundle: Bundle = .main) throws {
        let url = try #require(bundle.url(forResource: "daily-discovery", withExtension: "html"))
        let html = try String(contentsOf: url, encoding: .utf8)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000), configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "dailyDiscovery")
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// 只等待本地脚本握手，有界轮询避免页面异常时拖住整个测试进程。
    func waitUntilReady() async throws {
        for _ in 0..<200 {
            if messages.contains(where: { $0["type"] as? String == "ready" }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "DailyDiscoveryRenderer", code: 1)
    }

    func update(_ snapshot: DailyRecommendationWebSnapshot) async throws {
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        _ = try await webView.evaluateJavaScript("window.starcatDiscovery.update(\(json)); true")
    }

    /// 直接比较卡面、导航、底栏和按钮的实际矩形，捕获新增状态行造成的位移。
    func layout() async throws -> [[Double]] {
        let result = try await webView.evaluateJavaScript("""
            ['.sd-card', '.sd-bottom', '.sd-preferences', '[data-action="nextBatch"]'].map(selector => {
                const rect = document.querySelector(selector).getBoundingClientRect();
                return [rect.x, rect.y, rect.width, rect.height];
            })
            """)
        return try #require(result as? [[Double]])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }

    /// 移除 handler 打破 WebKit 对 fixture 的强引用，每个用例独立释放页面。
    func close() {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dailyDiscovery")
    }
}
