//
//  CodebaseMemoryExtractor.swift
//  Starcat
//
//  持久解压 GitHub source ZIP 到 CodebaseMemory 输出根下的 <owner>/<repo>/source/ 目录。
//
//  与 SourceZipExtractor 的关键差异：
//  - 目标目录持久化（<codebasememory-root>/<owner>/<repo>/source/），不走 tmp
//  - 幂等：写入 .zip.sha256 文件，二次调用时比较跳过解压
//  - 安全参数与 SourceZipExtractor 同款（zipMaxBytes / allowUncontainedSymlinks / ZIP bomb）
//
//  关键约束：
//  - 复用 SharedSnapshotService 的 zipMaxBytes 常量（100MB）
//  - 复用 SourceZipExtractor 已踩过的 allowUncontainedSymlinks: true 决策

import CryptoKit
import Foundation
import ZIPFoundation

struct CodebaseMemoryExtractor {

    /// 单次持久解压结果。
    struct ExtractedSource: Sendable {
        /// 解压后的项目源根目录（绝对路径）。
        let sourceURL: URL
        /// 是否命中已有缓存（跳过了解压）。
        let wasCached: Bool
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// 持久解压 ZIP 到 `outputDirectory/source/`。
    ///
    /// - Parameters:
    ///   - zipURL: 已下载的共享 zipball 路径（来自 SharedSnapshotService）
    ///   - outputDirectory: CodebaseMemory 项目目录（`<root>/<owner>/<repo>/`）
    ///
    /// - Returns: ExtractedSource 含 sourceURL + wasCached 标志
    ///
    /// 幂等判定：写 `<outputDirectory>/.zip.sha256` 文件，内容是 zip 二进制 SHA-256。
    /// 第二次调用时比较该文件与当前 zip 的 SHA-256，相等 + source 目录存在 = wasCached。
    func extractIfNeeded(
        zipURL: URL,
        outputDirectory: URL,
        fileManager overrideFM: FileManager? = nil
    ) async throws -> ExtractedSource {
        let fm = overrideFM ?? fileManager

        // 1. 大小预检（100MB ZIP 上限，与 SharedSnapshotService.maximumArchiveBytes 对齐）
        let zipSize = (try? fm.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? 0
        guard zipSize > 0 else {
            throw CodebaseMemoryError.emptyArchive
        }
        guard zipSize <= 104_857_600 else {
            throw CodebaseMemoryError.archiveTooLarge(actualBytes: zipSize)
        }

        // 2. 计算 ZIP 的 SHA-256 并做幂等判断（CryptoKit, 对 100MB 文件 < 0.5s）
        let shaFileURL = outputDirectory.appendingPathComponent(".zip.sha256")
        let zipData = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        let zipDigest = SHA256.hash(data: zipData)
        let zipSHA = zipDigest.compactMap { String(format: "%02x", $0) }.joined()

        if fm.fileExists(atPath: shaFileURL.path),
           let stored = try? String(contentsOf: shaFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           stored == zipSHA {
            let sourceDir = outputDirectory.appendingPathComponent("source", isDirectory: true)
            if fm.fileExists(atPath: sourceDir.path) {
                return ExtractedSource(sourceURL: sourceDir, wasCached: true)
            }
        }

        // 3. 删除旧 source 目录 + 创建新目录
        let sourceDir = outputDirectory.appendingPathComponent("source", isDirectory: true)
        try? fm.removeItem(at: sourceDir)
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        // 4. ZIPFoundation 解压（detached 避免阻塞调用线程）
        //    allowUncontainedSymlinks: true — 复用 SourceZipExtractor §3 的踩坑决策
        do {
            try await Task.detached(priority: .userInitiated) {
                try fm.unzipItem(
                    at: zipURL,
                    to: sourceDir,
                    allowUncontainedSymlinks: true
                )
            }.value
        } catch {
            try? fm.removeItem(at: sourceDir)
            throw CodebaseMemoryError.indexFailed(underlying: error.localizedDescription)
        }

        // 5. ZIP bomb 兜底（500MB 解压上限，同 SourceZipExtractor）
        let extractedBytes = Self.directorySize(of: sourceDir, fileManager: fm)
        guard extractedBytes <= 524_288_000 else {
            try? fm.removeItem(at: sourceDir)
            throw CodebaseMemoryError.extractedTooLarge(actualBytes: extractedBytes)
        }

        // 6. 写 .zip.sha256 做幂等凭证
        try zipSHA.write(to: shaFileURL, atomically: true, encoding: .utf8)

        return ExtractedSource(sourceURL: sourceDir, wasCached: false)
    }

    // MARK: - Helpers

    /// 递归计算目录总大小（bytes），同 SourceZipExtractor.directorySize。
    static func directorySize(of url: URL, fileManager: FileManager = .default) -> Int {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(resourceKeys))
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += size
            }
        }
        return total
    }
}
