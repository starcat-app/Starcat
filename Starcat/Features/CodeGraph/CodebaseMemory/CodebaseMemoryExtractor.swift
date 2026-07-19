//
//  CodebaseMemoryExtractor.swift
//  Starcat
//
//  持久解压 GitHub source ZIP 到 CodebaseMemory 输出根下的 <owner>/<repo>/source/ 目录。
//
//  与 SourceZipExtractor 的关键差异：
//  - 目标目录持久化（<codebasememory-root>/<owner>/<repo>/source/），不走 tmp
//  - 幂等：写入 .zip.sha256 文件，二次调用时比较跳过解压
//  - 安全参数与 SourceZipExtractor 同款（运行时 ZIP 上限 / allowUncontainedSymlinks / ZIP bomb）
//
//  关键约束：
//  - 生产调用传入 AI「代码上下文」配置的 ZIP 上限，与下载阶段保持一致
//  - 解压后上限按 ZIP 上限的 5 倍计算，避免提高下载上限后仍被旧 500MB 常量误拦截
//  - 复用 SourceZipExtractor 已踩过的 allowUncontainedSymlinks: true 决策

import CryptoKit
import Foundation
import ZIPFoundation

/// `FileManager` 在 Swift 6 中不是 Sendable；本类型只保存不可变依赖入口，
/// 重型 detached 解压任务会在任务内部创建独立 FileManager，避免跨线程共享该实例。
struct CodebaseMemoryExtractor: @unchecked Sendable {

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
        maximumArchiveBytes: Int,
        fileManager overrideFM: FileManager? = nil
    ) async throws -> ExtractedSource {
        let fm = overrideFM ?? fileManager

        // 1. 再做一次运行时大小预检，避免缓存文件或非下载入口绕过用户配置。
        let zipSize = (try? fm.attributesOfItem(atPath: zipURL.path)[.size] as? Int) ?? 0
        guard zipSize > 0 else {
            throw CodebaseMemoryError.emptyArchive
        }
        guard zipSize <= maximumArchiveBytes else {
            throw CodebaseMemoryError.archiveTooLarge(actualBytes: zipSize)
        }
        let (scaledExtractedLimit, overflow) = maximumArchiveBytes.multipliedReportingOverflow(by: 5)
        let maximumExtractedBytes = overflow ? Int.max : scaledExtractedLimit

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
                // 用户调低阈值后，旧解压缓存也必须重新服从新的 5× 上限。
                let cachedExtractedBytes = Self.directorySize(of: sourceDir, fileManager: fm)
                guard cachedExtractedBytes <= maximumExtractedBytes else {
                    throw CodebaseMemoryError.extractedTooLarge(actualBytes: cachedExtractedBytes)
                }
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
                // 不捕获外层 FileManager：Swift 6 会把它视为跨并发边界的可变引用。
                // 解压任务内部使用独立实例，避免阻塞调用方 actor 的同时保持文件操作局部化。
                let workerFileManager = FileManager()
                try workerFileManager.unzipItem(
                    at: zipURL,
                    to: sourceDir,
                    allowUncontainedSymlinks: true
                )
            }.value
        } catch {
            try? fm.removeItem(at: sourceDir)
            throw CodebaseMemoryError.indexFailed(underlying: error.localizedDescription)
        }

        // 5. ZIP bomb 兜底。与 RepoContextPacker 一致按压缩包上限的 5 倍计算。
        let extractedBytes = Self.directorySize(of: sourceDir, fileManager: fm)
        guard extractedBytes <= maximumExtractedBytes else {
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
