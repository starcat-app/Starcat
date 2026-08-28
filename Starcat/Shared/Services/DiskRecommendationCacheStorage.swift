//
//  DiskRecommendationCacheStorage.swift
//  Starcat
//
//  推荐缓存的磁盘 I/O actor。详情页推荐是旁路能力，任何文件读取、JSON 编解码
//  或目录统计都不能占用 MainActor，否则缓存越大越容易拖慢详情页首帧。
//

import Foundation

/// 推荐缓存磁盘统计。
struct RecommendationCacheStatistics: Sendable, Equatable {
    let itemCount: Int
    let totalBytes: Int64

    static let empty = RecommendationCacheStatistics(itemCount: 0, totalBytes: 0)
}

/// 读取结果携带可选统计；只有损坏文件被删除时才要求 MainActor 刷新设置页数字。
struct RecommendationCacheLoadResult: Sendable {
    let snapshot: RecommendationCacheSnapshot?
    let statistics: RecommendationCacheStatistics?
}

/// 串行保护推荐缓存文件操作，并把所有阻塞式 Foundation I/O 隔离到 MainActor 之外。
actor DiskRecommendationCacheStorage {
    private let fileManager = FileManager.default
    private let rootOverride: URL?

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(rootOverride: URL?) {
        self.rootOverride = rootOverride
    }

    /// 读取单仓快照。损坏文件会被删除，使下一次访问自然回源。
    func load(repoID: Int64) -> RecommendationCacheLoadResult {
        guard repoID > 0 else {
            return RecommendationCacheLoadResult(snapshot: nil, statistics: nil)
        }
        let url: URL
        do {
            url = try cacheFileURL(repoID: repoID)
        } catch {
            AppLog.network.warning("Recommendation cache: invalid path repoID=\(repoID, privacy: .public)")
            return RecommendationCacheLoadResult(snapshot: nil, statistics: nil)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return RecommendationCacheLoadResult(snapshot: nil, statistics: nil)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            AppLog.network.warning(
                "Recommendation cache: read failed path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            return RecommendationCacheLoadResult(snapshot: nil, statistics: nil)
        }

        do {
            return RecommendationCacheLoadResult(
                snapshot: try decoder.decode(RecommendationCacheSnapshot.self, from: data),
                statistics: nil
            )
        } catch {
            // 缓存可重建；损坏时删除单文件，不能让一次解码失败反复阻塞详情页。
            AppLog.network.warning(
                "Recommendation cache: decode failed, removing path=\(url.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            try? fileManager.removeItem(at: url)
            return RecommendationCacheLoadResult(snapshot: nil, statistics: statistics())
        }
    }

    /// 原子覆写单仓快照，并返回写入后的全局统计。
    func save(snapshot: RecommendationCacheSnapshot) throws -> RecommendationCacheStatistics {
        let url = try cacheFileURL(repoID: snapshot.repoID)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
        return statistics()
    }

    /// 删除全部推荐缓存，并返回空统计。
    func deleteEverything() throws -> RecommendationCacheStatistics {
        let root = try rootURL()
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
        return .empty
    }

    /// 扫描缓存目录。扫描仍保留，但在 actor 上执行，不再阻塞设置页或详情页。
    func statistics() -> RecommendationCacheStatistics {
        guard let root = try? rootURL(),
              fileManager.fileExists(atPath: root.path) else {
            return .empty
        }

        var total: Int64 = 0
        var count = 0
        for file in collectJSONFiles(under: root) {
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
                count += 1
            }
        }
        return RecommendationCacheStatistics(itemCount: count, totalBytes: total)
    }

    private func rootURL() throws -> URL {
        if let rootOverride { return rootOverride }
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw DiskRecommendationCacheError.applicationSupportUnavailable
        }
        return appSupport
            .appendingPathComponent(AppConstants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("recommendation-cache", isDirectory: true)
    }

    private func cacheFileURL(repoID: Int64) throws -> URL {
        try rootURL().appendingPathComponent("\(repoID).json")
    }

    private func collectJSONFiles(under directory: URL) -> [URL] {
        var files: [URL] = []
        let children = (
            try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
            )
        ) ?? []
        for child in children {
            if child.hasDirectoryPath {
                files.append(contentsOf: collectJSONFiles(under: child))
            } else if child.pathExtension == "json" {
                files.append(child)
            }
        }
        return files
    }
}
