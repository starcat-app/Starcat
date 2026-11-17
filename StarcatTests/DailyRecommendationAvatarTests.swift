//
//  DailyRecommendationAvatarTests.swift
//  StarcatTests
//
//  使用隔离的加载闭包验证头像整批就绪、并发预算及取消；不访问 GitHub 或操作窗口。
//

import Foundation
import ImageIO
import Kingfisher
import Testing
@testable import Starcat

/// 忽略取消的测试下载通过 continuation 手动结束，确保超时不依赖下载配合。
@Suite("每日推荐头像准备")
@MainActor
struct DailyRecommendationAvatarTests {
    @Test("同 owner 忽略大小写去重，最多四路并发，整批完成前不返回")
    func deduplicatesAndLimitsConcurrency() async {
        let store = DailyRecommendationAvatarStore()
        let items = (0..<6).map { item("owner\($0)") } + [item("OWNER0", repo: "other")]
        var waiting: [String: CheckedContinuation<String?, Never>] = [:]
        var calls: [String] = []
        var completed = false
        let preparation = Task {
            await store.prepareBatch(items: items, accountID: 1, revision: 1) { url in
                calls.append(url.absoluteString)
                return await withCheckedContinuation { waiting[url.absoluteString] = $0 }
            }
            completed = true
        }
        while waiting.count < 4 { await Task.yield() }
        #expect(!completed)
        #expect(calls.count == 4)
        let firstKey = waiting.keys.sorted()[0]
        waiting.removeValue(forKey: firstKey)?.resume(returning: "first")
        while calls.count < 5 { await Task.yield() }
        #expect(waiting.count == 4)
        let secondKey = waiting.keys.sorted()[0]
        waiting.removeValue(forKey: secondKey)?.resume(returning: "second")
        while calls.count < 6 { await Task.yield() }
        #expect(!completed)
        #expect(waiting.count == 4)
        for continuation in waiting.values { continuation.resume(returning: "prepared") }
        await preparation.value
        #expect(completed)
        #expect(Set(calls).count == 6)
        #expect(items.allSatisfy { store.dataURI(for: $0, accountID: 1, revision: 1) != nil })
        #expect(DailyRecommendationAvatarStore.imageURL(for: items[0])?.absoluteString
            == "https://github.com/owner0.png?size=512")
    }

    @Test("重开复用成功与失败结果，显式重试仅补失败头像")
    func reusesPreparedBatchAndRetriesFailures() async {
        let store = DailyRecommendationAvatarStore()
        let items = [item("success"), item("failure")]
        var calls = 0
        for _ in 0..<2 {
            await store.prepareBatch(items: items, accountID: 1, revision: 1) { url in
                calls += 1
                return url.path.contains("success") ? "saved" : nil
            }
        }
        #expect(calls == 2)
        #expect(store.dataURI(for: items[0], accountID: 1, revision: 1) == "saved")
        #expect(store.dataURI(for: items[1], accountID: 1, revision: 1) == nil)
        await store.prepareBatch(items: items, accountID: 1, revision: 1, retryFailed: true) { _ in
            calls += 1
            return "recovered"
        }
        #expect(calls == 3)
        #expect(store.dataURI(for: items[0], accountID: 1, revision: 1) == "saved")
        #expect(store.dataURI(for: items[1], accountID: 1, revision: 1) == "recovered")
    }

    @Test("失败冷却到期允许重新准备，成功图片继续复用")
    func retriesAfterCooldown() async {
        let store = DailyRecommendationAvatarStore()
        let items = [item("success"), item("failure")]
        let now = ContinuousClock.now
        var calls = 0
        for elapsed in [0, 60, 301] {
            await store.prepareBatch(items: items, accountID: 1, revision: 1, now: now.advanced(by: .seconds(elapsed))) { url in
                calls += 1
                return url.path.contains("success") ? "saved" : nil
            }
        }
        #expect(calls == 3)
        #expect(store.dataURI(for: items[0], accountID: 1, revision: 1) == "saved")
    }

    @Test("整批超时立即返回，不等待忽略取消的下载、不启动剩余队列")
    func timeoutDoesNotWaitForDownloads() async {
        let store = DailyRecommendationAvatarStore()
        let items = (0..<10).map { item("owner\($0)") }
        var waiting: [CheckedContinuation<String?, Never>] = []
        var finished = 0
        let start = ContinuousClock.now
        await store.prepareBatch(items: items, accountID: 1, revision: 1, timeout: .milliseconds(80)) { _ in
            defer { finished += 1 }
            return await withCheckedContinuation { waiting.append($0) }
        }
        #expect(start.duration(to: .now) < .seconds(2))
        #expect(waiting.count == 4)
        #expect(finished == 0)
        #expect(items.allSatisfy { store.dataURI(for: $0, accountID: 1, revision: 1) == nil })
        for continuation in waiting { continuation.resume(returning: "late") }
        while finished < waiting.count { await Task.yield() }
        #expect(items.allSatisfy { store.dataURI(for: $0, accountID: 1, revision: 1) == nil })
    }

    @Test("部分成功、明确失败和超时混合时保留已完成头像")
    func timeoutKeepsPartialSuccess() async {
        let store = DailyRecommendationAvatarStore()
        let items = [item("success"), item("failure"), item("slow")]
        var waiting: CheckedContinuation<String?, Never>?
        await store.prepareBatch(items: items, accountID: 1, revision: 1, timeout: .milliseconds(80)) { url in
            if url.path.contains("success") { return "ready" }
            if url.path.contains("failure") { return nil }
            return await withCheckedContinuation { waiting = $0 }
        }
        #expect(store.dataURI(for: items[0], accountID: 1, revision: 1) == "ready")
        #expect(store.dataURI(for: items[1], accountID: 1, revision: 1) == nil)
        #expect(store.dataURI(for: items[2], accountID: 1, revision: 1) == nil)
        waiting?.resume(returning: "late")
    }

    @Test("零预算或空批次直接结束，不启动下载")
    func emptyOrExpiredBudget() async {
        let store = DailyRecommendationAvatarStore()
        var calls = 0
        for items in [[], [item("owner")]] {
            await store.prepareBatch(items: items, accountID: 1, revision: 1, timeout: .zero) { _ in
                calls += 1
                return "unexpected"
            }
        }
        #expect(calls == 0)
    }

    @Test("用户取消立即结束等待，迟到结果不能影响后续批次")
    func cancellationDiscardsLateResults() async {
        let store = DailyRecommendationAvatarStore()
        let candidate = item("owner")
        var waiting: CheckedContinuation<String?, Never>?
        var finished = false
        let preparation = Task {
            await store.prepareBatch(items: [candidate], accountID: 1, revision: 1) { _ in
                defer { finished = true }
                return await withCheckedContinuation { waiting = $0 }
            }
        }
        while waiting == nil { await Task.yield() }
        preparation.cancel()
        await preparation.value
        #expect(!finished)
        await store.prepareBatch(items: [candidate], accountID: 1, revision: 1) { _ in "new" }
        waiting?.resume(returning: "late")
        while !finished { await Task.yield() }
        #expect(store.dataURI(for: candidate, accountID: 1, revision: 1) == "new")
    }

    @Test("账号或数据库作用域变化释放旧等待，旧图与迟到结果均被隔离", arguments: [true, false])
    func scopeChangeDiscardsOldImages(switchAccount: Bool) async {
        let store = DailyRecommendationAvatarStore()
        let candidate = item("owner")
        await store.prepareBatch(items: [item("cached")], accountID: 1, revision: 1) { _ in "old" }
        var waiting: CheckedContinuation<String?, Never>?
        var finished = false
        let preparation = Task {
            await store.prepareBatch(items: [candidate], accountID: 1, revision: 1) { _ in
                defer { finished = true }
                return await withCheckedContinuation { waiting = $0 }
            }
        }
        while waiting == nil { await Task.yield() }
        let nextAccount: Int64 = switchAccount ? 2 : 1
        store.activate(accountID: nextAccount, revision: 2)
        await preparation.value
        #expect(!finished)
        #expect(store.dataURI(for: item("cached"), accountID: 1, revision: 1) == nil)
        await store.prepareBatch(items: [candidate], accountID: nextAccount, revision: 2) { _ in "new" }
        waiting?.resume(returning: "late")
        while !finished { await Task.yield() }
        #expect(store.dataURI(for: candidate, accountID: nextAccount, revision: 2) == "new")
        #expect(store.dataURI(for: candidate, accountID: 1, revision: 1) == nil)
    }

    @Test("新请求使旧请求失效；提交新批次前保留旧卡图片，提交后释放")
    func replacementPreservesOldCardUntilCommit() async {
        let store = DailyRecommendationAvatarStore()
        let old = item("old")
        let next = item("next")
        await store.prepareBatch(items: [old], accountID: 1, revision: 1) { _ in "old-image" }
        var waiting: CheckedContinuation<String?, Never>?
        var finished = false
        let superseded = Task {
            await store.prepareBatch(items: [next], accountID: 1, revision: 1) { _ in
                defer { finished = true }
                return await withCheckedContinuation { waiting = $0 }
            }
        }
        while waiting == nil { await Task.yield() }
        await store.prepareBatch(items: [next], accountID: 1, revision: 1) { _ in "new-image" }
        await superseded.value
        #expect(store.dataURI(for: old, accountID: 1, revision: 1) == "old-image")
        #expect(store.dataURI(for: next, accountID: 1, revision: 1) == "new-image")
        store.retain(items: [next], accountID: 1, revision: 1)
        #expect(store.dataURI(for: old, accountID: 1, revision: 1) == nil)
        waiting?.resume(returning: "late")
        while !finished { await Task.yield() }
        #expect(store.dataURI(for: next, accountID: 1, revision: 1) == "new-image")
    }

    @Test("已有共享磁盘缓存直接用于快照，不需要联网")
    func usesSharedDiskCache() async throws {
        let url = try #require(URL(string: "https://github.com/avatar-test-\(UUID()).png?size=512"))
        let data = try fixturePNG()
        try ImageCache.default.diskStorage.store(value: data, forKey: url.absoluteString)
        defer { try? ImageCache.default.diskStorage.remove(forKey: url.absoluteString) }
        let uri = await DailyRecommendationAvatarStore.loadAvatar(from: url)
        #expect(uri?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test("损坏、空或过大的图片不算就绪，正常图片缩到最多 512 像素")
    func validatesAndBoundsImages() throws {
        for invalid in [Data(), Data("<html>Unavailable</html>".utf8),
                        Data(repeating: 0, count: AvatarCacheLoader.maxBytes + 1)] {
            #expect(DailyRecommendationAvatarStore.imageDataURI(invalid) == nil)
        }
        let uri = try #require(DailyRecommendationAvatarStore.imageDataURI(fixturePNG(width: 1024, height: 768)))
        let encoded = try #require(uri.split(separator: ",").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 512)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 384)
    }

    private func item(_ owner: String, repo: String = "project") -> RepoRecommendationItem {
        RepoRecommendationItem(repoID: 1, fullName: "\(owner)/\(repo)", description: nil, language: nil,
                               stars: 1, forks: 0, archived: false, score: 1, source: "test", reasons: [])
    }

    /// 创建有效 PNG，避免测试依赖远端图片或不透明的 base64 常量。
    private func fixturePNG(width: Int = 2, height: Int = 2) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
