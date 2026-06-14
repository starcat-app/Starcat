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

import AppKit
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
    /// CodeFlow / RepoContext 共用的源码 ZIP 数量与容量。
    let archiveCount: Int
    let archiveBytes: Int64
    /// 派生：总字节数（README + 图片磁盘 + 源码 ZIP）。
    var totalBytes: Int64 { readmeBytes + Int64(imageDiskBytes) + archiveBytes }

    static let empty = CacheStatistics(
        readmeCount: 0,
        readmeBytes: 0,
        imageDiskBytes: 0,
        archiveCount: 0,
        archiveBytes: 0
    )
}

/// 缓存清理协调器。
///
/// 单例性：不必单例 — 由 SettingsView 局部构造即可，依赖通过 init 注入。
/// MainActor：因为读 ReadmeRepository（async DB 读）+ 写到 SwiftUI 状态，
/// 用 MainActor 减少跨域跳转。
@MainActor
final class CacheCleaner {

    private let readmeRepository: ReadmeRepository
    private let fileManager: FileManager
    private let fixedArchiveDirectory: URL?

    init(
        readmeRepository: ReadmeRepository,
        fileManager: FileManager = .default,
        fixedArchiveDirectory: URL? = nil
    ) {
        self.readmeRepository = readmeRepository
        self.fileManager = fileManager
        self.fixedArchiveDirectory = fixedArchiveDirectory
    }

    // MARK: - 统计

    /// 计算当前缓存用量快照。
    ///
    /// 失败降级策略：任一子统计失败不阻断其它项，缺失项用 0 占位 — 设置页"显示当前状态"
    /// 比"全或无"更友好。
    func loadStatistics() async -> CacheStatistics {
        let (readmeCount, readmeBytes) = await loadReadmeStats()
        let imageDisk = await calculateImageDiskBytes()
        let archives = loadArchiveStats()
        return CacheStatistics(
            readmeCount: readmeCount,
            readmeBytes: readmeBytes,
            imageDiskBytes: imageDisk,
            archiveCount: archives.count,
            archiveBytes: archives.bytes
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

    /// 只删除共享下载目录里的 ZIP 文件，保留根目录和任何非 ZIP 文件。
    func clearArchives() {
        do {
            let directory = try archiveDirectoryURL()
            for url in archiveFileURLs(in: directory) {
                try fileManager.removeItem(at: url)
            }
            removeEmptySubdirectories(in: directory)
            AppLog.general.info("Downloaded repository ZIP files cleared by user")
        } catch {
            AppLog.general.error("Clear repository ZIP files failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 打开共享 ZIP 下载目录；目录尚未创建时先创建。
    func revealArchiveDirectory() throws {
        let directory = try archiveDirectoryURL()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    /// 清全部(README + 图片)。
    /// 不做事务原子性 — 两者本来就独立,且失败也不影响业务逻辑。
    func clearAll() async {
        await clearReadmes()
        await clearImageCache()
        clearArchives()
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

    private func loadArchiveStats() -> (count: Int, bytes: Int64) {
        do {
            let files = archiveFileURLs(in: try archiveDirectoryURL())
            let bytes = files.reduce(into: Int64(0)) { total, url in
                let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                total += Int64(size ?? 0)
            }
            return (files.count, bytes)
        } catch {
            AppLog.general.error("Repository ZIP stats failed: \(error.localizedDescription, privacy: .public)")
            return (0, 0)
        }
    }

    private func archiveDirectoryURL() throws -> URL {
        if let fixedArchiveDirectory { return fixedArchiveDirectory }
        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Starcat/archives", isDirectory: true)
    }

    private func archiveFileURLs(in directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "zip",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    /// 清掉 ZIP 后遗留的 owner / host 空目录，但保留用户要打开的 `archives` 根目录。
    private func removeEmptySubdirectories(in root: URL) {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let directories = enumerator.compactMap { $0 as? URL }.sorted {
            $0.pathComponents.count > $1.pathComponents.count
        }
        for directory in directories where directory != root {
            if (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? fileManager.removeItem(at: directory)
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
