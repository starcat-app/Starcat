//
//  SnapshotAvatarImage.swift
//  Starcat
//
//  屏外截图用的仓库 logo。不走 KFImage：那条路径只认「当前直径改写后的 URL」当
//  cache key，导出 28pt 会变成 `size=56`，对不上详情页 hero（64pt → `size=128`）
//  或列表（40pt → `size=80`），`loadDiskFileSynchronously` 也救不了，剪贴板只会
//  留下 shippingbox 占位。
//
//  这里只同步读 Kingfisher 已经有的内存 / 磁盘缓存，按 App 里真实出现过的直径
//  穷举 key。禁止网络、禁止转 runloop（会重入侧栏 TimelineView）。
//

import AppKit
import Kingfisher

/// 从 Kingfisher 缓存里拿出仓库 owner logo，给剪贴板截图用。
enum SnapshotAvatarImage {
    /// 详情 hero 64、搜索 44、列表 40、紧凑行 / 导出 28、身份芯片 16。
    /// `RemoteAvatar` 会按直径改 GitHub 的 `size` / `s`，这些都要当成候选 key。
    static let cachedDisplayDiameters: [CGFloat] = [16, 20, 24, 28, 32, 36, 40, 44, 64]

    /// 按命中概率排序的 cache key。先当前导出直径，再 hero / 列表常用尺寸。
    static func cacheKeys(
        owner: String,
        ownerAvatar: String?,
        displayDiameter: CGFloat
    ) -> [String] {
        var seen = Set<String>()
        var keys: [String] = []

        func append(_ raw: String?, diameter: CGFloat?) {
            guard let raw, !raw.isEmpty else { return }
            let key: String
            if let diameter, let url = GitHubAvatarURL.imageURL(from: raw, displayDiameter: diameter) {
                key = url.absoluteString
            } else {
                key = raw
            }
            if seen.insert(key).inserted {
                keys.append(key)
            }
        }

        var diameters = [displayDiameter]
        diameters.append(contentsOf: cachedDisplayDiameters.filter { $0 != displayDiameter })

        for diameter in diameters {
            append(ownerAvatar, diameter: diameter)
            append(RepoAvatarURL.from(owner: owner), diameter: diameter)
        }

        // 库里存的可能是未改写的原始 URL（HTML 导出 / AvatarCacheLoader）。
        append(ownerAvatar, diameter: nil)
        append(RepoAvatarURL.from(owner: owner), diameter: nil)
        return keys
    }

    /// 命中返回位图；缓存里没有就 `nil`，调用方画占位，不要在主线程下载。
    @MainActor
    static func cachedNSImage(
        owner: String,
        ownerAvatar: String?,
        displayDiameter: CGFloat = 28,
        cache: ImageCache = .default
    ) -> NSImage? {
        for key in cacheKeys(owner: owner, ownerAvatar: ownerAvatar, displayDiameter: displayDiameter) {
            if let image = cache.retrieveImageInMemoryCache(forKey: key) {
                return image
            }
            if let data = try? cache.diskStorage.value(forKey: key),
               let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }
}
