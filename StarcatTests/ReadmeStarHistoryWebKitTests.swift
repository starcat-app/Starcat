//
//  ReadmeStarHistoryWebKitTests.swift
//  StarcatTests
//
//  在真实 WKWebView 中验证生产 renderer / CSS / 交互脚本的组合。
//  使用离线固定数据，检查主题、容器断点、标注边界和键盘读数；截图只写临时目录。
//

import AppKit
import Testing
import WebKit
@testable import Starcat

@MainActor
@Suite("README Star History WebKit", .serialized)
struct ReadmeStarHistoryWebKitTests {
    @Test("明暗主题与宽窄卡片布局", arguments: [false, true])
    func themesAndResponsiveLayout(dark: Bool) async throws {
        for width in [1_080, 780, 660, 420, 360] {
            let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
            let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = webView
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFront(nil)
            defer { window.close() }
            webView.loadHTMLString(try document(dark: dark), baseURL: nil)
            try await waitForChart(webView)

            let result = try await webView.evaluateJavaScript("""
            (function() {
                var card = document.querySelector('.starcat-star-history-card');
                var chart = document.querySelector('.starcat-star-history-chart');
                var calls = Array.from(document.querySelectorAll('.starcat-star-history-callout'));
                var metrics = Array.from(document.querySelectorAll('.starcat-star-history-metric'));
                var footer = document.querySelector('.starcat-star-history-footer');
                var bounds = chart.getBoundingClientRect();
                return {
                    overflow: document.documentElement.scrollWidth > window.innerWidth,
                    columns: getComputedStyle(document.querySelector('.starcat-star-history-metrics')).gridTemplateColumns.split(' ').length,
                    oneRow: metrics.every(function(node) { return Math.abs(node.getBoundingClientRect().top - metrics[0].getBoundingClientRect().top) < 1; }),
                    twoLines: metrics.every(function(node) { return node.querySelector('.starcat-star-history-metric-copy').children.length === 2; }),
                    footerText: footer.querySelector('.starcat-star-history-source').textContent.trim(),
                    footerLinks: footer.querySelectorAll('a').length,
                    brandColor: getComputedStyle(footer.querySelector('strong')).color,
                    dailyLabel: metrics[0].querySelector('.starcat-star-history-metric-copy > span').textContent,
                    color: getComputedStyle(document.querySelector('.starcat-star-history-line')).stroke,
                    foreground: getComputedStyle(card).color,
                    ticks: Array.from(document.querySelectorAll('.starcat-star-history-axis-y')).map(function(node) { return node.textContent; }),
                    calloutsInside: calls.every(function(node) { var r = node.getBoundingClientRect(); return r.left >= bounds.left && r.right <= bounds.right && r.top >= bounds.top; }),
                    calloutCount: calls.length,
                    originTime: JSON.parse(chart.dataset.points)[0][0],
                    originValue: JSON.parse(chart.dataset.points)[0][1],
                    lineStartsAtAxis: Math.abs(chart.querySelector('.starcat-star-history-line').points.getItem(0).x - chart.querySelector('.starcat-star-history-axis-x').getAttribute('x')) < 1,
                    cleanLabels: calls.every(function(node) { return !node.textContent.includes('≈'); })
                };
            })();
            """)
            let info = try #require(result as? [String: Any])
            #expect(info["overflow"] as? Bool == false)
            #expect(info["columns"] as? Int == 4)
            #expect(info["oneRow"] as? Bool == true)
            #expect(info["twoLines"] as? Bool == true)
            #expect(info["dailyLabel"] as? String == String.l10n("readme.starHistory.dailyAverage"))
            #expect(info["footerLinks"] as? Int == 0)
            #expect(info["brandColor"] as? String == (dark ? "rgb(255, 211, 77)" : "rgb(154, 107, 0)"))
            // 故意让服务生成时间晚于覆盖日，避免页脚误用 Data through 或最后观测日期。
            #expect(info["footerText"] as? String == String(format: String.l10n("readme.starHistory.updatedFormat"), "Sep 7, 2026"))
            #expect(info["color"] as? String == (dark ? "rgb(48, 216, 117)" : "rgb(8, 189, 89)"))
            #expect(info["ticks"] as? [String] == ["0", "15K", "30K", "45K", "60K"])
            #expect(info["calloutsInside"] as? Bool == true)
            #expect((info["calloutCount"] as? Int ?? 0) >= 1)
            let creationTime = try #require(StarHistoryDateCodec.date(from: "2021-12-21")).timeIntervalSince1970 * 1_000
            #expect(info["originTime"] as? Double == creationTime)
            #expect(info["originValue"] as? Int == 0)
            #expect(info["lineStartsAtAxis"] as? Bool == true)
            #expect(info["cleanLabels"] as? Bool == true)
            let initialTopicCount = try await checkHeader(webView, compact: width < 800)

            // 产出生产视图的 WebKit 截图，便于审阅；不依赖网络头像或外部页面。
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? NSError(domain: "WebKitSnapshot", code: 1)) }
                }
            }
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("starcat-history-ui")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("\(dark ? "dark" : "light")-\(width).png"))
            }

            // 键盘选择必须读取原始序列，不能只在 90 个 LTTB 绘制点之间移动。
            let selection = try await webView.evaluateJavaScript("""
            (function() {
                var chart = document.querySelector('.starcat-star-history-chart');
                chart.focus();
                chart.dispatchEvent(new KeyboardEvent('keydown', { key: 'Home', bubbles: true }));
                var creationValue = chart.querySelector('.starcat-star-history-tooltip strong').textContent;
                chart.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
                return { index: Number(chart.getAttribute('aria-valuenow')), creationValue: creationValue,
                    observedValue: chart.querySelector('.starcat-star-history-tooltip strong').textContent };
            })();
            """)
            let selected = try #require(selection as? [String: Any])
            #expect(selected["index"] as? Int == 1)
            #expect(selected["creationValue"] as? String == "0")
            #expect(selected["observedValue"] as? String == "1,200")

            // 实际缩窗再放宽：时间域不能重置，收起的 Topic 也必须恢复，不能只验证首次渲染。
            if width == 1_080 {
                for targetWidth in [660, 360, 1_080] {
                    window.setContentSize(NSSize(width: targetWidth, height: 800))
                    webView.setFrameSize(NSSize(width: targetWidth, height: 800))
                    var resized = false
                    for _ in 0..<50 {
                        let stable = try await webView.evaluateJavaScript("""
                        (function() {
                            var chart = document.querySelector('.starcat-star-history-chart');
                            var svg = chart.querySelector('svg');
                            var first = chart.querySelector('.starcat-star-history-line').points.getItem(0);
                            return window.innerWidth === \(targetWidth) && svg.viewBox.baseVal.width === chart.clientWidth
                                && Math.abs(first.x - chart.querySelector('.starcat-star-history-axis-x').getAttribute('x')) < 1
                                && Math.abs(first.y - (chart.clientHeight - 30)) < 1;
                        })();
                        """)
                        if stable as? Bool == true { resized = true; break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let resizeState = try await webView.evaluateJavaScript("""
                    (function() {
                        var chart = document.querySelector('.starcat-star-history-chart');
                        var first = chart.querySelector('.starcat-star-history-line').points.getItem(0);
                        return [window.innerWidth, chart.clientWidth, chart.querySelector('svg').viewBox.baseVal.width,
                            chart.clientHeight, first.x, first.y, chart.querySelector('.starcat-star-history-axis-x').getAttribute('x')];
                    })();
                    """)
                    #expect(resized, "Resize dimensions [viewport, chart, SVG, height, x, y, axis]: \(resizeState)")
                    let shown = try await checkHeader(webView, compact: targetWidth < 800)
                    if targetWidth == 1_080 { #expect(shown == initialTopicCount) }
                    else { #expect(shown < initialTopicCount) }
                }
            }

            // 重复挂载和卸载必须可释放 observer，不保留旧仓库的图表回调。
            let cleanup = try await webView.evaluateJavaScript("""
            (function() {
                var host = document.getElementById('starcat-readme-star-history');
                host.starcatHistoryCleanup();
                host.replaceChildren();
                return host.childElementCount;
            })();
            """)
            #expect(cleanup as? Int == 0)
        }
    }

    /// 从真实排版结果验证单行与隐藏数据，防止 CSS 看似禁止换行但实际裁掉语言或 +N。
    private func checkHeader(_ webView: WKWebView, compact: Bool) async throws -> Int {
        let result = try await webView.evaluateJavaScript("""
        (function() {
            var description = document.querySelector('.starcat-star-history-description');
            var tags = document.querySelector('.starcat-star-history-tags');
            var visible = Array.from(tags.children).filter(function(chip) { return !chip.hidden; });
            var topics = visible.filter(function(chip) { return chip.classList.contains('starcat-star-history-tag-topic'); });
            var more = tags.querySelector('.starcat-star-history-tag-more');
            var bounds = tags.getBoundingClientRect();
            return {
                descriptionOneLine: description.clientHeight <= parseFloat(getComputedStyle(description).lineHeight) + 1,
                fullDescription: description.title === description.textContent,
                oneRow: visible.every(function(chip) { return Math.abs(chip.getBoundingClientRect().top - bounds.top) < 1; }),
                chipsFit: visible.every(function(chip) { var rect = chip.getBoundingClientRect(); return rect.left >= bounds.left && rect.right <= bounds.right + 1; }),
                language: tags.querySelector('.starcat-star-history-tag-language').textContent,
                topics: topics.map(function(chip) { return chip.textContent; }),
                hiddenCount: Number(more.textContent.slice(1)),
                hiddenNames: more.title
            };
        })();
        """)
        let info = try #require(result as? [String: Any])
        if compact { #expect(info["descriptionOneLine"] as? Bool == true) }
        #expect(info["fullDescription"] as? Bool == true)
        #expect(info["oneRow"] as? Bool == true)
        #expect(info["chipsFit"] as? Bool == true)
        #expect(info["language"] as? String == "TypeScript")
        let visible = try #require(info["topics"] as? [String])
        #expect(visible == Array(Self.topics.prefix(visible.count)))
        #expect(info["hiddenCount"] as? Int == Self.topics.count - visible.count)
        #expect(info["hiddenNames"] as? String == Self.topics.dropFirst(visible.count).joined(separator: ", "))
        return visible.count
    }

    /// 等待 document-end 脚本完成，超时只影响该测试，不让 testmanagerd 无限等待。
    private func waitForChart(_ webView: WKWebView) async throws {
        for _ in 0..<100 {
            if (try? await webView.evaluateJavaScript("document.documentElement.dataset.chartReady === 'true'")) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "ReadmeStarHistoryWebKitTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Chart script did not finish"])
    }

    /// 固定长历史和真实量级，覆盖普通平台、后期快速增长和中文/英文标签宽度。
    private func document(dark: Bool) throws -> String {
        let start = try #require(StarHistoryDateCodec.date(from: "2022-01-17"))
        let end = try #require(StarHistoryDateCodec.date(from: "2026-09-06"))
        let duration = end.timeIntervalSince(start)
        let points = (0...180).map { index -> StarHistoryPoint in
            let progress = Double(index) / 180
            let value = 1_200 + 22_000 * progress + 27_311 * pow(max(0, (progress - 0.78) / 0.22), 2)
            return StarHistoryPoint(date: start.addingTimeInterval(duration * progress), count: Int(value), fetchedAt: end)
        }
        var repo = Repo.makeMinimal(owner: "tt-a1i", name: "archify")
        repo.id = 42
        repo.starsCount = 50_511
        repo.description = "Agent skill for beautiful, verifiable architecture, workflow, sequence, data-flow, and lifecycle diagrams—self-contained HTML with motion, annotations, and interactive examples for developers."
        repo.language = "TypeScript"
        repo.topics = String(data: try JSONEncoder().encode(Self.topics), encoding: .utf8)
        // 创建日比首条历史早 27 天，覆盖用户反馈的缺失早期记录场景。
        let created = try #require(StarHistoryDateCodec.date(from: "2021-12-21"))
        repo.createdAt = "2021-12-21T00:00:00Z"
        let snapshot = StarHistorySnapshot(range: .all, points: points, remoteState: .fresh,
                                          coverageStart: start, updatedAt: end,
                                          coverage: StarHistoryCoverage(start: start, lastEvent: end, dataThrough: end,
                                                                        generatedAt: end.addingTimeInterval(86_400)))
        let model = StarHistoryChartRenderModel(points: points, range: .all, repositoryCreatedAt: created, now: end)
        let card = try #require(ReadmeStarHistoryHTMLRenderer.render(snapshot: snapshot, model: model, repo: repo,
                                                                   locale: Locale(identifier: "en"), now: end))
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:">
        <style>\(ReadmeCSS.full)\n\(ReadmeStarHistoryDOM.css)
        body { background: \(dark ? "#29262a" : "#eef1f6"); padding: 20px; }
        .starcat-star-history { margin-top: 0; }
        </style></head><body class="\(dark ? "dark" : "light")">
        <div id="starcat-readme-star-history">\(card)</div>
        <script>\(ReadmeStarHistoryDOM.script)
        configureStarHistory(document.getElementById('starcat-readme-star-history'));
        document.documentElement.dataset.chartReady = 'true';
        </script></body></html>
        """
    }

    private static let topics = [
        "agent-skills", "architecture-as-code", "architecture-diagram", "ai", "documentation",
        "diagrams", "workflow", "sequence", "data-flow", "lifecycle", "html", "svg", "animation",
        "interactive", "developer-tools", "visualization", "design", "self-hosted", "productivity", "open-source"
    ]
}
