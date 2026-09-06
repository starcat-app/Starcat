//
//  ImageCachePerformanceConfiguration.swift
//  Starcat
//
//  Kingfisher 默认缓存的全局容量边界。
//

import Kingfisher

/// 用磁盘容量换取头像/封面复用，同时防止默认“物理内存 1/4”策略推高常驻内存。
enum ImageCachePerformanceConfiguration {
    /// 192 MiB 足以保留大量小头像和当前窗口封面；1 GiB 磁盘缓存减少重复下载与解码。
    /// Kingfisher 的默认磁盘 sizeLimit 为 0（无限），必须显式约束长期增长。
    private static let memoryCostLimit = 192 * 1_024 * 1_024
    private static let memoryCountLimit = 4_000
    private static let diskSizeLimit: UInt = 1_024 * 1_024 * 1_024

    static func configureDefault() {
        let cache = ImageCache.default
        cache.memoryStorage.config.totalCostLimit = memoryCostLimit
        cache.memoryStorage.config.countLimit = memoryCountLimit
        cache.memoryStorage.config.expiration = .seconds(15 * 60)
        cache.diskStorage.config.sizeLimit = diskSizeLimit
        cache.diskStorage.config.expiration = .days(30)
    }
}
