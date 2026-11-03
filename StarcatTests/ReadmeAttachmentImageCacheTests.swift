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

    @Test("展示只替换附件图片，不改变数据库 HTML、链接或视频")
    func displayRouting() {
        let html = """
        <a href="\(Self.remote)"><picture><source srcset="  \(Self.remote) 1x,\thttps://example.com/x.png 2x">
        <img width="900" src="\(Self.remote)" data-canonical-src="\(Self.remote)"></picture></a>
        <video src="\(Self.remote)"><source srcset="\(Self.remote)"></video>
        <img src="https://example.com/plain.png">
        """
        let result = ReadmeAssetURLRewriter.rewriteAttachmentImagesForDisplay(in: html)
        let cached = ReadmeAttachmentImageURL.cachedSource(Self.remote)
        #expect(result.contains("srcset=\"  \(cached) 1x,\thttps://example.com/x.png 2x\""))
        #expect(result.contains("<img width=\"900\" src=\"\(cached)\""))
        #expect(result.contains("<a href=\"\(Self.remote)\">"))
        #expect(result.contains("data-canonical-src=\"\(Self.remote)\""))
        #expect(result.contains("<video src=\"\(Self.remote)\"><source srcset=\"\(Self.remote)\">"))
        #expect(result.contains("<img src=\"https://example.com/plain.png\">"))
        #expect(ReadmeAssetURLRewriter.rewriteAttachmentImagesForDisplay(in: result) == result)
        #expect(ReadmeAttachmentImageURL.remoteURL(for: URL(string: cached)!)?.absoluteString == Self.remote)
        #expect(ReadmeAttachmentImageURL.remoteURL(for: URL(string: "starcat-readme-image://other/a")!) == nil)
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

    @Test("首次显示与再次打开经专用 scheme 命中磁盘")
    func webKitUsesCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let counter = ImageDownloadCounter()
        let cache = ReadmeAttachmentImageCache(directory: directory, loader: { _ in
            await counter.increment()
            return ReadmeAttachmentImage(
                data: Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAAh+QQBAAAAACwAAAAAAQABAAACAUQAOw==")!,
                mimeType: "image/gif"
            )
        })
        for _ in 0..<2 {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let sink = ImageMessageSink()
            for name in ["readmeScroll", "readmeTranslationSource", "readmeMermaidRequest"] {
                config.userContentController.add(sink, name: name)
            }
            config.userContentController.addUserScript(WKUserScript(
                source: ReadmeWebView.readmeEnhancementScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true
            ))
            config.setURLSchemeHandler(ReadmeAttachmentImageSchemeHandler(accountID: 9, cache: cache),
                                       forURLScheme: ReadmeAttachmentImageURL.scheme)
            let view = WKWebView(frame: .zero, configuration: config)
            defer { view.stopLoading() }
            view.loadHTMLString(ReadmeWebView.assembleDocument(fragment: """
            <picture><source srcset="https://github.com/user-attachments/assets/2cd4a6ec-eb1e-4b45-8627-a76442ea3874">
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
            #expect(current?.hasPrefix("starcat-readme-image://attachment/") == true)
            _ = try await view.evaluateJavaScript("document.querySelector('#test').click()")
            var previewLoaded = false
            for _ in 0..<150 {
                if (try? await view.evaluateJavaScript("document.querySelector('.readme-image-preview img')?.naturalWidth > 0")) as? Bool == true {
                    previewLoaded = true
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(previewLoaded)
        }
        #expect(await counter.count == 1)
    }
}

/// 独立 actor 记录 WebKit fixture 的网络次数，不在主线程共享可变状态。
private actor ImageDownloadCounter {
    var count = 0
    func increment() { count += 1 }
}

/// 增强脚本的消息接收端为空操作，fixture 只观察图片和真实预览加载结果。
@MainActor
private final class ImageMessageSink: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
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
