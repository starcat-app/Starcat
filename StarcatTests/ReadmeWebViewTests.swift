//
//  ReadmeWebViewTests.swift
//  StarcatTests
//
//  HOM-146 配套单测：README WebView 相对链接解析修复。
//  HOM-201 P1-2（2026-06-14）：`<img>` 相对路径重写已从 `ReadmeWebView` 迁出到
//  独立工具 `ReadmeAssetURLRewriter`，相关测试也同步搬移；本文件仅保留与
//  `ReadmeWebView` 直接绑定的 baseURL 测试。
//

import Testing
import Foundation
import WebKit
import AppKit
@testable import Starcat

@MainActor
@Suite("ReadmeWebView")
struct ReadmeWebViewTests {

    // MARK: - repositoryContentBaseURL

    @Test("README 相对链接保留 blob/HEAD 分支段")
    func repositoryContentBaseURL_resolvesRelativeLinkUnderHead() throws {
        let repositoryURL = try #require(URL(string: "https://github.com/alice/foo"))
        let baseURL = ReadmeWebView.repositoryContentBaseURL(from: repositoryURL)

        #expect(baseURL.absoluteString == "https://github.com/alice/foo/blob/HEAD/")
        #expect(URL(string: "docs/guide.md", relativeTo: baseURL)?.absoluteURL.absoluteString
            == "https://github.com/alice/foo/blob/HEAD/docs/guide.md")
    }

    @Test("README 文档包含图片预览样式且继续禁止页面脚本")
    func assembleDocument_includesImagePreviewStylesAndKeepsPageScriptBlocked() {
        let html = ReadmeWebView.assembleDocument(
            fragment: #"<p><img src="https://example.com/logo.png" alt="Logo"></p>"#,
            isDark: false
        )

        // 图片交互靠 app-owned WKUserScript 注入；README 页面自己的脚本仍由 CSP 禁止。
        #expect(html.contains("script-src 'none'"))
        #expect(html.contains(".readme-image-preview"))
        #expect(html.contains("body.readme-js-ready > article img:not(.readme-image-loaded)"))
    }

    @Test("README 页内查找请求用 generation 区分同一查询的再次执行")
    func findRequestGenerationChangesIdentity() {
        let first = ReadmeFindRequest(query: "WKWebView", generation: 1, backwards: false)
        let sameQueryNext = ReadmeFindRequest(query: "WKWebView", generation: 2, backwards: false)
        let previous = ReadmeFindRequest(query: "WKWebView", generation: 3, backwards: true)

        #expect(first != sameQueryNext)
        #expect(sameQueryNext != previous)
        #expect(ReadmeFindRequest().generation == 0)
    }

    @Test("README 视频要求用户主动播放")
    func configureMediaPlayback_requiresUserActionForAllMedia() {
        let configuration = WKWebViewConfiguration()

        ReadmeWebView.configureMediaPlayback(configuration)

        #expect(configuration.mediaTypesRequiringUserActionForPlayback == .all)
    }

    @Test("README 视频使用 HTTPS 媒体策略和原生 controls")
    func assembleDocument_includesVideoPolicyAndResponsiveStyles() {
        let html = ReadmeWebView.assembleDocument(
            fragment: #"<video src="https://example.com/demo.mp4" autoplay></video>"#,
            isDark: false
        )
        let script = ReadmeWebView.readmeEnhancementScript

        // 页面脚本继续禁用；只有 app-owned 脚本能移除 autoplay 并补齐原生 controls。
        #expect(html.contains("script-src 'none'; media-src https:"))
        #expect(html.contains(".markdown-body video"))
        #expect(html.contains("max-width: 100%;"))
        #expect(html.contains("max-height: 640px;"))
        #expect(script.contains("function enhanceVideo(video)"))
        #expect(script.contains("video.removeAttribute('autoplay');"))
        #expect(script.contains("video.autoplay = false;"))
        #expect(script.contains("video.controls = true;"))
        #expect(script.contains("video.preload = 'metadata';"))
        #expect(script.contains("video.setAttribute('playsinline', '');"))
        #expect(script.contains("enhanceVideos();"))
    }

    @Test("README Mermaid 保留 GitHub enrichment 数据并提供本地渲染样式")
    func assembleDocument_preservesMermaidEnrichmentAndKeepsPageScriptBlocked() {
        let fragment = """
        <section class="js-render-needs-enrichment" data-type="mermaid">
          <div class="js-render-enrichment-target"
               data-json="{&quot;data&quot;:&quot;sequenceDiagram\\nA-&amp;gt;&amp;gt;B: hello&quot;}"
               data-plain="sequenceDiagram&#10;A-&gt;&gt;B: hello">
            <div class="render-plaintext-hidden"><pre lang="mermaid">sequenceDiagram
        A->>B: hello</pre></div>
          </div>
          <span class="js-render-enrichment-loader"><span class="sr-only">Loading</span></span>
        </section>
        """
        let html = ReadmeWebView.assembleDocument(fragment: fragment, isDark: true)

        // 图表源码只作为 app-owned Mermaid 的输入；README 自带脚本仍然不能执行。
        #expect(html.contains("script-src 'none'"))
        #expect(html.contains(#"data-type="mermaid""#))
        #expect(html.contains(#"data-plain="sequenceDiagram&#10;A-&gt;&gt;B: hello""#))
        #expect(html.contains(#"A-&amp;gt;&amp;gt;B: hello"#))
        #expect(html.contains(".starcat-mermaid-rendered iframe"))
        #expect(html.contains(#"data-starcat-mermaid-state="failed""#))
    }

    @Test("README Mermaid 优先读取 data-plain 并清理失败的临时 iframe")
    func mermaidBridge_prefersPlainSourceAndCleansFailureArtifacts() throws {
        let script = ReadmeWebView.readmeEnhancementScript
        let sourceStart = try #require(script.range(of: "function mermaidSource(section) {"))
        let sourceEnd = try #require(
            script.range(
                of: "function cleanupMermaidRenderArtifacts",
                range: sourceStart.upperBound..<script.endIndex
            )
        )
        let sourceFunction = script[sourceStart.lowerBound..<sourceEnd.lowerBound]
        let plainAccess = try #require(sourceFunction.range(of: "getAttribute('data-plain')"))
        let jsonAccess = try #require(sourceFunction.range(of: "getAttribute('data-json')"))

        // GitHub data-json 会把 `->>` 双重转义；正确的 data-plain 必须先命中。
        #expect(plainAccess.lowerBound < jsonAccess.lowerBound)
        #expect(sourceFunction.contains(".replace(/&gt;/gi, '>')"))
        #expect(script.contains("var temporaryIDs = [renderID, 'i' + renderID, 'd' + renderID]"))
        #expect(script.contains("cleanupMermaidRenderArtifacts(renderID);"))
    }

    @Test("README Mermaid sandbox iframe 按 SVG 宽高比响应详情栏宽度")
    func mermaidBridge_makesSandboxIframeResponsive() {
        let script = ReadmeWebView.readmeEnhancementScript

        // Mermaid 11 会在 iframe 写入 SVG 原始像素高度。注入脚本必须读取 viewBox，
        // 用 CSS 宽高比替换固定高度，窗口或详情栏变宽变窄时由 WebKit 自动重排。
        #expect(script.contains("function mermaidSandboxIntrinsicSize(iframe)"))
        #expect(script.contains("new DOMParser().parseFromString(markup, 'text/html')"))
        #expect(script.contains("iframe.style.maxWidth = size.width + 'px';"))
        #expect(script.contains("iframe.style.height = 'auto';"))
        #expect(script.contains("iframe.style.aspectRatio = size.width + ' / ' + size.height;"))
        #expect(script.contains("makeMermaidSandboxResponsive(rendered);"))
        #expect(script.contains("securityLevel: 'sandbox'"))
    }

    @Test("README 使用固定版本的本地 Mermaid 运行时")
    func bundledMermaidRuntime_matchesDeclaredVersion() throws {
        let runtimeURL = try #require(
            Bundle.main.url(
                forResource: ReadmeWebView.mermaidRuntimeResourceName,
                withExtension: "js"
            )
        )
        let source = try String(contentsOf: runtimeURL, encoding: .utf8)

        #expect(ReadmeWebView.mermaidRendererVersion == "11.16.0")
        #expect(source.contains(#""11.16.0""#))
        #expect(source.contains(#"globalThis["mermaid"]"#))
    }

    @Test("深色 README 代码块和表格相对系统窗底抬升，不用 GitHub 近黑画布色")
    func assembleDocument_darkLiftsCodeAndTableSurfacesOffWindowBackground() {
        let html = ReadmeWebView.assembleDocument(
            fragment: "<pre>code</pre><table><tr><td>cell</td></tr></table>",
            isDark: true
        )

        // 半透明白叠在 transparent 正文上，才能跟着 NSColor.windowBackgroundColor 抬升。
        #expect(html.contains("body class=\"markdown-body dark\""))
        #expect(html.contains("--code-bg: rgba(255, 255, 255, 0.08);"))
        #expect(html.contains("--border: rgba(255, 255, 255, 0.14);"))
        #expect(html.contains(".markdown-body .highlight pre"))
        #expect(!html.contains("--code-bg: #161b22;"))
        #expect(!html.contains("--border: #30363d;"))
    }

    @Test("README 正文字号接入界面倍率")
    func assembleDocument_injectsReadableFontSizeFromInterfaceScale() {
        let standardHTML = ReadmeWebView.assembleDocument(
            fragment: "<p>Hello</p>",
            isDark: false
        )
        let largeHTML = ReadmeWebView.assembleDocument(
            fragment: "<p>Hello</p>",
            isDark: false,
            interfaceScale: .large
        )
        let adjustedHTML = ReadmeWebView.assembleDocument(
            fragment: "<p>Hello</p>",
            isDark: false,
            readmeFontSizeAdjustment: 2
        )

        #expect(standardHTML.contains("--readme-body-font-size: 16.00px;"))
        #expect(largeHTML.contains("--readme-body-font-size: 18.56px;"))
        #expect(adjustedHTML.contains("--readme-body-font-size: 18.00px;"))
        #expect(standardHTML.contains("font-size: var(--readme-body-font-size, 16px);"))
        #expect(standardHTML.contains("line-height: var(--readme-line-height, 1.62);"))
    }

    @Test("README 在正文后提供隐藏的 Star History placeholder")
    func assembleDocument_placesStarHistoryHostAfterArticle() throws {
        let html = ReadmeWebView.assembleDocument(
            fragment: "<p>README body</p>",
            isDark: false
        )
        let articleEnd = try #require(html.range(of: "</article>"))
        let host = try #require(html.range(of: #"id="starcat-readme-star-history""#))

        #expect(articleEnd.upperBound < host.lowerBound)
        #expect(html.contains(#"data-starcat-owned="true" hidden"#))
        #expect(html.contains(".starcat-star-history-line"))
        #expect(html.contains(".starcat-star-history-area"))
        #expect(html.contains(".starcat-star-history-endpoint"))
        #expect(html.contains("--history-panel: #ffffff;"))
        #expect(html.contains("--history-panel: rgba(255,255,255,.065);"))
        #expect(html.contains(".starcat-star-history-attribution"))
        #expect(html.contains(".starcat-star-history-attribution strong"))
        #expect(html.contains(".starcat-star-history-avatar img"))
        #expect(html.contains(".starcat-star-history-card-kicker"))
        #expect(html.contains(".starcat-star-history-current-star"))
        #expect(html.contains(".starcat-star-history-skeleton-block"))
        #expect(html.contains("starcat-star-history-skeleton-pulse"))
        #expect(html.contains("@media (prefers-reduced-motion: reduce)"))
        #expect(html.contains("--history-brand: #9a6b00;"))
        #expect(html.contains("--history-brand: #ffd34d;"))
    }

    @Test("Star History 底部兜底通过受控函数局部替换")
    func starHistoryBridge_isFallbackAndIncremental() {
        let script = ReadmeWebView.readmeEnhancementScript

        #expect(script.contains("Math.max(0, overflow - y) <="))
        #expect(script.contains("isNearBottom:"))
        #expect(script.contains("window.starcatReplaceReadmeStarHistory = function(html, animate)"))
        // 入场动画开关必须经参数传入受控函数，而不是让页面脚本自行判断。
        #expect(script.contains("configureStarHistory(host, animate === true);"))
        // 曲线动画要等卡片首次进入视口才播放；未兑现的入场债转移给替换卡，
        // 卡片被移除时债务取消，避免动画消耗在屏幕外或转移到无关卡片。
        #expect(script.contains("host.starcatHistoryRevealOwed = false;"))
        #expect(script.contains("new IntersectionObserver"))
        #expect(script.contains("scheduleRevealWhenVisible"))
        // 总星标数字与曲线同帧从 0 数到当前总数，退出路径统一恢复 Swift 原文。
        #expect(script.contains("starcat-star-history-current-value strong"))
        #expect(script.contains("revealTotal.textContent = revealTotalText;"))
        #expect(script.contains("host.innerHTML = html;"))
        #expect(script.contains(".starcat-star-history-avatar img"))
        #expect(script.contains("image.remove();"))
        #expect(script.contains("host.hidden = false;"))
        #expect(!script.contains("location.reload"))
    }

    @Test("Star History 内嵌图片加载失败时兜底注入原生卡片")
    func starHistoryBridge_injectsFallbackWhenEmbeddedImageFails() throws {
        let script = ReadmeWebView.readmeEnhancementScript
        let bridgeStart = try #require(script.range(of: "window.starcatReplaceReadmeStarHistory = function"))
        let bridgeEnd = try #require(
            script.range(of: "function watchEmbeddedStarHistoryRecovery", range: bridgeStart.upperBound..<script.endIndex)
        )
        let bridge = script[bridgeStart.lowerBound..<bridgeEnd.upperBound]

        // 内嵌标记 ≠ 图片加载成功：camo 偶发 429/503 时图片裂开、原生卡片又被
        // 跳过，README 底部会彻底空白，因此失败态必须落到原生卡片兜底。
        #expect(bridge.contains("embeddedImage.complete && embeddedImage.naturalWidth === 0"))
        #expect(bridge.contains("applyReadmeStarHistory(host, html, animate === true);"))
        #expect(bridge.contains("addEventListener('error'"))
        // Swift 每次渲染状态更新都会重新调用桥接函数；epoch 守卫让上一轮挂起的
        // 异步兜底失效，旧 html 闭包晚到不能覆盖新内容。
        #expect(script.contains("var starHistoryApplyEpoch = 0;"))
        #expect(script.contains("if (epoch !== starHistoryApplyEpoch) { return; }"))
        // 兜底卡上屏后隐藏破损的 picture（破图 + 卡片同框），恢复加载时还原；
        // 每轮先还原再按真实状态结算，兜住「恢复发生在两轮调用之间」的窗口。
        #expect(script.contains("watchEmbeddedStarHistoryRecovery(host, embeddedImage, embeddedPicture, epoch);"))
        #expect(script.contains("embeddedPicture.style.display = 'none';"))
        #expect(script.contains("embeddedPicture.style.display = '';"))
        #expect(script.contains("function watchEmbeddedStarHistoryRecovery(host, embeddedImage, embeddedPicture, epoch)"))
    }

    @Test("README 渐显图片加载失败时立即解除隐形")
    func enhanceImage_failureExitsHiddenState() throws {
        let script = ReadmeWebView.readmeEnhancementScript
        let document = ReadmeWebView.assembleDocument(fragment: "<p>Hello</p>", isDark: false)

        // complete && naturalWidth === 0 表示加载已结束且失败，load 事件不会再
        // 触发；不在这里直接结算，图片会永远停在 opacity:0（凭空消失）。
        #expect(script.contains("function markFailed()"))
        #expect(script.contains("image.classList.add('readme-image-failed');"))
        #expect(script.contains("image.removeAttribute('data-readme-zoomable');"))
        #expect(script.contains("image.addEventListener('error', markFailed);"))
        // markLoaded 必须清掉失败态：<picture> 换源重载成功后图片要回到正常显示。
        #expect(script.contains("image.classList.remove('readme-image-failed');"))
        // CSS 失败态规则放在 loaded 规则之后，与 :not(.readme-image-loaded) 隐藏
        // 规则同特异性时靠源顺序取胜，失败图片显示 alt 文案而不是隐形。
        #expect(document.contains("body.readme-js-ready > article img.readme-image-failed {"))
        let hiddenRule = try #require(document.range(of: "img:not(.readme-image-loaded)"))
        let failedRule = try #require(document.range(of: "img.readme-image-failed"))
        #expect(hiddenRule.upperBound < failedRule.lowerBound)
    }

    @Test("README 翻译过渡不强制同步布局")
    func translationAnimation_avoidsForcedLayoutReads() throws {
        let script = ReadmeWebView.readmeEnhancementScript
        let animationStart = try #require(script.range(of: "function scheduleTranslationAnimationReset"))
        let animationEnd = try #require(
            script.range(
                of: "window.starcatApplyReadmeTranslations = function",
                range: animationStart.lowerBound..<script.endIndex
            )
        )
        let animationScript = script[animationStart.lowerBound..<animationEnd.lowerBound]
        let document = ReadmeWebView.assembleDocument(fragment: "<p>Hello</p>", isDark: false)

        // 翻译批次可能包含大量段落，禁止用 offsetWidth 这类同步布局读取来启动动画。
        #expect(!animationScript.contains("offsetWidth"))
        #expect(animationScript.contains("window.requestAnimationFrame(function()"))
        #expect(document.contains("transition: opacity 180ms ease-out, transform 180ms ease-out;"))
        #expect(document.contains("transition: opacity 160ms ease-out;"))
        #expect(!document.contains("@keyframes starcat-readme-segment-enter"))
        #expect(!document.contains("@keyframes starcat-readme-full-crossfade"))
    }
}
