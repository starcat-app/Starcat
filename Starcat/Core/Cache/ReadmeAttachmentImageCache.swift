//
//  ReadmeAttachmentImageCache.swift
//  Starcat
//
//  README 图片的原始数据缓存。GitHub 附件使用稳定 UUID，其它内容图使用完整 URL。
//  使用现有 Kingfisher 磁盘底座管理期限与容量，不经 NSImage 编解码，保留 GIF 动画。
//

import Foundation
import ImageIO
import Kingfisher

/// 正文路由和浏览器共用一份徽标规则，避免新增来源后只有其中一条路径生效。
enum ReadmeImageBadgeRules {
    struct Rule: Encodable {
        let hosts: [String]
        let path: String
        let query: String

        init(hosts: [String], path: String = "", query: String = "") {
            self.hosts = hosts
            self.path = path
            self.query = query
        }
    }

    /// 专用徽标域名可以直接识别；综合服务只匹配其徽标端点，保留截图、头像和统计图。
    static let sources: [Rule] = [
        Rule(hosts: [
            "shields.io", "badgen.net", "badge.fury.io", "badge.buildkite.com",
            "img.badgesize.io", "badge.waffle.io", "visitor-badge.laobi.icu",
            "visitor-badge.glitch.me", "hits.seeyoufarm.com", "profile-counter.glitch.me",
            "custom-icon-badges.demolab.com", "badges.gitter.im", "badges.frapsoft.com",
            "poser.pugx.org", "pypip.in", "hits.dwyl.com"
        ], path: ""),
        Rule(hosts: [], path: #"(^|/)badges?(/|\.(svg|png|gif|webp)$|$)|(^|/)status\.(svg|png|gif|webp)$|^/api/project_badges/"#),
        Rule(hosts: ["skills.sh"], path: #"^/b/"#),
        Rule(hosts: ["producthunt.com"], path: #"^/widgets/(embed-image|follow-button)(/|$)|^/api/embed/"#),
        Rule(hosts: ["api.hellogithub.com"], path: #"^/v1/widgets/"#),
        Rule(hosts: ["colab.research.google.com"], path: #"^/assets/colab-badge\.svg$"#),
        Rule(hosts: ["gitpod.io"], path: #"^/button/open-in-gitpod\.svg$"#),
        Rule(hosts: ["mybinder.org"], path: #"^/badge_logo\.svg$"#),
        Rule(hosts: ["fossa.com"], path: #"^/api/projects/.*\.svg$"#),
        Rule(hosts: ["travis-ci.org", "travis-ci.com"], path: #"\.(svg|png)$"#),
        Rule(hosts: ["circleci.com"], path: #"^/(gh|bb)/.*\.svg$"#),
        Rule(hosts: ["api.cirrus-ci.com"], path: #"^/github/.*\.svg$"#),
        Rule(hosts: ["ci.appveyor.com"], path: #"^/api/projects/status/"#),
        Rule(hosts: ["api.netlify.com"], path: #"^/api/v1/badges/"#),
        Rule(hosts: ["coveralls.io"], path: #"^/repos/.*\.svg$"#),
        Rule(hosts: ["goreportcard.com"], path: #"^/badge(/|$)"#),
        Rule(hosts: ["static.pepy.tech"], path: #"^/(badge|personalized-badge)(/|$)"#),
        Rule(hosts: ["pepy.tech"], path: #"^/badge(/|$)"#),
        Rule(hosts: ["repostatus.org"], path: #"^/badges/"#),
        Rule(hosts: ["david-dm.org"], path: #"\.svg$"#),
        Rule(hosts: ["bettercodehub.com"], path: #"^/edge/badge/"#),
        Rule(hosts: ["codefactor.io"], path: #"/badge(/|$)"#),
        Rule(hosts: ["packagephobia.com"], path: #"^/badge(/|$)"#),
        Rule(hosts: ["hitscounter.dev"], path: #"^/api/hit/?$"#),
        Rule(hosts: ["komarev.com"], path: #"^/ghpvc/?$"#),
        Rule(hosts: ["nodei.co"], path: #"^/npm/"#),
        Rule(hosts: ["godoc.org", "pkg.go.dev"], query: #"(^|&)status\.svg(?:[=&]|$)"#),
        Rule(hosts: ["opencollective.com"], path: #"^/[^/]+/(backers|sponsors)\.svg$"#)
    ]

    /// GitHub Camo 会隐藏源站；明确的推广外链可识别自托管徽标，不把整个站点当黑名单。
    static let links: [Rule] = [
        Rule(hosts: ["skills.sh"], path: #"^/[^/]+/[^/]+/?$"#),
        Rule(hosts: ["hellogithub.com"], path: #"^/(?:en/)?repository/"#),
        Rule(hosts: ["producthunt.com"], query: #"(^|&)utm_(source|medium)=badge[^&]*(?:&|$)"#)
    ]

    static var json: String {
        let data = try? JSONEncoder().encode(["sources": sources, "links": links])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// 动态徽标保持 WebKit 自身的 HTTP 缓存语义，不进入内容图片的长期磁盘缓存。
    static func isBadge(_ source: String) -> Bool {
        guard let url = URL(string: source), let host = url.host?.lowercased() else { return false }
        return sources.contains { rule in
            (rule.hosts.isEmpty || rule.hosts.contains { host == $0 || host.hasSuffix(".\($0)") })
                && (rule.path.isEmpty || url.path.lowercased().range(of: rule.path, options: .regularExpression) != nil)
                && (rule.query.isEmpty || (url.query ?? "").lowercased().range(of: rule.query, options: .regularExpression) != nil)
        }
    }
}

/// 仅对 img / picture 调用的展示映射；正文与独立浏览器使用同一个原始字节缓存。
enum ReadmeAttachmentImageURL {
    static let scheme = "starcat-readme-image"

    /// 在 HTML 解析前完成路由，防止先下载 HTTPS 图片，再因 JS 换源重复下载。
    static func cachedSource(_ source: String) -> String {
        let normalized = ReadmeAssetURLRewriter.stableGitHubAttachmentURL(from: source) ?? source
        guard let url = URL(string: normalized), isRemoteImageURL(url),
              !ReadmeImageBadgeRules.isBadge(normalized) else { return source }
        if url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com", url.port == nil,
           let uuid = UUID(uuidString: url.lastPathComponent),
           url.path == "/user-attachments/assets/\(url.lastPathComponent)" {
            return "\(scheme)://attachment/\(uuid.uuidString.lowercased())"
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "remote"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return components.url?.absoluteString ?? source
    }

    /// 不接受文件或其它内部协议，也不转发 URL 凭据、OAuth 和浏览器 Cookie。
    static func remoteURL(for url: URL) -> URL? {
        guard url.scheme == scheme, url.user == nil,
              url.port == nil, url.fragment == nil else { return nil }
        if url.host == "remote", url.path == "/",
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           items.count == 1, items[0].name == "url", let value = items[0].value,
           let remote = URL(string: value), isRemoteImageURL(remote) {
            return remote
        }
        guard url.host == "attachment", url.query == nil,
              let uuid = UUID(uuidString: url.lastPathComponent),
              url.path == "/\(url.lastPathComponent)" else { return nil }
        return URL(string: "https://github.com/user-attachments/assets/\(uuid.uuidString.lowercased())")
    }

    private static func isRemoteImageURL(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host ?? "").isEmpty && url.user == nil
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

    /// 附件沿用已发布的 UUID 键；普通图片包含完整 URL，避免不同主机、路径或 query 串图。
    func image(for source: URL, accountID: Int64?) async throws -> ReadmeAttachmentImage {
        guard let remote = ReadmeAttachmentImageURL.remoteURL(for: source) else { throw URLError(.unsupportedURL) }
        let identity = source.host == "attachment" ? remote.lastPathComponent : remote.absoluteString
        let key = "\(accountID.map(String.init) ?? "_anonymous")/\(identity)"
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
