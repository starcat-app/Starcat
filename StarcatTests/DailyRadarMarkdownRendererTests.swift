//
//  DailyRadarMarkdownRendererTests.swift
//  StarcatTests
//
//  日报截图问题的离线回归：短指标列、HTML 折叠标题和上游错误嵌套链接。
//  验证白名单重建的 HTML，不加载远程内容或操作实际应用窗口。
//

import Foundation
import JavaScriptCore
import Testing
@testable import Starcat

/// 只扩展日报需要的展示语义，避免修复格式时把来源 HTML 的执行能力一起放开。
struct DailyRadarMarkdownRendererTests {
    /// 同一文章头供原生展示，正文不再绘制第二个 H1 或摘要。
    @Test func structuredWeeklyArticleKeepsOneHeaderAndTrustedMetadata() throws {
        let metadata = """
        {"article_format":1,"title":"Weekly report","summary":"Full report summary","edition_date":"2026-11-05","reading_minutes":7}
        """
        let markdown = "---\n\(metadata)\n---\n\n# Weekly report\n\n## News\n\nContent"
        let article = try #require(DailyRadarArticle.parse(markdown))
        #expect(article.title == "Weekly report")
        #expect(article.summary == "Full report summary")
        #expect(article.readingMinutes == 7)
        let html = DailyRadarMarkdownRenderer.render(article.body)
        #expect(html.contains("<h2>News</h2>"))
        #expect(!html.contains("<h1>"))
        #expect(!html.contains("Full report summary"))
        #expect(DailyRadarArticle.parse(markdown.replacingOccurrences(of: "# Weekly report", with: "# Other")) == nil)
        #expect(DailyRadarArticle.parse("---\n---\n") == nil)
        #expect(DailyRadarArticle.parse("# Existing report\n\nBody") == nil)
    }

    /// 仓库首页有明确身份；深层链接与有语义的锚文字不被改写。
    @Test func repositoryLinksShowOwnerAndNameWithSafeAvatar() {
        let html = DailyRadarMarkdownRenderer.render("""
        [GitHub](https://github.com/google-deepmind/detectorscope)
        [Tencent-Hunyuan/Hy-SimulMT](https://github.com/Tencent-Hunyuan/Hy-SimulMT)
        [Release notes](https://github.com/owner/repo/releases)
        [Documentation](https://github.com/owner/repo)
        [GitHub](https://github.com/owner/repo?tab=readme)
        """)
        #expect(html.contains("google-deepmind/detectorscope</a>"))
        #expect(html.contains("Tencent-Hunyuan/Hy-SimulMT</a>"))
        #expect(html.contains("https://github.com/google-deepmind.png?size=48"))
        #expect(html.contains("alt=\"\" decoding=\"async\""))
        #expect(html.contains(">Release notes</a>"))
        #expect(html.contains(">Documentation</a>"))
        #expect(html.contains("repo?tab=readme\">GitHub</a>"))
        // 头像复用原生可见范围加载，但不能替换 owner/repo 或生成嵌套的图片回退链接。
        #expect(html.contains("class=\"article-image repository-image\""))
        #expect(html.contains("class=\"repository-avatar\" data-source=\"https://github.com/google-deepmind.png?size=48\""))
        #expect(!html.contains("image-fallback"))
        #expect(html.range(of: #"<img\b[^>]*\ssrc\s*="#, options: .regularExpression) == nil)
    }

    /// 源地址只进入惰性数据属性；初始 HTML 不存在任何会自动发起正文图片请求的 src/srcset。
    @Test func articleImagesReserveSpaceWithoutEagerSource() {
        // 用行内代码保留字面双引号，避免 Markdown 的智能标点先将其转为弯引号。
        let html = DailyRadarMarkdownRenderer.render("""
        ![Figure `"quoted"` & details](https://images.example/figure.png?q=1&v=2 "ignored title")
        """)
        #expect(html.contains("class=\"article-image\" data-state=\"pending\" aria-busy=\"true\""))
        #expect(html.contains("data-source=\"https://images.example/figure.png?q=1&amp;v=2\""))
        #expect(html.contains("alt=\"Figure `&quot;quoted&quot;` &amp; details\""))
        #expect(html.contains("class=\"image-placeholder\" aria-hidden=\"true\""))
        #expect(html.contains("class=\"image-spinner\""))
        #expect(html.contains("class=\"image-fallback\" href=\"https://images.example/figure.png?q=1&amp;v=2\""))
        #expect(html.range(of: #"<img\b[^>]*\ssrc\s*="#, options: .regularExpression) == nil)
        #expect(!html.contains("srcset"))
        #expect(!html.contains("ignored title"))
    }

    @Test func lazyImageSourcesKeepHTTPSAndSafeHTMLBoundary() {
        for source in [
            "http://images.example/a.png", "https://user:pass@images.example/a.png",
            "javascript:alert(1)", "data:image/png;base64,AAAA", "file:///tmp/a.png"
        ] {
            let html = DailyRadarMarkdownRenderer.render("![Unsafe](\(source))")
            #expect(!html.contains("article-image"))
            #expect(!html.contains("data-source="))
            #expect(!html.contains("<img"))
        }
        let raw = DailyRadarMarkdownRenderer.render("""
        <img src="https://images.example/a.png" srcset="https://images.example/b.png 2x" onload="alert(1)" style="position:fixed">
        """)
        // 来源 HTML 图片仍为惰性文本，不为加载功能扩展 SafeHTML 的标签/属性白名单。
        #expect(!raw.contains("<img"))
        #expect(raw.contains("&lt;img"))
        let emptyAlt = DailyRadarMarkdownRenderer.render("![](https://images.example/a.png)")
        #expect(emptyAlt.contains(">https://images.example/a.png</a>"))
    }

    @Test func linkedImageFallbackKeepsTheOriginalDestinationWithoutNestedAnchor() {
        let html = DailyRadarMarkdownRenderer.render("""
        [![Figure](https://images.example/a.png)](https://example.com/original)
        """)
        #expect(html.contains("<a href=\"https://example.com/original\">"))
        #expect(html.contains("<span class=\"image-fallback\">Figure</span>"))
        #expect(!html.contains("<a class=\"image-fallback\""))
        #expect(html.components(separatedBy: "<a ").count == 2)
    }

    /// WebView 等高于全文：即使 JS 自身 viewport 足够大，未收到原生范围也不允许启动图片。
    @Test func nativeVisibleRangeControlsRequestsAndRechecksExpandedContent() throws {
        let context = try imageScriptContext()
        #expect(context.evaluateScript("requests.length === 0 && messages.length === 1")?.toBool() == true)
        #expect(context.evaluateScript("messages[0].height === 12000")?.toBool() == true)
        context.evaluateScript("""
        window.dailyRadarSetVisibleRange("old-session",0,600,800);flush();
        """)
        #expect(context.evaluateScript("requests.length === 0")?.toBool() == true)
        context.evaluateScript("""
        window.dailyRadarSetVisibleRange("test-session",0,600,800);flush();
        """)
        #expect(context.evaluateScript("requests.length === 1 && requests[0].endsWith('/near.png')")?.toBool() == true)
        #expect(context.evaluateScript("!slots[1].image.src && !slots[2].image.src")?.toBool() == true)
        // 第一张真实图增高，把第二张推远；后续范围检查必须读取新几何位置。
        context.evaluateScript("""
        slots[1].top=8000;
        slots[0].image.emit("load");flush();
        window.dailyRadarSetVisibleRange("test-session",4800,5400,800);flush();
        """)
        #expect(context.evaluateScript("!slots[1].image.src")?.toBool() == true)
        context.evaluateScript("""
        window.dailyRadarSetVisibleRange("test-session",7800,8400,800);flush();
        """)
        #expect(context.evaluateScript("requests.length === 2 && slots[1].dataset.state === 'loading'")?.toBool() == true)
        #expect(context.exception == nil)
    }

    @Test func imageFailureEndsBusyStateAndCollapsedImagesWaitForToggle() throws {
        let context = try imageScriptContext()
        context.evaluateScript("""
        window.dailyRadarSetVisibleRange("test-session",0,600,800);flush();
        slots[0].image.emit("error");flush();
        """)
        #expect(context.evaluateScript("slots[0].dataset.state === 'error' && slots[0].attributes['aria-busy'] === 'false'")?.toBool() == true)
        #expect(context.evaluateScript("!slots[2].image.src")?.toBool() == true)
        context.evaluateScript("""
        slots[2].hidden=false;
        events.toggle();flush();
        slots[2].image.emit("load");flush();
        """)
        #expect(context.evaluateScript("slots[2].dataset.state === 'loaded' && slots[2].attributes['aria-busy'] === 'false'")?.toBool() == true)
        // 加载结束后 resize/toggle/滚动不能重新发起失败图片，避免重试风暴与永久转圈。
        context.evaluateScript("resizeCallback();events.toggle();flush();")
        #expect(context.evaluateScript("requests.length === 2")?.toBool() == true)
        #expect(context.exception == nil)
    }

    @Test func emptyNativeViewportNeverFallsBackToFullWebView() throws {
        let context = try imageScriptContext()
        for range in ["0,0,800", "0,600,0", "NaN,600,800", "0,Infinity,800"] {
            context.evaluateScript("window.dailyRadarSetVisibleRange('test-session',\(range));flush();")
        }
        #expect(context.evaluateScript("requests.length === 0")?.toBool() == true)
        #expect(context.exception == nil)
    }

    @Test func repositoryAvatarsUseTheSameNativeVisibilityAndEndLoadingOnFailure() throws {
        let context = try imageScriptContext(avatars: true)
        #expect(context.evaluateScript("requests.length === 0")?.toBool() == true)
        context.evaluateScript("""
        window.dailyRadarSetVisibleRange("test-session",0,600,800);flush();
        slots[0].image.emit("error");flush();
        """)
        #expect(context.evaluateScript("requests.length === 1 && slots[0].dataset.state === 'error'")?.toBool() == true)
        #expect(context.evaluateScript("slots[0].attributes['aria-busy'] === 'false' && !slots[1].image.src")?.toBool() == true)
        context.evaluateScript("""
        window.dailyRadarSetVisibleRange("test-session",4800,5400,800);flush();
        """)
        #expect(context.evaluateScript("requests.length === 2 && slots[1].dataset.state === 'loading'")?.toBool() == true)
        #expect(context.exception == nil)
    }

    @Test func documentKeepsNonceAndReducedMotionImageStates() {
        let document = DailyRadarMarkdownDocument.render(
            "![Figure](https://images.example/a.png)", session: "test-session",
            dark: false, fontSize: 16, reduceMotion: true
        )
        #expect(document.contains("default-src 'none'; img-src https:;"))
        #expect(document.contains("script-src 'nonce-test-session'"))
        #expect(document.contains("<script nonce=\"test-session\">"))
        #expect(document.contains("data-reduce-motion=\"true\""))
        #expect(document.contains("body[data-reduce-motion=\"true\"] .article-image>img{transition:none}"))
        #expect(document.contains("body[data-reduce-motion=\"true\"] .image-spinner{animation:none!important}"))
        #expect(document.contains(".article-image[data-state=\"loaded\"] .image-placeholder"))
        #expect(document.contains(".article-image[data-state=\"error\"] .image-fallback{display:block}"))
        #expect(!document.contains("window.addEventListener(\"load\""))
        #expect(!document.contains("IntersectionObserver"))
    }

    /// 正文图片禁用右键和拖拽，但文字 / 链接目标仍保留 WebKit 默认交互。
    @Test func articleImageInteractionsDisableOnlyImageTargets() throws {
        let context = try imageScriptContext()
        context.evaluateScript("""
        var prevented=[];
        function event(target){return {target,preventDefault(){prevented.push(target.name)}}}
        const imageTarget={name:"image",closest(selector){return selector===".article-image"?{}:null}};
        const textTarget={name:"text",closest(){return null}};
        events.contextmenu(event(imageTarget));
        events.contextmenu(event(textTarget));
        events.dragstart(event(imageTarget));
        events.dragstart(event(textTarget));
        """)
        try #require(context.exception == nil)
        #expect(context.evaluateScript("prevented.join(',')").toString() == "image,image")
    }

    /// 不创建 WebView；直接验证布局发布边界，确保同高 ready、旧会话失效及回调顺序。
    @Test @MainActor func layoutReadyPublishesHeightBeforeCallbackOncePerSession() {
        var height: CGFloat = 20
        var readyHeights: [CGFloat] = []
        let view = DailyRadarMarkdownView(
            markdown: "", identity: "ready", onLink: { _ in },
            height: .init(get: { height }, set: { height = $0 }),
            onReady: { readyHeights.append(height) }
        )
        let coordinator = view.makeCoordinator()
        coordinator.session = "first"
        coordinator.publishLayout(height: 20, session: "first")
        coordinator.publishLayout(height: 60, session: "first")
        #expect(readyHeights == [20])
        #expect(height == 60)
        coordinator.session = "second"
        coordinator.publishLayout(height: 500, session: "first")
        coordinator.publishLayout(height: .infinity, session: "second")
        coordinator.publishLayout(height: 0, session: "second")
        #expect(height == 60)
        coordinator.publishLayout(height: 120, session: "second")
        #expect(readyHeights == [20, 120])
        coordinator.session = ""
        coordinator.publishLayout(height: 900, session: "second")
        #expect(height == 120)
    }

    /// JavaScriptCore 中提供最小 DOM/动画队列；无网络、无窗口，运行生产脚本而非复刻加载判断。
    /// URL 仅供已通过 Swift 白名单的测试地址使用，安全边界由上面的真实 Markdown 用例覆盖。
    private func imageScriptContext(avatars: Bool = false) throws -> JSContext {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var requests=[],messages=[],frames=[],events={},resizeCallback;
        var window=this;
        window.innerWidth=800;window.innerHeight=12000;window.scrollY=0;
        window.webkit={messageHandlers:{dailyHeight:{postMessage:value=>messages.push(value)}}};
        class URL{
            constructor(value){
                this.protocol=value.split(":")[0]+":";
                this.username=value.includes("@")?"user":"";
                this.password="";
            }
        }
        function slot(top,name,hidden=false){
            const image={
                dataset:{source:"https://images.example/"+name+".png"},listeners:{},
                addEventListener(name,callback){this.listeners[name]=callback;},
                emit(name){const callback=this.listeners[name];delete this.listeners[name];callback();},
                set src(value){this.source=value;requests.push(value);},get src(){return this.source;}
            };
            return {
                top,hidden,image,height:300,width:800,dataset:{state:"pending"},attributes:{"aria-busy":"true"},
                querySelector:()=>image,
                getClientRects(){return this.hidden?[]:[this.getBoundingClientRect()];},
                getBoundingClientRect(){return {top:this.top,height:this.height,width:this.width};},
                setAttribute(name,value){this.attributes[name]=value;}
            };
        }
        var slots=[slot(100,"near"),slot(5000,"far"),slot(150,"collapsed",true)];
        var mockContent={
            querySelectorAll:()=>slots,getBoundingClientRect:()=>({height:12000})
        };
        var document={querySelector:()=>mockContent,addEventListener:(name,callback)=>events[name]=callback};
        class ResizeObserver{constructor(callback){resizeCallback=callback;}observe(){}}
        function requestAnimationFrame(callback){frames.push(callback);}
        function flush(){const batch=frames.splice(0);batch.forEach(callback=>callback());}
        """)
        if avatars {
            context.evaluateScript("""
            slots=[slot(100,"avatar"),slot(5000,"far-avatar")];
            slots.forEach(slot=>{slot.height=20;slot.width=20;});
            """)
        }
        context.evaluateScript(DailyRadarMarkdownDocument.imageScript(session: "test-session"))
        try #require(context.exception == nil)
        return context
    }

    /// 仅验证可选委托方法的 Objective-C 注册，不创建 WebView 或读取应用窗口。
    @Test @MainActor func linkPolicyCallbackIsRegisteredWithWebKit() {
        let view = DailyRadarMarkdownView(
            markdown: "", identity: "link-policy", onLink: { _ in }, height: .constant(1)
        )
        #expect(view.makeCoordinator().responds(
            to: NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        ))
    }

    @Test func screenshotTableHeadersUseMetadataLayout() {
        let headers = [
            "Product | Votes | Comments | Summary",
            "Story | Score | Comments | Summary",
            "Title | Score | Comments | Summary",
            "产品 | 票数 | 评论 | 摘要"
        ]
        for header in headers {
            let markdown = """
            | \(header) |
            |---|---|---|---|
            | Example | 548 | 302 | A long summary |
            """
            let html = DailyRadarMarkdownRenderer.render(markdown)
            #expect(html.contains("<table class=\"metadata\">"))
            #expect(html.contains("<td class=\"numeric\">548</td>"))
            #expect(html.contains("<td class=\"numeric\">302</td>"))
        }
    }

    @Test func genericTablesAlsoProtectNumericValues() {
        let html = DailyRadarMarkdownRenderer.render("""
        | Name | Value |
        |---|---|
        | Count | 3,599 |
        | Range | 10–20 |
        """)
        #expect(html.contains("<table>"))
        #expect(html.contains("<td class=\"numeric\">3,599</td>"))
        #expect(html.contains("<td>10–20</td>"))
    }

    @Test func summaryRendersBoldAndSafeLinksInsteadOfHTMLSource() {
        let html = DailyRadarMarkdownRenderer.render("""
        <details>
        <summary><strong>Hermes Agent</strong> — <a href="https://github.com/NousResearch/Hermes-Agent">NousResearch/Hermes-Agent</a></summary>

        **Report**

        </details>
        """)
        #expect(html.contains("<summary><strong>Hermes Agent</strong>"))
        #expect(html.contains("<a href=\"https://github.com/NousResearch/Hermes-Agent\">"))
        #expect(!html.contains("&lt;strong"))
        #expect(!html.contains("&lt;a href"))
        #expect(html.contains("<p><strong>Report</strong></p>"))
        #expect(html.contains("</details>"))
    }

    @Test func summaryAttributesAreRebuiltRatherThanCopied() {
        let html = DailyRadarMarkdownRenderer.render("""
        <details open ontoggle="alert(1)">
        <summary onclick="alert(2)"><strong style="color:red">Safe</strong> <a href='https://example.com/Case?q=1&amp;page=2' onmouseover='alert(3)' target='_blank'>Link</a></summary>
        </details>
        """)
        #expect(html.contains("<details open>"))
        #expect(html.contains("<summary><strong>Safe</strong>"))
        #expect(html.contains("<a href=\"https://example.com/Case?q=1&amp;page=2\">"))
        #expect(!html.contains("ontoggle"))
        #expect(!html.contains("onclick"))
        #expect(!html.contains("onmouseover"))
        #expect(!html.contains("target="))
        #expect(!html.contains("style="))
    }

    @Test func unsafeAndDisguisedHTMLDestinationsNeverBecomeLinks() {
        for destination in ["javascript:alert(1)", "java&#115;cript:alert(1)", "data:text/html,test",
                            "file:///etc/passwd", "https://user:pass@example.com/"] {
            let html = DailyRadarMarkdownRenderer.render("""
            <summary><a href="\(destination)">Unsafe</a></summary>
            """)
            #expect(!html.contains("<a href="))
            #expect(html.contains("Unsafe"))
        }
        let disguised = DailyRadarMarkdownRenderer.render("""
        <summary><a title="href='https://unrelated.example/'" href="javascript:alert(1)">Unsafe</a></summary>
        """)
        #expect(!disguised.contains("<a href="))
    }

    @Test func unknownHTMLAndEscapedEntitiesStayInert() {
        let html = DailyRadarMarkdownRenderer.render("""
        <summary><strong>&lt;script&gt; &amp; Safe</strong><svg onload="alert(1)"></svg></summary>

        <script>alert(1)</script>
        """)
        #expect(html.contains("<strong>&lt;script&gt; &amp; Safe</strong>"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<svg"))
        #expect(html.contains("&lt;svg"))
    }

    @Test func quotedAttributesCannotSmuggleExtraLinks() {
        let html = DailyRadarMarkdownRenderer.render("""
        <summary><a title="> <a href='https://unrelated.example/'>" href="javascript:alert(1)">Unsafe</a></summary>
        """)
        #expect(html.contains("<summary><a>Unsafe</a></summary>"))
        #expect(!html.contains("<a href="))

        let duplicate = DailyRadarMarkdownRenderer.render("""
        <summary><a href="https://example.com/first" href="https://example.com/second">Duplicate</a></summary>
        """)
        #expect(duplicate.contains("<summary><a>Duplicate</a></summary>"))
        #expect(!duplicate.contains("<a href="))
    }

    @Test func inlineHTMLUsesTheSameSafeFormattingRules() {
        let html = DailyRadarMarkdownRenderer.render("""
        A <strong onclick="alert(1)">bold</strong> and <a href="https://example.com/">linked</a> report.
        """)
        #expect(html.contains("<strong>bold</strong>"))
        #expect(html.contains("<a href=\"https://example.com/\">linked</a>"))
        #expect(!html.contains("onclick"))
    }

    @Test func malformedDiscussionLinkIsRecoveredOnlyInsideTableCells() {
        let source = "[Qwenputer: CPU](https://divgarg.com/blog/qwenputer · [discuss](https://lobste.rs/s/example))"
        let html = DailyRadarMarkdownRenderer.render("""
        | Story | Score | Comments | Summary |
        |---|---|---|---|
        | \(source) | 44 | 9 | Description |
        """)
        #expect(html.contains("<a href=\"https://divgarg.com/blog/qwenputer\">Qwenputer: CPU</a>"))
        #expect(html.contains(" · <a href=\"https://lobste.rs/s/example\">discuss</a>"))
        #expect(!html.contains("[Qwenputer"))
        let literal = DailyRadarMarkdownRenderer.render("`\(source)`\n\n\(source)")
        #expect(literal.contains("<code>\(source)</code>"))
        // 普通段落保留解析器的结果；不能为修日报表格而全局替换来源文本。
        #expect(!literal.contains("<a href=\"https://divgarg.com/blog/qwenputer\">"))
    }

    @Test func normalLinksAndParenthesesAreUnchanged() {
        let html = DailyRadarMarkdownRenderer.render("""
        | Story | Score | Comments | Summary |
        |---|---|---|---|
        | [A title](https://example.com/a_(b)) · [discuss](https://example.com/thread) | 44 | 9 | Description |
        """)
        #expect(html.contains("<a href=\"https://example.com/a_(b)\">A title</a>"))
        #expect(html.contains("<a href=\"https://example.com/thread\">discuss</a>"))
    }
}
