//
//  CacheCleaner.swift
//  Starcat
//
//  W4-4 D4：缓存统计与清理工具。
//
//  职责：
//  - 聚合"README 缓存"和"图片缓存"两类用量统计供设置页展示
//  - 提供清理 API（README / 图片 / 全部）
//
//  设计说明：
//  - README 缓存走 GRDB 的 `readmes` 表（ReadmeRepository.deleteAll）
//  - 图片缓存走 Kingfisher 的 `ImageCache.default`（disk + memory）
//  - 系统 OSLog 由 macOS 统一管理，无 app 本地日志文件可清；
//    设置页里"日志条目"项保留但 disabled，提示用户用 Console.app 管理
//
//  执行时机：用户在 Settings → 存储 主动点击；不在后台自动清理。
//

import Foundation
import Kingfisher

/// 缓存使用快照。
struct CacheStatistics: Equatable, Sendable {
    /// README 缓存条目数。
    let readmeCount: Int
    /// README 缓存字节总数（基于 readmes.size 列累计）。
    let readmeBytes: Int64
    /// Kingfisher 磁盘缓存字节数。
    let imageDiskBytes: UInt
    /// 派生：总字节数（README + 图片磁盘）。
    var totalBytes: Int64 { readmeBytes + Int64(imageDiskBytes) }

    static let empty = CacheStatistics(readmeCount: 0, readmeBytes: 0, imageDiskBytes: 0)
}

/// 缓存清理协调器。
///
/// 单例性：不必单例 — 由 SettingsView 局部构造即可，依赖通过 init 注入。
/// MainActor：因为读 ReadmeRepository（async DB 读）+ 写到 SwiftUI 状态，
/// 用 MainActor 减少跨域跳转。
@MainActor
final class CacheCleaner {

    private let readmeRepository: ReadmeRepository

    init(readmeRepository: ReadmeRepository) {
        self.readmeRepository = readmeRepository
    }

    // MARK: - 统计

    /// 计算当前缓存用量快照。
    ///
    /// 失败降级策略：任一子统计失败不阻断其它项，缺失项用 0 占位 — 设置页"显示当前状态"
    /// 比"全或无"更友好。
    func loadStatistics() async -> CacheStatistics {
        let (readmeCount, readmeBytes) = await loadReadmeStats()
        let imageDisk = await calculateImageDiskBytes()
        return CacheStatistics(
            readmeCount: readmeCount,
            readmeBytes: readmeBytes,
            imageDiskBytes: imageDisk
        )
    }

    /// 拉 readmes 统计;失败降级返回 (0, 0)。
    /// 抽成 helper 避免 do/catch 与 let 多次赋值冲突,函数 return 单分支语义最干净。
    private func loadReadmeStats() async -> (count: Int, bytes: Int64) {
        do {
            async let cnt = readmeRepository.countAll()
            async let bytes = readmeRepository.totalBytes()
            return try await (cnt, bytes)
        } catch {
            AppLog.database.error("CacheCleaner readme stats failed: \(error.localizedDescription, privacy: .public)")
            return (0, 0)
        }
    }

    // MARK: - 清理操作

    /// 清 README 缓存（GRDB）。
    func clearReadmes() async {
        do {
            try await readmeRepository.deleteAll()
            AppLog.database.info("README cache cleared by user")
        } catch {
            AppLog.database.error("Clear readme cache failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 清 Kingfisher 图片缓存（memory + disk）。
    func clearImageCache() async {
        // memory clear 是同步的
        ImageCache.default.clearMemoryCache()
        await withCheckedContinuation { cont in
            // Kingfisher disk clear 是 callback 风格,用 continuation 桥到 async
            ImageCache.default.clearDiskCache {
                cont.resume()
            }
        }
        AppLog.general.info("Image cache cleared by user")
    }

    /// 清全部(README + 图片)。
    /// 不做事务原子性 — 两者本来就独立,且失败也不影响业务逻辑。
    func clearAll() async {
        await clearReadmes()
        await clearImageCache()
    }

    // MARK: - 内部

    /// 桥接 Kingfisher 的 callback 式 disk size API 到 async。
    /// 失败时返回 0（设置页能显示"无法读取"已经过分了，对用户而言 0 即可解读为"无需清理"）。
    private func calculateImageDiskBytes() async -> UInt {
        await withCheckedContinuation { cont in
            ImageCache.default.calculateDiskStorageSize { result in
                switch result {
                case .success(let bytes):
                    cont.resume(returning: bytes)
                case .failure(let error):
                    AppLog.general.error("Image disk size calc failed: \(error.localizedDescription, privacy: .public)")
                    cont.resume(returning: 0)
                }
            }
        }
    }
}

// MARK: - 字节格式化

extension Int64 {
    /// 把字节数渲染为人类可读字符串(KB/MB)。
    /// 设置页里只展示 1801 条 README 的累计字节 + Kingfisher 缓存,
    /// 通常在几 MB 量级,ByteCountFormatter 输出风格够用。
    var formattedByteSize: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
