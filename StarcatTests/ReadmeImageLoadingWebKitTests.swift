//
//  ReadmeImageLoadingWebKitTests.swift
//  StarcatTests
//
//  用可控的离线响应验证真实 README 脚本与 CSS，不建立窗口、不截图。
//  图片请求在测试放行前始终挂起，避免依赖网络速度判断加载态。
//

import AppKit
import Foundation
import Testing
import WebKit
@testable import Starcat

/// 无窗口 WebKit 回归：覆盖图片加载和浏览器的真实 DOM、布局、键盘及缩放行为。
@MainActor
@Suite("README image loading WebKit", .serialized)
struct ReadmeImageLoadingWebKitTests {
    @Test("慢图等待时显示主题占位，成功后保留 picture 与原始尺寸", arguments: [false, true])
    func slowImageShowsPlaceholder(dark: Bool) async throws {
        let fixture = ImageFixture(fragment: """
        <p><a href="https://example.com"><picture>
        <source srcset="starcat-image-test://fixture/slow.gif">
        <img id="slow" src="starcat-image-test://fixture/fallback.gif" width="600" height="240">
        </picture></a></p>
        """, dark: dark)
        defer { fixture.close() }
        try await fixture.wait("document.querySelector('#slow')?.classList.contains('readme-image-loading')")
        let state = try await fixture.webView.evaluateJavaScript("""
        (() => {
            const image = document.querySelector('#slow');
            const css = getComputedStyle(image);
            image.click();
            return [css.opacity, css.backgroundColor, css.backgroundImage !== 'none',
                image.width, image.height, image.closest('a picture') !== null,
                document.querySelector('.readme-image-preview') === null];
        })()
        """) as? [Any]
        let info = try #require(state)
        #expect(info[0] as? String == "1")
        #expect(info[1] as? String == (dark ? "rgba(255, 255, 255, 0.08)" : "rgba(31, 35, 40, 0.1)"))
        // 系统可能开启减少动态效果，此时占位必须静止但仍可见。
        let reduced = try await fixture.webView.evaluateJavaScript("matchMedia('(prefers-reduced-motion: reduce)').matches") as? Bool
        #expect(info[2] as? Bool == (reduced != true))
        #expect(info[3] as? Int == 600)
        #expect(info[4] as? Int == 240)
        #expect(info[5] as? Bool == true)
        #expect(info[6] as? Bool == true)

        try fixture.responses.finish("/slow.gif")
        try await fixture.wait("document.querySelector('#slow').classList.contains('readme-image-loaded')")
        try await fixture.expectSettled("#slow", loaded: true)
        _ = try await fixture.openGallery("#slow")
        #expect(fixture.previewRequest?.images.first?.src == "starcat-image-test://fixture/slow.gif")
        let inlinePreview = try await fixture.webView.evaluateJavaScript("document.querySelector('.readme-image-preview') !== null") as? Bool
        #expect(inlinePreview == false)
    }

    @Test("未知尺寸正文图有临时占位，徽章与行内图不扩高，失败可恢复")
    func failureClearsTemporarySpace() async throws {
        let fixture = ImageFixture(fragment: """
        <p><img id="unknown" src="starcat-image-test://fixture/unknown.gif" alt="Preview"></p>
        <themed-picture><picture><img id="themed" src="starcat-image-test://fixture/themed.gif"></picture></themed-picture>
        <p><img id="badge" width="80" height="20" src="starcat-image-test://fixture/badge.gif"></p>
        <p><img id="group" src="starcat-image-test://fixture/group.gif"><img src="starcat-image-test://fixture/group2.gif"></p>
        <p>Inline <img id="inline" src="starcat-image-test://fixture/inline.gif"> icon</p>
        <div>Other content<p>Separate paragraph</p><picture>
        <img id="wide" width="600" src="starcat-image-test://fixture/wide.gif"></picture></div>
        """)
        defer { fixture.close() }
        try await fixture.wait("document.querySelector('#unknown')?.classList.contains('readme-image-loading-height')")
        try await fixture.wait("document.querySelector('#themed')?.classList.contains('readme-image-loading-height')")
        try await fixture.wait("document.querySelector('#wide')?.classList.contains('readme-image-loading-height')")
        let filtered = try await fixture.webView.evaluateJavaScript("""
        ['badge', 'group', 'inline'].every(id => {
            const image = document.getElementById(id);
            return !image.classList.contains('readme-image-loading')
                && !image.classList.contains('readme-image-loading-height');
        }) && document.querySelector('#unknown').getBoundingClientRect().height >= 120
        """) as? Bool
        #expect(filtered == true)
        try fixture.responses.finish("/unknown.gif", failing: true)
        try await fixture.wait("document.querySelector('#unknown').classList.contains('readme-image-failed')")
        try await fixture.expectSettled("#unknown", loaded: false)

        // 模拟 picture 换源 / 后续成功：监听器不能在第一次失败后失效。
        _ = try await fixture.webView.evaluateJavaScript("document.querySelector('#unknown').src = 'starcat-image-test://fixture/recovered.gif'")
        try await fixture.wait("document.querySelector('#unknown').complete === false")
        try await fixture.waitForRequest("/recovered.gif")
        try fixture.responses.finish("/recovered.gif")
        try await fixture.wait("document.querySelector('#unknown').classList.contains('readme-image-loaded')")
        try await fixture.expectSettled("#unknown", loaded: true)
    }

    @Test("预先解码的图片立即显示且不闪占位")
    func completedImageSkipsPlaceholder() async throws {
        let fixture = ImageFixture(fragment: "<p><img id='fast' src='data:image/gif;base64,\(ImageResponses.gif)'></p>",
                                   enhanceAtDocumentEnd: false)
        defer { fixture.close() }
        try await fixture.wait("document.querySelector('#fast')?.complete && document.querySelector('#fast').naturalWidth > 0")
        _ = try await fixture.webView.evaluateJavaScript(ReadmeWebView.readmeEnhancementScript)
        try await fixture.expectSettled("#fast", loaded: true)
        // 再跨过占位延迟，确认没有遗留 timer 把已完成图片切回加载态。
        try await Task.sleep(for: .milliseconds(220))
        try await fixture.expectSettled("#fast", loaded: true)
    }

    @Test("按正文顺序切换内容图，排除徽章并保留 picture 当前源", arguments: [false, true])
    func galleryOrderAndKeyboard(dark: Bool) async throws {
        let fixture = ImageFixture(fragment: """
        <p><img id="badge" alt="Build" src="starcat-image-test://img.shields.io/badge/build-passing-green.svg"></p>
        <p><img id="small" width="80" height="20" alt="Small" src="data:image/gif;base64,\(ImageResponses.gif)"></p>
        <picture><source srcset="\(ImageResponses.largeSVG)">
        <img id="chosen" alt="Diagram" src="data:image/gif;base64,\(ImageResponses.gif)"></picture>
        <p hidden><img alt="Hidden theme" src="data:image/gif;base64,\(ImageResponses.gif)"></p>
        <p><img id="last" alt="Last" src="data:image/gif;base64,\(ImageResponses.gif)"></p>
        """, dark: dark)
        defer { fixture.close() }
        try await fixture.wait("document.querySelector('#chosen')?.dataset.readmeZoomable === 'true'")
        _ = try await fixture.webView.evaluateJavaScript("""
        document.querySelector('#chosen').focus();
        document.querySelector('#chosen').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true}));
        """)
        let gallery = try await fixture.waitForGallery()
        #expect(fixture.previewRequest?.images.map(\.alt) == ["Small", "Diagram", "Last"])
        #expect(fixture.previewRequest?.images[1].src == ImageResponses.largeSVG)
        try await fixture.waitGallery("document.querySelector('.readme-image-preview-image')?.naturalWidth === 1200")
        let state = try await gallery.evaluateJavaScript("""
        (() => {
            const overlay = document.querySelector('.readme-image-preview');
            const stage = overlay.querySelector('.readme-image-preview-stage').getBoundingClientRect();
            const controls = overlay.querySelector('.readme-image-preview-controls').getBoundingClientRect();
            return [
                overlay.getAttribute('role') === 'dialog' && overlay.getAttribute('aria-modal') === 'true',
                overlay.querySelector('.readme-image-preview-counter').textContent === '2 / 3',
                overlay.querySelector('img').src === window.starcatImagePreviewRequest.images[1].src,
                overlay.querySelector('img').alt === 'Diagram',
                controls.top >= stage.bottom && controls.bottom <= innerHeight,
                document.activeElement.dataset.action === 'close'
            ];
        })()
        """) as? [Bool]
        #expect(state == Array(repeating: true, count: 6))
        _ = try await gallery.evaluateJavaScript("""
        document.querySelector('[data-action="previous"]').click();
        """)
        try await fixture.waitGallery("document.querySelector('.readme-image-preview-image')?.alt === 'Small'")
        let first = try await gallery.evaluateJavaScript("""
        document.querySelector('[data-action="previous"]').disabled &&
            document.querySelector('.readme-image-preview-counter').textContent === '1 / 3'
        """) as? Bool
        #expect(first == true)
        _ = try await gallery.evaluateJavaScript("""
        for (let index = 0; index < 3; index++) {
            window.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowRight'}));
        }
        """)
        try await fixture.waitGallery("document.querySelector('.readme-image-preview-image')?.alt === 'Last'")
        let last = try await gallery.evaluateJavaScript("""
        document.querySelector('[data-action="next"]').disabled &&
            document.querySelector('.readme-image-preview-counter').textContent === '3 / 3'
        """) as? Bool
        #expect(last == true)
        _ = try await gallery.evaluateJavaScript("""
        window.dispatchEvent(new KeyboardEvent('keydown', {key: 'ArrowLeft'}));
        document.querySelector('[data-action="close"]').focus();
        window.dispatchEvent(new KeyboardEvent('keydown', {key: 'Tab', shiftKey: true, cancelable: true}));
        """)
        try await fixture.waitGallery("document.querySelector('.readme-image-preview-counter')?.textContent === '2 / 3'")
        let trapped = try await gallery.evaluateJavaScript("""
        document.querySelector('.readme-image-preview').contains(document.activeElement)
            && document.activeElement.dataset.action !== 'close'
        """) as? Bool
        #expect(trapped == true)
    }

    @Test("徽章加载后保留原链接与键盘行为，普通小图和相似域名图片仍可预览")
    func galleryExcludesBadgesAndKeepsLinks() async throws {
        let fixture = ImageFixture(fragment: """
        <p><a id="badge-link" href="#build"><img id="provider"
        src="starcat-image-test://img.shields.io/github/stars/owner/repo"></a>
        <img id="workflow" src="starcat-image-test://github.com/owner/repo/actions/workflows/ci.yml/badge.svg">
        <img id="proxied" src="starcat-image-test://camo.githubusercontent.com/hash/opaque"
        data-canonical-src="https://badge.fury.io/js/example.svg">
        <img id="local" src="starcat-image-test://fixture/assets/build/badge.png">
        <img id="travis" src="starcat-image-test://api.travis-ci.org/owner/repo.svg">
        <img id="query" src="starcat-image-test://pkg.go.dev/example?status.svg"></p>
        <p><img id="small" width="80" height="20" alt="Small" src="data:image/gif;base64,\(ImageResponses.gif)"></p>
        <p><img id="similar" alt="Similar host" src="starcat-image-test://shields.io.example.com/screenshot.png"></p>
        """)
        defer { fixture.close() }
        for path in [
            "/github/stars/owner/repo", "/owner/repo/actions/workflows/ci.yml/badge.svg",
            "/hash/opaque", "/assets/build/badge.png", "/owner/repo.svg", "/example", "/screenshot.png"
        ] {
            try await fixture.waitForRequest(path)
            try fixture.responses.finish(path)
        }
        try await fixture.wait("""
        ['provider', 'workflow', 'proxied', 'local', 'travis', 'query', 'small', 'similar'].every(
            id => document.getElementById(id).classList.contains('readme-image-loaded'))
        """)
        let preserved = try await fixture.webView.evaluateJavaScript("""
        (() => {
            const badges = ['provider', 'workflow', 'proxied', 'local', 'travis', 'query'].map(
                id => document.getElementById(id));
            let linkReceivedClick = false;
            document.querySelector('#badge-link').addEventListener('click', event => {
                linkReceivedClick = !event.defaultPrevented;
                // 只在外层观察完原始默认行为后拦截，避免测试真的跳转或依赖网络。
                event.preventDefault();
            }, {once: true});
            document.querySelector('#provider').click();
            return linkReceivedClick && badges.every(image => {
                const enter = new KeyboardEvent('keydown', {key: 'Enter', bubbles: true, cancelable: true});
                const space = new KeyboardEvent('keydown', {key: ' ', bubbles: true, cancelable: true});
                image.dispatchEvent(enter);
                image.dispatchEvent(space);
                return !enter.defaultPrevented && !space.defaultPrevented
                    && !image.hasAttribute('data-readme-zoomable') && !image.hasAttribute('tabindex')
                    && !image.hasAttribute('role') && !image.hasAttribute('aria-haspopup');
            });
        })()
        """) as? Bool
        #expect(preserved == true)
        #expect(fixture.previewRequest == nil)
        _ = try await fixture.openGallery("#small")
        #expect(fixture.previewRequest?.index == 0)
        #expect(fixture.previewRequest?.images.map(\.alt) == ["Small", "Similar host"])
    }

    @Test("缩放按钮、滚轮与捏合生效，拖动有边界，切图恢复适应窗口")
    func galleryZoomAndPan() async throws {
        let fixture = ImageFixture(fragment: """
        <p><img id="large" src="\(ImageResponses.largeSVG)"></p>
        <p><img id="small" src="data:image/gif;base64,\(ImageResponses.gif)"></p>
        """)
        defer { fixture.close() }
        try await fixture.wait("document.querySelector('#large')?.dataset.readmeZoomable === 'true'")
        let gallery = try await fixture.openGallery("#large")
        try await fixture.waitGallery("document.querySelector('.readme-image-preview-image')?.hidden === false")
        let fitted = try await gallery.evaluateJavaScript("""
        (() => {
            const image = document.querySelector('.readme-image-preview-image').getBoundingClientRect();
            const stage = document.querySelector('.readme-image-preview-stage').getBoundingClientRect();
            return image.width < 1200 && image.width <= stage.width && image.height <= stage.height;
        })()
        """) as? Bool
        #expect(fitted == true)
        _ = try await gallery.evaluateJavaScript("""
        document.querySelector('[data-action="actualSize"]').click();
        document.querySelector('[data-action="zoomIn"]').click();
        """)
        let enlarged = try await gallery.evaluateJavaScript("""
        document.querySelector('.readme-image-preview-image').width === 1500 &&
            document.querySelector('.readme-image-preview-zoom').textContent === '125%'
        """) as? Bool
        #expect(enlarged == true)
        let panned = try await gallery.evaluateJavaScript("""
        (() => {
            const stage = document.querySelector('.readme-image-preview-stage');
            const image = stage.querySelector('img');
            // 合成 PointerEvent 不在 WebKit 的活动指针表内；只替代捕获 API，保留生产拖动计算与收尾。
            stage.setPointerCapture = function() {};
            image.dispatchEvent(new PointerEvent('pointerdown', {bubbles: true, pointerId: 1, clientX: 200, clientY: 200}));
            stage.dispatchEvent(new PointerEvent('pointermove', {bubbles: true, pointerId: 1, clientX: 10000, clientY: 10000}));
            stage.dispatchEvent(new PointerEvent('pointerup', {bubbles: true, pointerId: 1}));
            stage.click();
            const bounds = image.getBoundingClientRect();
            const viewport = stage.getBoundingClientRect();
            return !!document.querySelector('.readme-image-preview')
                && bounds.left <= viewport.left + 1 && bounds.right >= viewport.right - 1
                && bounds.top <= viewport.top + 1 && bounds.bottom >= viewport.bottom - 1;
        })()
        """) as? Bool
        #expect(panned == true)
        let wheel = try await gallery.evaluateJavaScript("""
        (() => {
            const stage = document.querySelector('.readme-image-preview-stage');
            stage.dispatchEvent(new WheelEvent('wheel', {deltaY: -100000, cancelable: true}));
            const maxed = document.querySelector('[data-action="zoomIn"]').disabled
                && document.querySelector('.readme-image-preview-zoom').textContent === '800%';
            stage.dispatchEvent(new WheelEvent('wheel', {deltaY: 100000, cancelable: true}));
            return maxed && document.querySelector('[data-action="zoomOut"]').disabled
                && document.querySelector('.readme-image-preview-zoom').textContent === '10%';
        })()
        """) as? Bool
        #expect(wheel == true)
        let pinch = try await gallery.evaluateJavaScript("""
        (() => {
            document.querySelector('[data-action="actualSize"]').click();
            const stage = document.querySelector('.readme-image-preview-stage');
            stage.dispatchEvent(new Event('gesturestart', {cancelable: true}));
            const change = new Event('gesturechange', {cancelable: true});
            Object.defineProperty(change, 'scale', {value: 2});
            stage.dispatchEvent(change);
            stage.dispatchEvent(new WheelEvent('wheel', {deltaY: -100, cancelable: true}));
            const doubled = document.querySelector('.readme-image-preview-zoom').textContent === '200%';
            stage.dispatchEvent(new Event('gestureend', {cancelable: true}));
            document.querySelector('[data-action="fit"]').click();
            return doubled && document.querySelector('.readme-image-preview-image').width < 1200;
        })()
        """) as? Bool
        #expect(pinch == true)
        _ = try await gallery.evaluateJavaScript("""
        document.querySelector('[data-action="zoomIn"]').click();
        document.querySelector('[data-action="next"]').click();
        """)
        try await fixture.waitGallery("document.querySelector('.readme-image-preview-zoom')?.textContent === '100%'")
        let reset = try await gallery.evaluateJavaScript("""
        document.querySelector('.readme-image-preview-image').width === 1 &&
            !document.querySelector('.readme-image-preview-stage').classList.contains('readme-image-preview-pannable')
        """) as? Bool
        #expect(reset == true)
    }

    @Test("慢图与失败图不阻塞切换，关闭恢复焦点、滚动和原始 overflow")
    func galleryPendingFailureAndRestoration() async throws {
        let fixture = ImageFixture(fragment: """
        <p><img id="first" src="data:image/gif;base64,\(ImageResponses.gif)"></p>
        <img width="600" height="240" src="starcat-image-test://fixture/pending.gif">
        <img width="600" height="240" src="data:image/png;base64,invalid">
        <div style="height:2000px">Long README</div>
        """)
        defer { fixture.close() }
        try await fixture.wait("document.querySelector('#first')?.dataset.readmeZoomable === 'true'")
        _ = try await fixture.webView.evaluateJavaScript("""
        document.documentElement.style.overflow = 'auto';
        document.body.style.overflow = 'visible';
        document.querySelector('#first').focus({preventScroll: true});
        window.scrollTo(0, 500);
        """)
        try await fixture.wait("window.scrollY === 500")
        let gallery = try await fixture.openGallery("#first")
        _ = try await gallery.evaluateJavaScript("""
        document.querySelector('[data-action="next"]').click();
        """)
        try await fixture.waitGallery("document.querySelector('.readme-image-preview-loading') !== null")
        let waiting = try await gallery.evaluateJavaScript("""
        document.querySelector('[data-action="zoomIn"]').disabled &&
            !document.querySelector('[data-action="next"]').disabled &&
            document.querySelector('.readme-image-preview-counter').textContent === '2 / 3' &&
            document.querySelector('article').inert && document.documentElement.style.overflow === 'hidden'
        """) as? Bool
        #expect(waiting == true)
        _ = try await gallery.evaluateJavaScript("document.querySelector('[data-action=\"next\"]').click()")
        try await fixture.waitGallery("""
        document.querySelector('.readme-image-preview-counter')?.textContent === '3 / 3' &&
            !document.querySelector('.readme-image-preview-status').classList.contains('readme-image-preview-loading')
        """)
        let failed = try await gallery.evaluateJavaScript("""
        !document.querySelector('.readme-image-preview-status').hidden &&
            document.querySelector('[data-action="zoomIn"]').disabled &&
            !document.querySelector('[data-action="previous"]').disabled
        """) as? Bool
        #expect(failed == true)
        _ = try await gallery.evaluateJavaScript("""
        window.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape'}));
        """)
        try await fixture.waitForGalleryClosed()
        let restored = try await fixture.webView.evaluateJavaScript("""
        window.scrollY === 500 && document.documentElement.style.overflow === 'auto' &&
            document.body.style.overflow === 'visible' && !document.querySelector('article').inert &&
            document.activeElement.id === 'first'
        """) as? Bool
        #expect(restored == true)
        for _ in 0..<3 {
            let reopened = try await fixture.openGallery("#first")
            _ = try await reopened.evaluateJavaScript("window.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape'}))")
            try await fixture.waitForGalleryClosed()
        }
        let reopened = try await fixture.openGallery("#first")
        let count = try await reopened.evaluateJavaScript("document.querySelectorAll('.readme-image-preview').length") as? Int
        #expect(count == 1)
        _ = try await reopened.evaluateJavaScript("document.querySelector('.readme-image-preview-stage').click()")
        try await fixture.waitForGalleryClosed()
    }

    @Test("窄窗口底部控件不溢出，单图禁用切换，App 关动画生效")
    func galleryNarrowLayoutAndReducedMotion() async throws {
        let fixture = ImageFixture(fragment: "<img id='only' src='\(ImageResponses.largeSVG)'>", reduceMotion: true)
        defer { fixture.close() }
        fixture.gallerySize = CGSize(width: 320, height: 500)
        try await fixture.wait("document.querySelector('#only')?.dataset.readmeZoomable === 'true'")
        let gallery = try await fixture.openGallery("#only")
        _ = try await gallery.evaluateJavaScript("""
        document.querySelector('[data-action="fit"]').textContent = 'Aan venster aanpassen';
        """)
        try await fixture.waitGallery("document.querySelector('.readme-image-preview-image')?.hidden === false")
        let result = try await gallery.evaluateJavaScript("""
        (() => {
            const overlay = document.querySelector('.readme-image-preview');
            const controls = overlay.querySelector('.readme-image-preview-controls').getBoundingClientRect();
            const stage = overlay.querySelector('.readme-image-preview-stage').getBoundingClientRect();
            const image = overlay.querySelector('img').getBoundingClientRect();
            return [
                controls.left >= 0 && controls.right <= innerWidth && controls.bottom <= innerHeight,
                stage.bottom <= controls.top && stage.height > 0,
                image.width <= stage.width && image.height <= stage.height,
                overlay.querySelector('[data-action="previous"]').disabled && overlay.querySelector('[data-action="next"]').disabled,
                Array.from(overlay.querySelectorAll('button')).every(button => button.getBoundingClientRect().right <= innerWidth),
                getComputedStyle(overlay).transitionDuration === '0s'
            ];
        })()
        """) as? [Bool]
        #expect(result == Array(repeating: true, count: 6))
        _ = try await gallery.evaluateJavaScript("document.querySelector('[data-action=\"close\"]').click()")
        try await fixture.waitForGalleryClosed()
    }

    @Test("图片浏览器覆盖整个宿主，随窗口内容尺寸变化，关闭不移动原阅读器")
    func galleryUsesWindowContentBounds() throws {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        let sourceView = NSView(frame: NSRect(x: 850, y: 0, width: 550, height: 900))
        contentView.addSubview(sourceView)
        let sourceFrame = sourceView.frame
        let request = try #require(ReadmeImagePreviewRequest(messageBody: [
            "images": [["src": ImageResponses.largeSVG, "alt": "Diagram"]], "index": 0
        ]))
        let controller = ReadmeImagePreviewController(
            request: request, accountID: nil, isDark: false, interfaceScale: .standard, reduceMotion: true
        )
        defer { controller.dismiss(animated: false) }
        controller.present(over: contentView, restoringFocusTo: sourceView)
        #expect(controller.webView.bounds.width == 1400)
        #expect(controller.webView.bounds.height == 900)
        #expect(controller.webView.bounds.width > sourceView.bounds.width)
        #expect(sourceView.superview === contentView && sourceView.frame == sourceFrame)
        contentView.setFrameSize(NSSize(width: 1600, height: 1000))
        contentView.layoutSubtreeIfNeeded()
        #expect(controller.webView.bounds.size == NSSize(width: 1600, height: 1000))
        controller.dismiss(animated: false)
        #expect(contentView.subviews == [sourceView])
        #expect(sourceView.frame == sourceFrame)
    }
}

/// 保留两份独立的生产文档与脚本；只替代窗口呈现，不把图片浏览器塞回原 README。
@MainActor
private final class ImageFixture: NSObject, WKScriptMessageHandler {
    let responses = ImageResponses()
    let webView: WKWebView
    private let galleryResponses = ImageResponses()
    private let dark: Bool
    private let reduceMotion: Bool
    private var gallery: WKWebView?
    private(set) var previewRequest: ReadmeImagePreviewRequest?
    var gallerySize = CGSize(width: 900, height: 700)

    init(fragment: String, dark: Bool = false, enhanceAtDocumentEnd: Bool = true, reduceMotion: Bool = false) {
        self.dark = dark
        self.reduceMotion = reduceMotion
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(responses, forURLScheme: "starcat-image-test")
        for name in ["readmeScroll", "readmeTranslationSource", "readmeMermaidRequest"] {
            config.userContentController.add(responses, name: name)
        }
        if enhanceAtDocumentEnd {
            config.userContentController.addUserScript(WKUserScript(
                source: ReadmeWebView.readmeEnhancementScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true
            ))
        }
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
        super.init()
        config.userContentController.add(self, name: ReadmeImagePreviewController.messageName)
        webView.loadHTMLString(ReadmeWebView.assembleDocument(fragment: fragment, isDark: dark), baseURL: nil)
    }

    /// 来源点击按生产消息格式启动另一个 WebView，不替换任何 DOM 浏览行为。
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.webView === webView, let request = ReadmeImagePreviewRequest(messageBody: message.body) {
            closeGallery()
            previewRequest = request
            let configuration = ReadmeImagePreviewController.configuration(request: request, accountID: nil, reduceMotion: reduceMotion)
            configuration.websiteDataStore = .nonPersistent()
            configuration.setURLSchemeHandler(galleryResponses, forURLScheme: "starcat-image-test")
            configuration.userContentController.add(self, name: ReadmeImagePreviewController.messageName)
            let created = WKWebView(frame: CGRect(origin: .zero, size: gallerySize), configuration: configuration)
            gallery = created
            created.loadHTMLString(ReadmeWebView.assembleDocument(fragment: "", isDark: dark), baseURL: nil)
        } else if message.webView === gallery,
                  let payload = message.body as? [String: Any], payload["visible"] as? Bool == false {
            closeGallery()
        }
    }

    func openGallery(_ selector: String) async throws -> WKWebView {
        _ = try await webView.evaluateJavaScript("document.querySelector('\(selector)').click()")
        return try await waitForGallery()
    }

    /// 等待真实的消息与 DOM 就绪，不用固定时间猜测跨 WebView 的交接。
    func waitForGallery() async throws -> WKWebView {
        for _ in 0..<150 {
            if let gallery {
                try await wait("document.querySelector('.readme-image-preview') !== null", in: gallery)
                return gallery
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ReadmeImageLoading", code: 3)
    }

    func waitGallery(_ condition: String) async throws {
        let gallery = try #require(gallery)
        try await wait(condition, in: gallery)
    }

    func waitForGalleryClosed() async throws {
        for _ in 0..<150 {
            if gallery == nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ReadmeImageLoading", code: 4)
    }

    private func closeGallery() {
        gallery?.stopLoading()
        gallery?.configuration.userContentController.removeScriptMessageHandler(forName: ReadmeImagePreviewController.messageName)
        gallery = nil
    }

    func close() {
        closeGallery()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: ReadmeImagePreviewController.messageName)
    }

    /// 轮询有界条件，不能等待整页 load：挂起的图片正是本测试需要保留的状态。
    func wait(_ condition: String) async throws {
        try await wait(condition, in: webView)
    }

    private func wait(_ condition: String, in webView: WKWebView) async throws {
        for _ in 0..<150 {
            if let result = try? await webView.evaluateJavaScript("Boolean(\(condition))"), result as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ReadmeImageLoading", code: 1, userInfo: [NSLocalizedDescriptionKey: condition])
    }

    /// 换源请求必须真实进入 handler 后再放行，避免依赖 WebKit 调度顺序。
    func waitForRequest(_ path: String) async throws {
        for _ in 0..<150 {
            if responses.pending[path] != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "ReadmeImageLoading", code: 2)
    }

    /// 成功和失败都必须撤销临时尺寸 / 动画；失败仍显示替代内容且不可预览。
    func expectSettled(_ selector: String, loaded: Bool) async throws {
        try await wait("getComputedStyle(document.querySelector('\(selector)')).opacity === '1'")
        let result = try await webView.evaluateJavaScript("""
        (() => {
            const image = document.querySelector('\(selector)');
            const css = getComputedStyle(image);
            return !Array.from(image.classList).some(name => name.startsWith('readme-image-loading'))
                && image.classList.contains('readme-image-loaded') === \(loaded)
                && image.classList.contains('readme-image-failed') === \(!loaded)
                && (image.dataset.readmeZoomable === 'true') === \(loaded)
                && css.backgroundImage === 'none';
        })()
        """) as? Bool
        #expect(result == true)
    }
}

/// WebKit 在主线程回调自定义 scheme；仅在测试明确放行时结束响应。
@MainActor
private final class ImageResponses: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    static let gif = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"
    /// 使用真实大 SVG 测量适应 / 原始尺寸，避免 1px GIF 掩盖缩放和拖动错误。
    static let largeSVG = "data:image/svg+xml;base64," + Data(
        #"<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="900"><rect width="1200" height="900" fill="teal"/></svg>"#.utf8
    ).base64EncodedString()
    var pending: [String: any WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        pending[urlSchemeTask.request.url!.path] = urlSchemeTask
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        pending.removeValue(forKey: urlSchemeTask.request.url!.path)
    }

    /// GIF 数据固定，失败也显式触发，整个 suite 不访问外网。
    func finish(_ path: String, failing: Bool = false) throws {
        let pendingTask = pending.removeValue(forKey: path)
        let task = try #require(pendingTask)
        if failing {
            task.didFailWithError(URLError(.resourceUnavailable))
        } else {
            let data = try #require(Data(base64Encoded: Self.gif))
            task.didReceive(URLResponse(url: task.request.url!, mimeType: "image/gif",
                                       expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}
