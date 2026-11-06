//
//  FollowGraphAvatarCacheTests.swift
//  StarcatTests
//
//  独立 Kingfisher 目录和可控下载器验证重开/离线缓存，不读写用户图片，不访问网络。
//

import Foundation
import Kingfisher
import Testing
import WebKit
@testable import Starcat

/// 验证 URL 边界、共用缓存键、磁盘复用和错误恢复。
@Suite("Follow graph avatar cache")
struct FollowGraphAvatarCacheTests {
    static let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
    static let remote = "https://avatars.githubusercontent.com/u/42?v=4"
    static var local: URL { URL(string: FollowGraphAvatarURL.source(remote))! }
    static var load: URL {
        var parts = URLComponents(url: local, resolvingAgainstBaseURL: false)!
        parts.host = "load"
        return parts.url!
    }

    @Test("规范化缓存键与原生头像一致，拒绝越界地址及重复参数")
    func addresses() throws {
        let request = try #require(FollowGraphAvatarURL.request(Self.local))
        #expect(request.cacheOnly)
        #expect(request.remote == GitHubAvatarURL.imageURL(from: Self.remote, displayDiameter: 32))
        #expect(FollowGraphAvatarURL.request(Self.load)?.cacheOnly == false)
        for raw in ["http://avatars.githubusercontent.com/u/1", "https://example.com/u/1",
                    "https://user@avatars.githubusercontent.com/u/1", "https://avatars.githubusercontent.com:443/u/1",
                    "https://avatars.githubusercontent.com/u/1#fragment", "file:///tmp/avatar"] {
            #expect(FollowGraphAvatarURL.source(raw).isEmpty)
        }
        for raw in [Self.local.absoluteString + "&url=duplicate",
                    Self.local.absoluteString.replacingOccurrences(of: "://cache/", with: "://other/"),
                    Self.local.absoluteString.replacingOccurrences(of: "/image?", with: "/other?"),
                    Self.local.absoluteString + "#fragment"] {
            #expect(FollowGraphAvatarURL.request(try #require(URL(string: raw))) == nil)
        }
    }

    @Test("首次 miss 零网络，下载一次后重建实例断网命中磁盘")
    func reopenOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = Downloads()
        var cache: FollowGraphAvatarCache? = FollowGraphAvatarCache(
            cacheName: "avatars", directory: directory, loader: { _ in await downloads.load() }
        )
        do {
            _ = try await cache!.image(for: Self.local)
            Issue.record("空缓存必须返回 miss")
        } catch {}
        #expect(await downloads.count == 0)
        #expect(try await cache!.image(for: Self.load).data == Self.gif)
        #expect(try await cache!.image(for: Self.local).data == Self.gif)
        #expect(await downloads.count == 1)
        cache = nil
        let offline = Downloads(offline: true)
        let reopened = FollowGraphAvatarCache(
            cacheName: "avatars", directory: directory, loader: { _ in await offline.load() }
        )
        #expect(try await reopened.image(for: Self.local).data == Self.gif)
        #expect(try await reopened.image(for: Self.load).data == Self.gif)
        #expect(await offline.count == 0)
    }

    @Test("原生缓存字节可直接复用；过期与损坏内容重新下载")
    func sharedKeysAndInvalidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let native = try ImageCache(name: "avatars", cacheDirectoryURL: directory)
        let key = try #require(FollowGraphAvatarURL.request(Self.local)?.remote.absoluteString)
        try native.diskStorage.store(value: Self.gif, forKey: key)
        let downloads = Downloads()
        let graph = FollowGraphAvatarCache(
            cacheName: "avatars", directory: directory, loader: { _ in await downloads.load() }
        )
        #expect(try await graph.image(for: Self.local).data == Self.gif)
        #expect(await downloads.count == 0)
        // Kingfisher 对 .expired 写入直接 no-op，不能用它覆盖旧文件来模拟过期。
        // 新 key 写入短 TTL，且过期前不读取，避免读取动作延长有效期。
        let expiringRaw = Self.remote.replacingOccurrences(of: "/42", with: "/43")
        let expiringKey = try #require(GitHubAvatarURL.imageURL(from: expiringRaw, displayDiameter: 32)?.absoluteString)
        let expiringURL = try #require(URL(string: FollowGraphAvatarURL.source(expiringRaw)
            .replacingOccurrences(of: "://cache/", with: "://load/")))
        try native.diskStorage.store(value: Self.gif, forKey: expiringKey, expiration: .seconds(0.01))
        try await Task.sleep(for: .milliseconds(30))
        #expect(try await graph.image(for: expiringURL).data == Self.gif)
        #expect(await downloads.count == 1)
        try native.diskStorage.store(value: Data("not an image".utf8), forKey: key)
        #expect(try await graph.image(for: Self.load).data == Self.gif)
        #expect(await downloads.count == 2)
    }

    @Test("网络失败与错误页均不写缓存，后续可重试")
    func failures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = Downloads(failFirst: true)
        let cache = FollowGraphAvatarCache(
            cacheName: "avatars", directory: directory, loader: { _ in await downloads.load() }
        )
        for _ in 0..<2 {
            do {
                _ = try await cache.image(for: Self.load)
                Issue.record("错误响应不能作为头像返回")
            } catch {}
            do {
                _ = try await cache.image(for: Self.local)
                Issue.record("错误响应不能写缓存")
            } catch {}
        }
        #expect(try await cache.image(for: Self.load).data == Self.gif)
        #expect(await downloads.count == 3)
    }

    @Test("节点复用卡片 224px 缓存，卡片成功后可补齐 64px key")
    func cardSizeReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let native = try ImageCache(name: "avatars", cacheDirectoryURL: directory)
        let cardURL = try #require(GitHubAvatarURL.imageURL(from: Self.remote, displayDiameter: 112))
        #expect(URLComponents(url: cardURL, resolvingAgainstBaseURL: false)?.queryItems?.last?.value == "224")
        try native.diskStorage.store(value: Self.gif, forKey: cardURL.absoluteString)
        let downloads = Downloads(offline: true)
        let graph = FollowGraphAvatarCache(
            cacheName: "avatars", directory: directory, loader: { _ in await downloads.load() }
        )
        #expect(try await graph.image(for: Self.local).data == Self.gif)
        let key = try #require(FollowGraphAvatarURL.request(Self.local)?.remote.absoluteString)
        #expect(try native.diskStorage.value(forKey: key) == Self.gif)
        try native.diskStorage.remove(forKey: key)
        #expect(try await graph.promoteCardImage(from: cardURL))
        #expect(try native.diskStorage.value(forKey: key) == Self.gif)
        #expect(await downloads.count == 0)
        // 不把其他版本或其他用户的头像误当成同一张缓存。
        for raw in [Self.remote.replacingOccurrences(of: "v=4", with: "v=5"),
                    Self.remote.replacingOccurrences(of: "/42", with: "/43")] {
            let url = try #require(URL(string: FollowGraphAvatarURL.source(raw)))
            do {
                _ = try await graph.image(for: url)
                Issue.record("不能跨用户或头像版本复用")
            } catch {}
        }
        #expect(await downloads.count == 0)
    }

    /// 隔离计数与可控失败，不依赖 URLSession 或用户网络环境。
    actor Downloads {
        var count = 0
        let offline: Bool
        let failFirst: Bool
        init(offline: Bool = false, failFirst: Bool = false) {
            self.offline = offline
            self.failFirst = failFirst
        }
        func load() -> Data? {
            count += 1
            if offline || (failFirst && count == 1) { return nil }
            if failFirst && count == 2 { return Data("<html>error</html>".utf8) }
            return FollowGraphAvatarCacheTests.gif
        }
    }
}

/// 不显示窗口；只驱动原生 delegate，验证 stop / 拆除不会回调已失效的 WebKit 请求。
@MainActor
@Suite("Follow graph avatar scheme", .serialized)
struct FollowGraphAvatarSchemeTests {
    @Test("stop 和原生拆除立即失效，迟到下载不能交付或落盘", arguments: [false, true])
    func cancelledRequest(cancelAll: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = DownloadGate()
        let cache = FollowGraphAvatarCache(cacheName: "avatars", directory: directory, loader: { _ in
            await gate.wait()
            return FollowGraphAvatarCacheTests.gif
        })
        let handler = FollowGraphAvatarSchemeHandler(cache: cache)
        let view = WKWebView(frame: .zero)
        let request = AvatarSchemeTask(url: FollowGraphAvatarCacheTests.load)
        handler.webView(view, start: request)
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.started)
        if cancelAll { handler.cancelAll() }
        else { handler.webView(view, stop: request) }
        await gate.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(request.callbacks == 0)
        do {
            _ = try await cache.image(for: FollowGraphAvatarCacheTests.local)
            Issue.record("取消后的迟到下载不能写缓存")
        } catch {}
    }
}

/// 模拟不响应取消的网络层，用显式门闩验证迟到结果。
private actor DownloadGate {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

/// delegate 仅在主线程调用；记录任何回调而不创建可见 WebKit 页面。
@MainActor
private final class AvatarSchemeTask: NSObject, @preconcurrency WKURLSchemeTask {
    let request: URLRequest
    var callbacks = 0
    init(url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { callbacks += 1 }
    func didReceive(_ data: Data) { callbacks += 1 }
    func didFinish() { callbacks += 1 }
    func didFailWithError(_ error: any Error) { callbacks += 1 }
}
