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
        #expect(html.contains("body.readme-js-ready .markdown-body img:not(.readme-image-loaded)"))
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
}
