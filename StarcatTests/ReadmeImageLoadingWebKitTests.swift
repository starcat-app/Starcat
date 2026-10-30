//
//  ReadmeImageLoadingWebKitTests.swift
//  StarcatTests
//
//  用可控的离线响应验证真实 README 脚本与 CSS，不建立窗口、不截图。
//  图片请求在测试放行前始终挂起，避免依赖网络速度判断加载态。
//

import Foundation
import Testing
import WebKit
@testable import Starcat

/// 无窗口 WebKit 回归：覆盖慢图占位、失败恢复、小图过滤与快速完成路径。
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
        defer { fixture.webView.stopLoading() }
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
        let previewVisible = try await fixture.webView.evaluateJavaScript("""
        (() => {
            document.querySelector('#slow').click();
            const preview = document.querySelector('.readme-image-preview img');
            return preview !== null && getComputedStyle(preview).opacity === '1';
        })()
        """) as? Bool
        #expect(previewVisible == true)
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
        defer { fixture.webView.stopLoading() }
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
        defer { fixture.webView.stopLoading() }
        try await fixture.wait("document.querySelector('#fast')?.complete && document.querySelector('#fast').naturalWidth > 0")
        _ = try await fixture.webView.evaluateJavaScript(ReadmeWebView.readmeEnhancementScript)
        try await fixture.expectSettled("#fast", loaded: true)
        // 再跨过占位延迟，确认没有遗留 timer 把已完成图片切回加载态。
        try await Task.sleep(for: .milliseconds(220))
        try await fixture.expectSettled("#fast", loaded: true)
    }
}

/// 保留生产 HTML / user script；测试只控制图片响应，不注入替代实现。
@MainActor
private final class ImageFixture {
    let responses = ImageResponses()
    let webView: WKWebView

    init(fragment: String, dark: Bool = false, enhanceAtDocumentEnd: Bool = true) {
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
        webView.loadHTMLString(ReadmeWebView.assembleDocument(fragment: fragment, isDark: dark), baseURL: nil)
    }

    /// 轮询有界条件，不能等待整页 load：挂起的图片正是本测试需要保留的状态。
    func wait(_ condition: String) async throws {
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
