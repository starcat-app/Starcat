//
//  FollowGraphAvatarCache.swift
//  Starcat
//
//  图谱通过受控 scheme 复用 Kingfisher 原始图片，不把头像塞进每批图数据。
//  缓存与 WebView 生命周期分离；磁盘读取、图片校验均在后台 actor 内执行。
//

import Foundation
import ImageIO
import Kingfisher

/// 只允许公开 GitHub 头像；本地探测和允许下载共用同一规范化缓存键。
enum FollowGraphAvatarURL {
    static let scheme = "starcat-follow-avatar"

    static func source(_ raw: String?) -> String {
        guard let raw, let url = URL(string: raw), isAllowed(url),
              let normalized = GitHubAvatarURL.imageURL(from: raw, displayDiameter: 32) else { return "" }
        var local = URLComponents()
        local.scheme = scheme
        local.host = "cache"
        local.path = "/image"
        local.queryItems = [URLQueryItem(name: "url", value: normalized.absoluteString)]
        return local.url?.absoluteString ?? ""
    }

    /// 不接受任意代理地址、凭据或重复参数；load 仅是缓存未命中后的第二阶段。
    static func request(_ local: URL) -> (remote: URL, cacheOnly: Bool)? {
        guard local.scheme == scheme, ["cache", "load"].contains(local.host),
              local.path == "/image", local.user == nil, local.password == nil,
              local.port == nil, local.fragment == nil,
              let items = URLComponents(url: local, resolvingAgainstBaseURL: false)?.queryItems,
              (1...2).contains(items.count), items[0].name == "url",
              let raw = items[0].value, let remote = URL(string: raw), isAllowed(remote),
              let normalized = GitHubAvatarURL.imageURL(from: raw, displayDiameter: 32) else { return nil }
        // 重试换图片请求身份，避免 WebKit 复用本页已失败的响应；不参与原生缓存键。
        if items.count == 2 {
            guard items[1].name == "attempt", let value = items[1].value,
                  let attempt = UInt64(value), attempt > 0 else { return nil }
        }
        return (normalized, local.host == "cache")
    }

    private static func isAllowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "avatars.githubusercontent.com" &&
            url.user == nil && url.password == nil && url.port == nil && url.fragment == nil
    }
}

/// 仅传递原始图片字节，避免 NSImage 跨 actor，也避免大批 base64 带来的内存复制。
struct FollowGraphAvatarImage: Sendable {
    let data: Data
    let mime: String
}

/// 与 RemoteAvatar 共用 ImageCache.default 和完整 URL key；缓存期限及清理沿用应用设置。
actor FollowGraphAvatarCache {
    static let shared = FollowGraphAvatarCache()
    typealias Loader = @Sendable (URL) async -> Data?
    private let cacheName: String?
    private let directory: URL?
    private let loader: Loader
    private var cache: ImageCache?

    /// 独立名称、目录和下载器只用于离线测试，生产默认复用应用缓存。
    init(cacheName: String? = nil, directory: URL? = nil, loader: Loader? = nil) {
        self.cacheName = cacheName
        self.directory = directory
        self.loader = loader ?? { await AvatarCacheLoader.downloadFromNetwork(url: $0)?.data }
    }

    /// cache 请求严格零网络；load 请求再次检查缓存，避免预取期间已写入却重复下载。
    func image(for local: URL) async throws -> FollowGraphAvatarImage {
        guard let request = FollowGraphAvatarURL.request(local) else { throw URLError(.unsupportedURL) }
        try Task.checkCancellation()
        let cache = try storage(), key = request.remote.absoluteString
        if let image = cachedImage(for: request.remote, cache: cache) { return image }
        guard !request.cacheOnly else { throw URLError(.resourceUnavailable) }
        guard let data = await loader(request.remote) else { throw URLError(.cannotLoadFromNetwork) }
        try Task.checkCancellation()
        guard let image = Self.validated(data) else { throw URLError(.cannotDecodeContentData) }
        // 缓存故障不应使本次成功的下载变成裂图；不缓存错误页或截断图片。
        try? cache.diskStorage.store(value: data, forKey: key, writeOptions: .atomic)
        return image
    }

    /// 卡片成功回调发生时内存缓存已可读，不依赖 Kingfisher 异步写盘是否完成。
    /// 保留真实 URL 的其它参数，只把尺寸归一到节点 key；不合并不同用户或头像版本。
    func promoteCardImage(from url: URL) throws -> Bool {
        guard !FollowGraphAvatarURL.source(url.absoluteString).isEmpty else { return false }
        let cache = try storage()
        guard let image = read(key: url.absoluteString, cache: cache),
              let nodeURL = GitHubAvatarURL.imageURL(from: url.absoluteString, displayDiameter: 32) else { return false }
        try? cache.diskStorage.store(value: image.data, forKey: nodeURL.absoluteString, writeOptions: .atomic)
        return true
    }

    /// 同一头像的常用较大尺寸可缩绘到 64px；先查内存，避免刚加载的卡片还没写盘。
    private func cachedImage(for url: URL, cache: ImageCache) -> FollowGraphAvatarImage? {
        let candidates = [32, 112, 56, 64, 128].compactMap {
            GitHubAvatarURL.imageURL(from: url.absoluteString, displayDiameter: CGFloat($0))?.absoluteString
        }
        for key in candidates {
            if let image = read(key: key, cache: cache) {
                if key != url.absoluteString {
                    try? cache.diskStorage.store(value: image.data, forKey: url.absoluteString, writeOptions: .atomic)
                }
                return image
            }
        }
        return nil
    }

    private func read(key: String, cache: ImageCache) -> FollowGraphAvatarImage? {
        if let image = cache.retrieveImageInMemoryCache(forKey: key),
           let data = image.kf.pngRepresentation(), let value = Self.validated(data) { return value }
        if let data = try? cache.diskStorage.value(forKey: key) { return Self.validated(data) }
        return nil
    }

    private func storage() throws -> ImageCache {
        if let cache { return cache }
        let created: ImageCache
        if let cacheName {
            created = try ImageCache(name: cacheName, cacheDirectoryURL: directory)
        } else {
            created = .default
        }
        cache = created
        return created
    }

    /// CDN 头像为栅格图片；检查完整性后才写入共用缓存，不能仅相信 Content-Type。
    private static func validated(_ data: Data) -> FollowGraphAvatarImage? {
        guard !data.isEmpty, data.count <= 5 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        return FollowGraphAvatarImage(data: data, mime: AvatarCacheLoader.sniffMimeType(data: data))
    }
}
