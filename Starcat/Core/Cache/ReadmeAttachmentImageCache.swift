//
//  ReadmeAttachmentImageCache.swift
//  Starcat
//
//  GitHub 附件图片的原始数据缓存。稳定 UUID 是资源身份，临时 JWT 不进入缓存键。
//  使用现有 Kingfisher 磁盘底座管理期限与容量，不经 NSImage 编解码，保留 GIF 动画。
//

import Foundation
import ImageIO
import Kingfisher

/// 受控的附件地址映射；自定义 scheme 只能访问固定 GitHub 附件入口。
enum ReadmeAttachmentImageURL {
    static let scheme = "starcat-readme-image"

    /// 普通图片、徽章、视频和超出附件路径约定的 URL 保持原样。
    static func cachedSource(_ source: String) -> String {
        let normalized = ReadmeAssetURLRewriter.stableGitHubAttachmentURL(from: source) ?? source
        guard let url = URL(string: normalized), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com", url.user == nil, url.port == nil,
              let uuid = UUID(uuidString: url.lastPathComponent),
              url.path == "/user-attachments/assets/\(url.lastPathComponent)" else { return source }
        return "\(scheme)://attachment/\(uuid.uuidString.lowercased())"
    }

    /// 从内部 URL 还原稳定 HTTPS 地址，不接受任意域名或路径，避免变成通用代理。
    static func remoteURL(for url: URL) -> URL? {
        guard url.scheme == scheme, url.host == "attachment", url.user == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              let uuid = UUID(uuidString: url.lastPathComponent),
              url.path == "/\(url.lastPathComponent)" else { return nil }
        return URL(string: "https://github.com/user-attachments/assets/\(uuid.uuidString.lowercased())")
    }
}

/// 缓存原始字节与 MIME。二进制 plist 只做封装，不对图片重新压缩或取 GIF 首帧。
struct ReadmeAttachmentImage: Codable, Sendable, Equatable {
    let data: Data
    let mimeType: String
}

/// 串行维护磁盘状态与共享下载；网络 await 期间允许其它图片和清理操作进入。
///
/// clear 会先取消共享任务并更换 generation。即使下载器迟到返回，也不能把用户刚清掉
/// 的图片写回磁盘。WebKit 单个消费者取消时则不取消共享下载，供其它窗口继续复用。
actor ReadmeAttachmentImageCache {
    static let shared = ReadmeAttachmentImageCache()
    typealias Loader = @Sendable (URL) async throws -> ReadmeAttachmentImage

    private let directory: URL
    private let sizeLimit: UInt
    private let expiration: StorageExpiration
    private let loader: Loader
    // 共用无凭据会话复用连接，避免每张图片都重新建立 TLS 连接；缓存仍完全由本类管理。
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()
    private var disk: DiskStorage.Backend<Data>?
    private var generation = UUID()
    private var inflight: [String: (id: UUID, task: Task<ReadmeAttachmentImage, Error>)] = [:]

    /// 可注入独立目录与下载器，测试不接触用户缓存、不访问外网。
    init(directory: URL? = nil, sizeLimit: UInt = 256 * 1_024 * 1_024,
         expiration: StorageExpiration = .days(30), loader: Loader? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
        self.sizeLimit = sizeLimit
        self.expiration = expiration
        self.loader = loader ?? Self.download
    }

    /// 缓存键同时包含账户和 UUID；匿名状态独立，不跨账户复用已下载的附件。
    func image(for source: URL, accountID: Int64?) async throws -> ReadmeAttachmentImage {
        guard let remote = ReadmeAttachmentImageURL.remoteURL(for: source) else { throw URLError(.unsupportedURL) }
        let key = "\(accountID.map(String.init) ?? "_anonymous")/\(remote.lastPathComponent)"
        if let data = try? storage().value(forKey: key, extendingExpiration: .none),
           let image = try? PropertyListDecoder().decode(ReadmeAttachmentImage.self, from: data) {
            return image
        }
        if let pending = inflight[key] { return try await pending.task.value }
        let id = UUID()
        let currentGeneration = generation
        let task = Task { try await fetchAndStore(remote, key: key, generation: currentGeneration) }
        inflight[key] = (id, task)
        defer {
            if inflight[key]?.id == id { inflight.removeValue(forKey: key) }
        }
        return try await task.value
    }

    /// 清理与下载结算都在同一 actor 内，保证清理完成后迟到任务不能重新填充磁盘。
    func clear() throws {
        generation = UUID()
        for pending in inflight.values { pending.task.cancel() }
        inflight.removeAll()
        try storage().removeAll()
    }

    /// 现有设置页把附件容量并入“图片缓存”，无需新增文案或第二个清理按钮。
    func diskSize() -> UInt {
        guard let storage = try? storage() else { return 0 }
        _ = try? storage.removeExpiredValues()
        return (try? storage.totalSize()) ?? 0
    }

    /// 在后台 actor 上惰性创建存储，不让初始化和图片文件读取阻塞主线程。
    private func storage() throws -> DiskStorage.Backend<Data> {
        if let disk { return disk }
        var config = DiskStorage.Config(name: "readme-attachments", sizeLimit: sizeLimit, directory: directory)
        config.expiration = expiration
        let created = try DiskStorage.Backend<Data>(config: config)
        _ = try? created.removeExpiredValues()
        _ = try? created.removeSizeExceededValues()
        disk = created
        return created
    }

    /// 单个共享任务负责写盘；写盘失败仍返回已下载图片，不能让缓存故障变成裂图。
    private func fetchAndStore(_ url: URL, key: String, generation expected: UUID) async throws -> ReadmeAttachmentImage {
        let image = try await loader(url)
        try Task.checkCancellation()
        guard generation == expected else { throw URLError(.cancelled) }
        guard !image.data.isEmpty, image.mimeType.hasPrefix("image/") else { throw URLError(.cannotDecodeContentData) }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let storage = try? storage(), let data = try? encoder.encode(image), data.count <= sizeLimit {
            try? storage.store(value: data, forKey: key, writeOptions: .atomic)
            _ = try? storage.removeExpiredValues()
            _ = try? storage.removeSizeExceededValues()
        }
        return image
    }

    /// 首次请求只访问稳定入口；不携带 OAuth、浏览器 Cookie，也不依赖签名 URL 的系统缓存。
    private static func download(_ url: URL) async throws -> ReadmeAttachmentImage {
        let (data, response) = try await downloadSession.data(from: url)
        return try validatedImage(data: data, response: response)
    }

    /// HTTP 成功与文件完整性均通过才交付 WebKit 并落盘，错误页不能固化为图片缓存。
    static func validatedImage(data: Data, response: URLResponse) throws -> ReadmeAttachmentImage {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let mime = response.mimeType, mime.hasPrefix("image/"), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        // MIME 不能证明内容完整；栅格图还需 ImageIO 确认文件完整，杜绝把截断 PNG/GIF 固化。
        if mime != "image/svg+xml" {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete else {
                throw URLError(.cannotDecodeContentData)
            }
        }
        return ReadmeAttachmentImage(data: data, mimeType: mime)
    }
}
