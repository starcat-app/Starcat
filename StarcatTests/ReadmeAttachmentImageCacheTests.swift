//
//  ReadmeAttachmentImageCacheTests.swift
//  StarcatTests
//
//  独立临时目录与离线下载器验证附件缓存，不读取用户文件或发起网络请求。
//

import Foundation
import ImageIO
import Kingfisher
import Testing
import WebKit
@testable import Starcat

/// 原始文件复用、账户隔离、并发合并、容量与清理的行为回归。
@Suite("README attachment image cache")
struct ReadmeAttachmentImageCacheTests {
    /// 使用真实服务的典型端点作样本，不能直接从生产规则生成预期。
    static let commonBadgeSources = [
        "https://img.shields.io/github/stars/owner/repo",
        "https://badgen.net/npm/v/example",
        "https://badge.fury.io/js/example.svg",
        "https://badge.buildkite.com/example.svg",
        "https://img.badgesize.io/owner/repo/main/file.js",
        "https://badge.waffle.io/owner/repo.svg",
        "https://visitor-badge.laobi.icu/badge?page_id=owner.repo",
        "https://visitor-badge.glitch.me/badge?page_id=owner.repo",
        "https://hits.seeyoufarm.com/api/count/incr/badge.svg",
        "https://profile-counter.glitch.me/example/count.svg",
        "https://custom-icon-badges.demolab.com/github/stars/owner/repo",
        "https://badges.gitter.im/owner/repo.svg",
        "https://badges.frapsoft.com/os/v1/open-source.svg",
        "https://poser.pugx.org/vendor/package/v/stable",
        "https://pypip.in/version/example/badge.svg",
        "https://hits.dwyl.com/owner/repo.svg",
        "https://skills.sh/b/mattpocock/skills",
        "https://api.producthunt.com/widgets/embed-image/v1/follow.svg?product_id=123&theme=light",
        "https://api.hellogithub.com/v1/widgets/recommend.svg?rid=123&theme=neutral",
        "https://colab.research.google.com/assets/colab-badge.svg",
        "https://gitpod.io/button/open-in-gitpod.svg",
        "https://mybinder.org/badge_logo.svg",
        "https://static.mybinder.org/badge_logo.svg",
        "https://app.fossa.com/api/projects/git%2Bgithub.com%2Fowner%2Frepo.svg?type=shield",
        "https://app.fossa.com/api/projects/git%2Bgithub.com%2Fowner%2Frepo.svg?type=large",
        "https://api.travis-ci.com/owner/repo.svg?branch=main",
        "https://circleci.com/gh/owner/repo.svg?style=shield",
        "https://api.cirrus-ci.com/github/owner/repo.svg?branch=main",
        "https://ci.appveyor.com/api/projects/status/example?svg=true",
        "https://api.netlify.com/api/v1/badges/example/deploy-status",
        "https://coveralls.io/repos/github/owner/repo/badge.svg?branch=main",
        "https://goreportcard.com/badge/github.com/owner/repo",
        "https://static.pepy.tech/personalized-badge/example?period=total&units=international_system",
        "https://pepy.tech/badge/example",
        "https://www.repostatus.org/badges/latest/active.svg",
        "https://david-dm.org/owner/repo.svg?theme=shields.io",
        "https://bettercodehub.com/edge/badge/owner/repo?branch=main",
        "https://www.codefactor.io/repository/github/owner/repo/badge",
        "https://packagephobia.com/badge?p=example",
        "https://hitscounter.dev/api/hit?url=example",
        "https://komarev.com/ghpvc/?username=example",
        "https://nodei.co/npm/example.png",
        "https://pkg.go.dev/example?status.svg",
        "https://godoc.org/example?status.svg",
        "https://opencollective.com/example/sponsors.svg?width=200",
        "https://github.com/owner/repo/actions/workflows/ci.yml/badge.svg?branch=main",
        "https://codecov.io/gh/owner/repo/branch/main/graph/badge.svg?token=example",
        "https://readthedocs.org/projects/example/badge/?version=latest",
        "https://sonarcloud.io/api/project_badges/measure?project=example&metric=alert_status",
        "https://api.codacy.com/project/badge/Grade/example",
        "https://scrutinizer-ci.com/g/owner/repo/badges/quality-score.png",
        "https://snyk.io/test/github/owner/repo/badge.svg",
        "https://trendshift.io/api/badge/repositories/18527",
        "https://zenodo.org/badge/DOI/10.1234/example.svg",
        "https://joss.theoj.org/papers/example/status.svg",
        "https://bestpractices.coreinfrastructure.org/projects/123/badge",
        "https://www.codefactor.io/repository/github/owner/repo/badge?style=flat"
    ]
    private static let remote = "https://github.com/user-attachments/assets/2cd4a6ec-eb1e-4b45-8627-a76442ea3874"
    private static let gif = ReadmeAttachmentImage(
        data: Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAAh+QQBAAAAACwAAAAAAQABAAACAUQAOw==")!,
        mimeType: "image/gif"
    )

    /// 每例使用独立目录，重建 cache 实例模拟 App 重启后的磁盘命中。
    @Test("重复读取与实例重建复用原始文件，账户互相隔离")
    func diskReuseAndAccounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = Downloads()
        let cache = ReadmeAttachmentImageCache(directory: directory, loader: { try await loader.load($0) })
        let url = try #require(URL(string: ReadmeAttachmentImageURL.cachedSource(Self.remote)))
        #expect(try await cache.image(for: url, accountID: 1) == Self.gif)
        #expect(try await cache.image(for: url, accountID: 1) == Self.gif)
        #expect(await loader.count == 1)
        let restarted = ReadmeAttachmentImageCache(directory: directory, loader: { try await loader.load($0) })
        #expect(try await restarted.image(for: url, accountID: 1) == Self.gif)
        let source = try #require(CGImageSourceCreateWithData(Self.gif.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        #expect(await loader.count == 1)
        #expect(try await restarted.image(for: url, accountID: 2) == Self.gif)
        #expect(try await restarted.image(for: url, accountID: nil) == Self.gif)
        #expect(await loader.count == 3)
        #expect(await restarted.diskSize() > 0)
    }

    @Test("同时请求同一附件只下载一次")
    func concurrentReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = Downloads(delay: .milliseconds(100))
        let cache = ReadmeAttachmentImageCache(directory: directory, loader: { try await loader.load($0) })
        let url = try #require(URL(string: ReadmeAttachmentImageURL.cachedSource(Self.remote)))
        let images = try await withThrowingTaskGroup(of: ReadmeAttachmentImage.self) { group in
            for _ in 0..<8 { group.addTask { try await cache.image(for: url, accountID: 1) } }
            var results: [ReadmeAttachmentImage] = []
            for try await image in group { results.append(image) }
            return results
        }
        #expect(images.count == 8)
        #expect(images.allSatisfy { $0 == Self.gif })
        #expect(await loader.count == 1)
    }

    @Test("失败响应不缓存，重试可以恢复")
    func failedResponseIsRetried() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = Downloads(failFirst: true)
        let cache = ReadmeAttachmentImageCache(directory: directory, loader: { try await loader.load($0) })
        let url = try #require(URL(string: ReadmeAttachmentImageURL.cachedSource(Self.remote)))
        do {
            _ = try await cache.image(for: url, accountID: 1)
            Issue.record("首次下载应失败")
        } catch {}
        #expect(await cache.diskSize() == 0)
        #expect(try await cache.image(for: url, accountID: 1) == Self.gif)
        #expect(await loader.count == 2)
    }

    @Test("清理阻止迟到下载写回，并允许重新下载")
    func clearDuringDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = Downloads(delay: .milliseconds(150))
        let cache = ReadmeAttachmentImageCache(directory: directory, loader: { try await loader.load($0) })
        let url = try #require(URL(string: ReadmeAttachmentImageURL.cachedSource(Self.remote)))
        let request = Task { try await cache.image(for: url, accountID: 1) }
        for _ in 0..<100 {
            if await loader.count > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await cache.clear()
        do {
            _ = try await request.value
            Issue.record("清理后的旧任务不应成功结算")
        } catch {}
        #expect(await cache.diskSize() == 0)
        #expect(try await cache.image(for: url, accountID: 1) == Self.gif)
        #expect(await loader.count == 2)
    }

    @Test("过期与容量规则限制磁盘占用")
    func expirationAndCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = Downloads()
        let cache = ReadmeAttachmentImageCache(directory: directory, sizeLimit: 600,
                                              expiration: .seconds(0.1), loader: { try await loader.load($0) })
        let url = try #require(URL(string: ReadmeAttachmentImageURL.cachedSource(Self.remote)))
        for account in 1...6 { _ = try await cache.image(for: url, accountID: Int64(account)) }
        #expect(await cache.diskSize() <= 600)
        // Kingfisher 文件日期按整秒存储；直接令 fixture 过期，避免亚秒等待产生偶发失败。
        let files = try #require(FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ))
        for file in files.allObjects.compactMap({ $0 as? URL }) {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: file.path)
            }
        }
        #expect(await cache.diskSize() == 0)
        _ = try await cache.image(for: url, accountID: 6)
        #expect(await loader.count == 7)
    }

    @Test("展示路由附件与普通内容图，不改变链接或视频")
    func displayRouting() {
        let html = """
        <a href="\(Self.remote)"><picture><source srcset="  \(Self.remote) 1x,\thttps://example.com/x.png 2x">
        <img width="900" src="\(Self.remote)" data-canonical-src="\(Self.remote)"></picture></a>
        <video src="\(Self.remote)"><source srcset="\(Self.remote)"></video>
        <img src="https://example.com/plain.png">
        """
        let result = ReadmeAssetURLRewriter.rewriteAttachmentImagesForDisplay(in: html)
        let cached = ReadmeAttachmentImageURL.cachedSource(Self.remote)
        #expect(result.contains("srcset=\"  \(cached) 1x,\t\(ReadmeAttachmentImageURL.cachedSource("https://example.com/x.png")) 2x\""))
        #expect(result.contains("<img width=\"900\" src=\"\(cached)\""))
        #expect(result.contains("<a href=\"\(Self.remote)\">"))
        #expect(result.contains("data-canonical-src=\"\(Self.remote)\""))
        #expect(result.contains("<video src=\"\(Self.remote)\"><source srcset=\"\(Self.remote)\">"))
        #expect(result.contains("<img src=\"\(ReadmeAttachmentImageURL.cachedSource("https://example.com/plain.png"))\">"))
        #expect(ReadmeAssetURLRewriter.rewriteAttachmentImagesForDisplay(in: result) == result)
        #expect(ReadmeAttachmentImageURL.remoteURL(for: URL(string: cached)!)?.absoluteString == Self.remote)
        #expect(ReadmeAttachmentImageURL.remoteURL(for: URL(string: "starcat-readme-image://other/a")!) == nil)
    }

    @Test("常见徽标保持 HTTP 缓存语义", arguments: commonBadgeSources)
    func badgeSourceRouting(source: String) {
        #expect(ReadmeImageBadgeRules.isBadge(source))
        #expect(ReadmeAttachmentImageURL.cachedSource(source) == source)
    }

    @Test("普通图片完整保留 URL，内部路由拒绝非远端协议与凭据")
    func remoteImageRouting() throws {
        for source in [
            "https://example.com/path/a.png?size=large&v=1#image",
            "http://localhost:8080/diagram.svg?name=%E5%9B%BE&query=a%26b",
            "https://api.producthunt.com/screenshots/app.png",
            "https://hellogithub.com/images/screenshot.png",
            "https://skills.sh/images/screenshot.png",
            "https://colab.research.google.com/assets/screenshot.png",
            "https://gitpod.io/images/workspace.png",
            "https://mybinder.org/images/architecture.svg",
            "https://app.fossa.com/images/report.svg",
            "https://opencollective.com/example/sponsors/0/avatar.svg",
            "https://shields.io.example.com/screenshot.png"
        ] {
            #expect(!ReadmeImageBadgeRules.isBadge(source))
            let cached = ReadmeAttachmentImageURL.cachedSource(source)
            #expect(cached.hasPrefix("starcat-readme-image://remote/"))
            #expect(ReadmeAttachmentImageURL.cachedSource(cached) == cached)
            #expect(ReadmeAttachmentImageURL.remoteURL(for: try #require(URL(string: cached)))?.absoluteString == source)
        }
        for source in ["file:///tmp/a.png", "data:image/png;base64,abc", "https://user@example.com/a.png",
                       "https://:secret@example.com/a.png"] {
            #expect(ReadmeAttachmentImageURL.cachedSource(source) == source)
            var components = URLComponents(string: "starcat-readme-image://remote/")!
            components.queryItems = [URLQueryItem(name: "url", value: source)]
            #expect(ReadmeAttachmentImageURL.remoteURL(for: try #require(components.url)) == nil)
        }
    }

    @Test("远端 URL 不因主机、路径、参数相同片段而串缓存，重启仍复用")
    func remoteCacheIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ImageDownloadCounter()
        let cache = ReadmeAttachmentImageCache(directory: directory, loader: { _ in
            await counter.increment()
            return Self.gif
        })
        let sources = ["https://one.example/a.png?v=1", "https://two.example/a.png?v=1",
                       "https://one.example/b.png?v=1", "https://one.example/a.png?v=2"]
        for source in sources {
            let url = try #require(URL(string: ReadmeAttachmentImageURL.cachedSource(source)))
            _ = try await cache.image(for: url, accountID: 1)
        }
        #expect(await counter.count == sources.count)
        let restarted = ReadmeAttachmentImageCache(directory: directory, loader: { _ in
            Issue.record("重建后应命中磁盘")
            return Self.gif
        })
        for source in sources {
            let url = try #require(URL(string: ReadmeAttachmentImageURL.cachedSource(source)))
            #expect(try await restarted.image(for: url, accountID: 1) == Self.gif)
        }
        #expect(await counter.count == sources.count)
    }

    @Test("HTML 参数实体只解码一次，徽标与 canonical 保持原样")
    func escapedImageAttributes() throws {
        let source = "https://example.com/image.svg?a=1&b=2&name=\"quote\"&literal=&amp;"
        let html = """
        <img src="https://example.com/image.svg?a=1&amp;b=2&#38;name=&quot;quote&quot;&amp;literal=&amp;amp;">
        <img src="https://camo.githubusercontent.com/hash" data-canonical-src="https://skills.sh/b/owner/repo">
        """
        let routed = ReadmeAssetURLRewriter.rewriteAttachmentImagesForDisplay(in: html)
        #expect(routed.contains(ReadmeAttachmentImageURL.cachedSource(source).replacingOccurrences(of: "&", with: "&amp;")))
        #expect(routed.contains("<img src=\"https://camo.githubusercontent.com/hash\""))
        #expect(ReadmeAssetURLRewriter.rewriteAttachmentImagesForDisplay(in: routed) == routed)
    }

    @Test("HTTP 错误、错误 MIME 与截断图片均被拒绝")
    func validatesOriginalImage() throws {
        let url = try #require(URL(string: Self.remote))
        let valid = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                              headerFields: ["Content-Type": "image/gif"]))
        #expect(try ReadmeAttachmentImageCache.validatedImage(data: Self.gif.data, response: valid) == Self.gif)
        for (code, mime, data) in [(404, "image/gif", Self.gif.data),
                                   (200, "text/html", Data("<html>error</html>".utf8)),
                                   (200, "image/png", Data([0x89, 0x50, 0x4e, 0x47]))] {
            let response = try #require(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil,
                                                      headerFields: ["Content-Type": mime]))
            #expect(throws: (any Error).self) {
                try ReadmeAttachmentImageCache.validatedImage(data: data, response: response)
            }
        }
    }

    @MainActor
    @Test("设置图片缓存统计和清理包含 README 附件")
    func cleanerIncludesAttachments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ReadmeAttachmentImageCache(directory: directory, loader: { _ in Self.gif })
        let url = try #require(URL(string: ReadmeAttachmentImageURL.cachedSource(Self.remote)))
        _ = try await cache.image(for: url, accountID: 1)
        let imageCache = try ImageCache(name: UUID().uuidString, cacheDirectoryURL: directory)
        let cleaner = CacheCleaner(
            readmeRepository: ReadmeRepository(database: try InMemoryDatabaseManager()),
            fixedArchiveDirectory: directory.appendingPathComponent("archives"),
            attachmentImages: cache, imageCache: imageCache
        )
        let statistics = await cleaner.loadStatistics()
        #expect(statistics.imageDiskBytes > 0)
        await cleaner.clearImageCache()
        #expect(await cache.diskSize() == 0)
        let after = await cleaner.loadStatistics()
        #expect(after.imageDiskBytes == 0)
    }

    /// 离线下载计数器可以模拟延迟与错误；故意忽略取消以覆盖迟到返回防护。
    private actor Downloads {
        var count = 0
        let delay: Duration
        let failFirst: Bool

        init(delay: Duration = .zero, failFirst: Bool = false) {
            self.delay = delay
            self.failFirst = failFirst
        }

        func load(_ url: URL) async throws -> ReadmeAttachmentImage {
            count += 1
            #expect(url.absoluteString == ReadmeAttachmentImageCacheTests.remote)
            if delay != .zero { try? await Task.sleep(for: delay) }
            if failFirst && count == 1 { throw URLError(.networkConnectionLost) }
            return ReadmeAttachmentImageCacheTests.gif
        }
    }
}

/// 真实无窗口 WebKit 验证：正文、放大预览与新 WebView 都能复用同一原始 GIF。
@MainActor
@Suite("README attachment image WebKit", .serialized)
struct ReadmeAttachmentImageWebKitTests {
    @Test("WebKit stop 后不再收到迟到回调，共享下载仍可复用")
    func stoppedTaskDoesNotReceiveCallbacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ImageDownloadCounter()
        let cache = ReadmeAttachmentImageCache(directory: directory, loader: { _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(100))
            return ReadmeAttachmentImage(
                data: Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!,
                mimeType: "image/gif"
            )
        })
        let source = ReadmeAttachmentImageURL.cachedSource(
            "https://github.com/user-attachments/assets/2cd4a6ec-eb1e-4b45-8627-a76442ea3874"
        )
        let url = try #require(URL(string: source))
        let schemeTask = StoppedImageTask(url: url)
        let handler = ReadmeAttachmentImageSchemeHandler(accountID: 9, cache: cache)
        let view = WKWebView(frame: .zero)
        handler.webView(view, start: schemeTask)
        for _ in 0..<100 {
            if await counter.count == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await counter.count == 1)
        handler.webView(view, stop: schemeTask)
        let result = try await cache.image(for: url, accountID: 9)
        #expect(result.mimeType == "image/gif")
        #expect(schemeTask.callbackCount == 0)
        #expect(await counter.count == 1)
    }

    @Test("正文与独立图片浏览器共用原始文件，重建后仍只下载一次", arguments: [
        "https://github.com/user-attachments/assets/2cd4a6ec-eb1e-4b45-8627-a76442ea3874",
        "https://example.com/readme/image.gif?size=large&v=2"
    ])
    func webKitUsesCache(source: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ImageDownloadCounter()
        for _ in 0..<2 {
            let cache = ReadmeAttachmentImageCache(directory: directory, loader: { requested in
                #expect(requested.absoluteString == source)
                await counter.increment()
                return ReadmeAttachmentImage(
                    data: Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAAh+QQBAAAAACwAAAAAAQABAAACAUQAOw==")!,
                    mimeType: "image/gif"
                )
            })
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let sink = ImageMessageSink()
            for name in ["readmeScroll", "readmeTranslationSource", "readmeMermaidRequest", ReadmeImagePreviewController.messageName] {
                config.userContentController.add(sink, name: name)
            }
            config.userContentController.addUserScript(WKUserScript(
                source: ReadmeWebView.readmeEnhancementScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true
            ))
            config.setURLSchemeHandler(ReadmeAttachmentImageSchemeHandler(accountID: 9, cache: cache),
                                       forURLScheme: ReadmeAttachmentImageURL.scheme)
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: config)
            defer { view.stopLoading() }
            view.loadHTMLString(ReadmeWebView.assembleDocument(fragment: """
            <picture><source srcset="\(source.replacingOccurrences(of: "&", with: "&amp;"))">
            <img id="test" src="https://example.invalid/fallback.gif"></picture>
            """, isDark: false), baseURL: nil)
            var loaded = false
            for _ in 0..<150 {
                if (try? await view.evaluateJavaScript("document.querySelector('#test')?.naturalWidth > 0")) as? Bool == true {
                    loaded = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(loaded)
            let current = try await view.evaluateJavaScript("document.querySelector('#test').currentSrc") as? String
            #expect(current == ReadmeAttachmentImageURL.cachedSource(source))
            _ = try await view.evaluateJavaScript("document.querySelector('#test').click()")
            for _ in 0..<150 {
                if sink.previewRequest != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let request = try #require(sink.previewRequest)
            #expect(request.images.first?.src == current)
            let galleryConfig = ReadmeImagePreviewController.configuration(
                request: request, accountID: 9, reduceMotion: false, imageCache: cache
            )
            galleryConfig.websiteDataStore = .nonPersistent()
            galleryConfig.userContentController.add(sink, name: ReadmeImagePreviewController.messageName)
            let gallery = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700), configuration: galleryConfig)
            defer { gallery.stopLoading() }
            gallery.loadHTMLString(ReadmeWebView.assembleDocument(fragment: "", isDark: false), baseURL: nil)
            var previewLoaded = false
            for _ in 0..<150 {
                if (try? await gallery.evaluateJavaScript("document.querySelector('.readme-image-preview-image')?.hidden === false")) as? Bool == true {
                    previewLoaded = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(previewLoaded)
            #expect(await counter.count == 1)
        }
        #expect(await counter.count == 1)
    }
}

/// 独立 actor 记录 WebKit fixture 的网络次数，不在主线程共享可变状态。
private actor ImageDownloadCounter {
    var count = 0
    func increment() { count += 1 }
}

/// 捕获生产脚本发出的预览请求，让独立浏览器加载测试复用真实正文中的图片地址。
@MainActor
private final class ImageMessageSink: NSObject, WKScriptMessageHandler {
    var previewRequest: ReadmeImagePreviewRequest?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let request = ReadmeImagePreviewRequest(messageBody: message.body) { previewRequest = request }
    }
}

/// stop 场景只记录回调；任何回调都意味着生产环境可能触发 WebKit 已停止任务异常。
/// WKURLSchemeTask 未声明 actor；fixture 只从主线程 handler 调用，以运行时隔离检查桥接。
@MainActor
private final class StoppedImageTask: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    var callbackCount = 0

    init(url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { callbackCount += 1 }
    func didReceive(_ data: Data) { callbackCount += 1 }
    func didFinish() { callbackCount += 1 }
    func didFailWithError(_ error: any Error) { callbackCount += 1 }
}
