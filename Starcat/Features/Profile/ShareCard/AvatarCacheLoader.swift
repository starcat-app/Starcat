//
//  AvatarCacheLoader.swift
//  Starcat
//
//  HOM-174 v3（dong4j 2026-06-06）：HTML 导出场景下的统一头像加载器。
//
//  设计动机：
//  - v2 写的 `StarredExporter.downloadAvatarBase64` 直接 `URLSession.ephemeral` 重新下载用户头像，
//    完全没复用 Kingfisher 在 App 内已经下载好的磁盘 cache。
//  - 同样的 base URL 问题对 repo logo（owner 头像）更严重——1000 个 repo 通常涉及 200-300
//    个 owner，如果全走 URLSession 会触发 GitHub rate limit、且离线场景完全拿不到。
//  - 解决：先查 Kingfisher disk cache（命中即转 base64 data URI，0 网络），未命中再走 URLSession
//    兜底下载，下载完顺手写回 Kingfisher cache 让"下次再导出/App 内浏览"都能命中。
//
//  cache key 约定：
//  - Kingfisher 7 对 URL source 的默认 cache key = `url.absoluteString`，与 `KFImage(url)` 一致。
//  - 这意味着 sidebar / 列表行用 `RemoteAvatar(urlString:)` 渲染的头像，本 loader 用同一 URL
//    查 cache 必然命中（前提是 App 内浏览过）。
//
//  MIME 嗅探：
//  - 不依赖 HTTP `Content-Type`（cache 文件没有 header），用图像 magic number 嗅探。
//  - 已知场景：GitHub 头像通常是 PNG / JPG，少量 WebP（高 DPI 屏）/ GIF（动图头像）。
//  - 未匹配的字节序退化为 `image/png`——浏览器对 data URI 的 MIME 容错较好，错标也能渲染。
//
//  并发与失败兜底：
//  - 公开 API 全是 `async` nonisolated，调用方可以放心从任意 actor 内发起；
//  - 任何异常（cache 读失败 / URLSession 超时 / 非图片 MIME / 体积超限）一律返回 nil，
//    让 HTML 端 fallback（用户头像 → initials；repo logo → 不渲染头像位）。
//

import Foundation
import Kingfisher

/// HTML 导出场景的头像加载器。无状态，一组 enum 静态方法。
///
/// 与 `RemoteAvatar`（SwiftUI 实时显示）解耦：
/// - `RemoteAvatar` 是给 UI 渲染用的（直接给 SwiftUI 一个 View）；
/// - `AvatarCacheLoader` 是给 HTML 导出用的（异步返回 base64 字符串），但**两者共享同一个磁盘 cache**。
enum AvatarCacheLoader {

    /// 单次下载的硬上限：5 MB。GitHub 头像通常 < 100KB，超大基本是异常返回（404 HTML / 重定向页等）。
    static let maxBytes: Int = 5 * 1024 * 1024

    /// URLSession 超时：5s 请求 + 10s 资源。短超时避免离线场景拖累整个导出流程。
    static let requestTimeout: TimeInterval = 5
    static let resourceTimeout: TimeInterval = 10

    // MARK: - 公开 API

    /// 给一个图片 URL 字符串，返回 base64 data URI；任何失败返回 nil。
    ///
    /// 流程：
    /// 1. 校验 URL 合法（http/https）
    /// 2. 查 Kingfisher 磁盘 cache（key = url.absoluteString）
    ///    - 命中：sniff MIME + base64 编码，**零网络**
    /// 3. 未命中：URLSession 下载（5s 超时 / 5MB 上限 / MIME 必须 image/*）
    ///    - 成功：写回 Kingfisher cache + base64 编码
    ///    - 失败：返回 nil
    static func loadAsDataURI(urlString: String?) async -> String? {
        guard let urlString,
              let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        // ① 查磁盘 cache
        if let cachedData = readFromDiskCache(url: url) {
            let mime = sniffMimeType(data: cachedData)
            return "data:\(mime);base64,\(cachedData.base64EncodedString())"
        }

        // ② URLSession 兜底
        guard let downloaded = await downloadFromNetwork(url: url) else { return nil }
        // 写回 cache 让"下次导出 / App 内浏览"秒命中（失败静默忽略，不影响本次结果）
        writeToDiskCache(url: url, data: downloaded.data)
        return "data:\(downloaded.mime);base64,\(downloaded.data.base64EncodedString())"
    }

    /// 并发拉一组 owner 的 GitHub 头像（去重 + 并发上限）。
    ///
    /// - Parameters:
    ///   - owners: GitHub owner 名集合（如 `["vapor", "apple"]`），自动去重
    ///   - maxConcurrency: 并发上限，默认 8。避免短时间内对 GitHub 发起太多请求触发 rate limit。
    /// - Returns: `[owner: dataURI]` 字典；失败的 owner 不进字典。
    ///
    /// owner 头像走 GitHub 的公开 redirect 端点 `https://github.com/{owner}.png?size=80`
    /// （与 App 内 `RepoAvatarURL.from(owner:)` 完全一致，保证 cache key 命中）。
    static func loadOwnerAvatars(
        owners: Set<String>,
        maxConcurrency: Int = 8
    ) async -> [String: String] {
        guard !owners.isEmpty else { return [:] }

        // 大写不敏感去重 + 排序保证结果稳定（便于单测断言）
        let unique = Array(Set(owners.map { $0 })).sorted()

        var result: [String: String] = [:]
        result.reserveCapacity(unique.count)

        await withTaskGroup(of: (String, String?).self) { group in
            var inflight = 0
            var index = 0

            // 启动初始批
            while index < unique.count && inflight < maxConcurrency {
                let owner = unique[index]
                group.addTask {
                    let url = "https://github.com/\(owner).png?size=80"
                    let dataURI = await AvatarCacheLoader.loadAsDataURI(urlString: url)
                    return (owner, dataURI)
                }
                inflight += 1
                index += 1
            }

            // 滑动窗口：每完成一个补一个，维持 maxConcurrency 并发
            while let (owner, dataURI) = await group.next() {
                if let dataURI {
                    result[owner] = dataURI
                }
                inflight -= 1
                if index < unique.count {
                    let next = unique[index]
                    group.addTask {
                        let url = "https://github.com/\(next).png?size=80"
                        let dataURI = await AvatarCacheLoader.loadAsDataURI(urlString: url)
                        return (next, dataURI)
                    }
                    inflight += 1
                    index += 1
                }
            }
        }

        AppLog.ui.info("AvatarCacheLoader: loaded \(result.count, privacy: .public)/\(unique.count, privacy: .public) owner avatars")
        return result
    }

    // MARK: - Kingfisher 磁盘 cache

    /// 直接读 Kingfisher 磁盘 cache 的原始 Data；命中返回 Data，未命中或异常返回 nil。
    ///
    /// 用 `diskStorage.value(forKey:)` 而非高阶的 `retrieveImage`：
    /// - 后者会把 Data 解码成 NSImage 再让我们重编码为 PNG，损耗大（JPG 重编码体积 +30%、可能损失色彩）
    /// - 前者直接拿原始下载字节，配合 MIME 嗅探，保真且零开销
    private static func readFromDiskCache(url: URL) -> Data? {
        let key = url.absoluteString  // 与 KFImage(url) cache key 一致
        do {
            return try ImageCache.default.diskStorage.value(forKey: key)
        } catch {
            AppLog.ui.debug("AvatarCacheLoader: disk cache read failed key=\(key, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 把 URLSession 下载的 Data 写回 Kingfisher 磁盘 cache，让下次 App 内浏览或再次导出命中。
    /// 失败静默吞掉（cache 写入失败不影响主流程）。
    private static func writeToDiskCache(url: URL, data: Data) {
        let key = url.absoluteString
        do {
            try ImageCache.default.diskStorage.store(value: data, forKey: key)
        } catch {
            AppLog.ui.debug("AvatarCacheLoader: disk cache write failed key=\(key, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - URLSession 兜底

    /// URLSession 下载 + 校验（5s 超时 / 5MB 上限 / 必须 image/* MIME）。
    /// 返回 `(data, mime)` 或 nil。
    private static func downloadFromNetwork(url: URL) async -> (data: Data, mime: String)? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                AppLog.ui.debug("AvatarCacheLoader: non-200 response url=\(url.absoluteString, privacy: .public)")
                return nil
            }
            guard data.count > 0, data.count <= maxBytes else {
                AppLog.ui.debug("AvatarCacheLoader: invalid size \(data.count, privacy: .public) url=\(url.absoluteString, privacy: .public)")
                return nil
            }
            // Content-Type 优先；缺失或非 image/* 时退化用 magic number 嗅探
            let headerMime = (http.value(forHTTPHeaderField: "Content-Type") ?? "")
                .components(separatedBy: ";").first?
                .trimmingCharacters(in: .whitespaces)
                .lowercased() ?? ""
            let mime: String
            if headerMime.hasPrefix("image/") {
                mime = headerMime
            } else {
                let sniffed = sniffMimeType(data: data)
                // 嗅探也不是 image/*——拒绝（防止把 404 HTML 编码进 data URI）
                guard sniffed.hasPrefix("image/") else {
                    AppLog.ui.debug("AvatarCacheLoader: non-image content url=\(url.absoluteString, privacy: .public) header=\(headerMime, privacy: .public)")
                    return nil
                }
                mime = sniffed
            }
            return (data, mime)
        } catch {
            AppLog.ui.debug("AvatarCacheLoader: download failed url=\(url.absoluteString, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - MIME 嗅探（magic number）

    /// 根据图片数据字节头嗅探 MIME；未匹配的图像类型默认 `image/png`（浏览器 data URI 容错好）。
    ///
    /// 支持的格式（覆盖 GitHub 头像 / OpenGraph 99% 情况）：
    /// - PNG: `89 50 4E 47 0D 0A 1A 0A`
    /// - JPEG: `FF D8 FF`
    /// - GIF: `47 49 46 38 (37|39) 61` (GIF87a / GIF89a)
    /// - WebP: `52 49 46 46 ?? ?? ?? ?? 57 45 42 50` (RIFF....WEBP)
    /// - BMP: `42 4D`
    /// - SVG: 文本起始包含 `<svg` 或 `<?xml`（罕见，但 GitHub Identicon 极少给）
    static func sniffMimeType(data: Data) -> String {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 4 else { return "image/png" }

        // PNG
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        // JPEG
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        // GIF
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return "image/gif"
        }
        // BMP
        if bytes.starts(with: [0x42, 0x4D]) {
            return "image/bmp"
        }
        // WebP: RIFF....WEBP（前 4 = RIFF, 8..11 = WEBP）
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        // SVG：UTF-8 文本，前 100 字节里出现 "<svg" 或 "<?xml"
        if let probe = String(data: data.prefix(128), encoding: .utf8)?.lowercased(),
           probe.contains("<svg") || probe.contains("<?xml") {
            return "image/svg+xml"
        }
        return "image/png"  // 兜底
    }
}
