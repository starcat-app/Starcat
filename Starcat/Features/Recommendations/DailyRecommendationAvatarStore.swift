//
//  DailyRecommendationAvatarStore.swift
//  Starcat
//
//  在推荐窗口出现前准备整批 owner 头像，网页直接使用图片数据。
//  网络与共享头像缓存复用既有加载器，当前批次之外不另建永久缓存。
//

import Foundation
import ImageIO
import Kingfisher
import Observation

/// 成功图片直接复用，失败冷却五分钟；避免重开重复等待，也避免失败占位永久固化。
@MainActor
@Observable
final class DailyRecommendationAvatarStore {
    private var images: [String: String] = [:]
    private var retryAfter: [String: ContinuousClock.Instant] = [:]
    private var accountID: Int64?
    private var revision: UInt64?
    private var requestID = UUID()
    private var cancelPreparation: (@Sendable () -> Void)?

    /// 切账号或数据库作用域时立即释放等待，旧请求即使迟到也无法提交图片。
    func activate(accountID: Int64?, revision: UInt64) {
        guard self.accountID != accountID || self.revision != revision else { return }
        cancelPreparation?()
        cancelPreparation = nil
        requestID = UUID()
        images = [:]
        retryAfter = [:]
        self.accountID = accountID
        self.revision = revision
    }

    /// 读取时也核对作用域，避免 SwiftUI 更新顺序使旧账号图片进入新快照。
    func dataURI(for item: RepoRecommendationItem, accountID: Int64?, revision: UInt64) -> String? {
        guard self.accountID == accountID, self.revision == revision,
              let url = Self.imageURL(for: item) else { return nil }
        return images[url.absoluteString]
    }

    /// 只请求 owner 头像；GitHub owner 不区分大小写，同一 owner 的多个仓库共享下载。
    nonisolated static func imageURL(for item: RepoRecommendationItem) -> URL? {
        let path = item.fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 2, !path[0].isEmpty, !path[1].isEmpty else { return nil }
        return GitHubAvatarURL.imageURL(
            from: RepoAvatarURL.from(owner: String(path[0]).lowercased()),
            displayDiameter: 256, maximumPixelSize: 512
        )
    }

    /// 新批次准备期间保留旧卡图片；宿主提交或取消批次后才释放不再展示的图片。
    func retain(items: [RepoRecommendationItem], accountID: Int64, revision: UInt64) {
        guard self.accountID == accountID, self.revision == revision else { return }
        let keys = Set(items.compactMap { Self.imageURL(for: $0)?.absoluteString })
        images = images.filter { keys.contains($0.key) }
        retryAfter = retryAfter.filter { keys.contains($0.key) }
    }

    /// 最多四路并发共用一个 30 秒预算，缓存读取也包含在预算内。
    /// Stream 负责结束调用方等待；不能直接等待下载 TaskGroup 退出，否则忽略取消的下载
    /// 会使“超时”仍卡住弹窗。独立 worker 取消后禁止启动排队项或发布迟到结果。
    func prepareBatch(
        items: [RepoRecommendationItem], accountID: Int64, revision: UInt64,
        timeout: Duration = .seconds(30), retryFailed: Bool = false,
        now: ContinuousClock.Instant = .now,
        load: @escaping @MainActor @Sendable (URL) async -> String? = {
            await DailyRecommendationAvatarStore.loadAvatar(from: $0)
        }
    ) async {
        guard !Task.isCancelled else { return }
        activate(accountID: accountID, revision: revision)
        cancelPreparation?()
        cancelPreparation = nil
        requestID = UUID()
        let token = requestID
        var seen = Set<String>()
        let urls = items.compactMap(Self.imageURL).filter { seen.insert($0.absoluteString).inserted }
        let pending = urls.filter {
            images[$0.absoluteString] == nil
                && (retryFailed || retryAfter[$0.absoluteString].map { now >= $0 } != false)
        }
        guard !pending.isEmpty else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let (stream, continuation) = AsyncStream<(String, String?)>.makeStream()
        let worker = Task { @MainActor in
            defer { continuation.finish() }
            await withTaskGroup(of: (String, String?).self) { group in
                var remaining = pending.makeIterator()
                func enqueue(_ url: URL) {
                    group.addTask {
                        guard !Task.isCancelled, ContinuousClock.now < deadline else {
                            return (url.absoluteString, nil)
                        }
                        let dataURI = await load(url)
                        return (url.absoluteString, dataURI)
                    }
                }
                for _ in 0..<min(4, pending.count) {
                    if let url = remaining.next() { enqueue(url) }
                }
                while let result = await group.next() {
                    guard !Task.isCancelled, ContinuousClock.now < deadline else {
                        group.cancelAll()
                        return
                    }
                    continuation.yield(result)
                    if let url = remaining.next() { enqueue(url) }
                }
            }
        }
        let timer = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            worker.cancel()
            timer.cancel()
        }
        cancelPreparation = { continuation.finish() }
        var loaded: [String: String] = [:]
        await withTaskCancellationHandler {
            for await (key, dataURI) in stream {
                guard token == requestID, !Task.isCancelled else { break }
                if let dataURI { loaded[key] = dataURI }
            }
        } onCancel: {
            continuation.finish()
        }
        guard token == requestID else { return }
        cancelPreparation = nil
        guard !Task.isCancelled else { return }
        images.merge(loaded) { _, new in new }
        for url in pending {
            retryAfter[url.absoluteString] = loaded[url.absoluteString] == nil ? now.advanced(by: .seconds(300)) : nil
        }
    }

    /// 使用全站 Kingfisher 缓存；损坏缓存不能阻止重新下载，也不能被误报为图片就绪。
    nonisolated static func loadAvatar(from url: URL) async -> String? {
        guard !Task.isCancelled else { return nil }
        if let data = AvatarCacheLoader.cachedImageData(for: url), let uri = imageDataURI(data) {
            return Task.isCancelled ? nil : uri
        }
        guard !Task.isCancelled,
              let downloaded = await AvatarCacheLoader.downloadFromNetwork(url: url),
              !Task.isCancelled, let uri = imageDataURI(downloaded.data),
              !Task.isCancelled else { return nil }
        try? ImageCache.default.diskStorage.store(value: downloaded.data, forKey: url.absoluteString)
        return Task.isCancelled ? nil : uri
    }

    /// ImageIO 实际解码并限制到 512 像素，再统一为 PNG；避免坏数据、超大位图或浏览器
    /// 不支持的编码进入快照。由 loadAvatar 在后台调用，不占用主线程编码。
    nonisolated static func imageDataURI(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= AvatarCacheLoader.maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), encoded.length <= AvatarCacheLoader.maxBytes else { return nil }
        return "data:image/png;base64,\((encoded as Data).base64EncodedString())"
    }
}
