// MARK: - DefaultSourceZipExtractor
//
// Pass 0：ZIP 解压 + 安全防护 + GitHub source ZIP layout 识别。
//
// 决议来源：§22.6 Q5（临时目录）+ §22.11 Q10（安全防护）。
//
// 流程：
//   1. **大小预检**：ZIP 自身 > 100MB → 抛 `zipTooLarge`（防御性，省得解压完才发现）
//   2. **创建临时目录**：系统 `temporaryDirectory/RepoContextPacker/<UUID>/`，OS reboot 兜底 GC
//   3. **ZIPFoundation 解压**：放 `Task.detached(.userInitiated)` 避免阻塞调用线程
//   4. **ZIP bomb 兜底**：解压后总大小 > 500MB → cleanup + 抛 `extractedDirectoryTooLarge`
//   5. **识别 unzipped root**：一级目录单个 → 进入它（GitHub source ZIP 通用包裹）/ 否则 flat
//   6. **返回 ExtractedSourceDirectory**：含 rootURL + idempotent cleanup 闭包
//
// 关键约束：
//   - cleanup 闭包**不抛错**（最坏情况：留个 UUID 临时目录，OS reboot 自动清）
//   - 任何错误抛出前必须先清理已创建的临时目录（不留垃圾）
//   - ZIPFoundation 0.9+ 自带 Zip slip 防护，不需要在这里再检查（FileFilter 兜底）

import Foundation
import ZIPFoundation

public struct DefaultSourceZipExtractor: SourceZipExtracting {

    public init() {}

    public func extract(_ zipURL: URL) async throws -> ExtractedSourceDirectory {
        // Step 1：ZIP 文件存在性 + 大小预检
        let zipSize = (
            try? FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? Int
        ) ?? 0
        guard zipSize > 0 else {
            throw RepoContextPackerError.zipFileNotFound(zipURL)
        }
        guard zipSize <= TierRules.zipMaxBytes else {
            throw RepoContextPackerError.zipTooLarge(
                actualBytes: zipSize,
                maxBytes: TierRules.zipMaxBytes
            )
        }

        // Step 2：创建临时目录
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoContextPacker", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: tempRoot,
                withIntermediateDirectories: true
            )
        } catch {
            throw RepoContextPackerError.outputDirectoryNotWritable(tempRoot, underlying: error)
        }

        // Step 3：ZIPFoundation 解压（detached 避免阻塞）
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.unzipItem(at: zipURL, to: tempRoot)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: tempRoot)
            throw RepoContextPackerError.zipExtractionFailed(underlying: error)
        }

        // Step 4：ZIP bomb 兜底
        let extractedSize = Self.directorySize(of: tempRoot)
        guard extractedSize <= TierRules.extractedMaxBytes else {
            try? FileManager.default.removeItem(at: tempRoot)
            throw RepoContextPackerError.extractedDirectoryTooLarge(
                actualBytes: extractedSize,
                maxBytes: TierRules.extractedMaxBytes
            )
        }

        // Step 5：识别真正的项目根目录
        let rootURL: URL
        do {
            rootURL = try Self.findUnzippedRoot(in: tempRoot)
        } catch {
            try? FileManager.default.removeItem(at: tempRoot)
            throw error
        }

        // Step 6：返回 ExtractedSourceDirectory（cleanup 闭包不抛错）
        return ExtractedSourceDirectory(rootURL: rootURL) {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - findUnzippedRoot

    /// 识别 ZIP 解压后的「真正项目根目录」。
    ///
    /// GitHub source ZIP 解出来形如：
    ///   `tempRoot/<repo>-<sha>/  ← 真正项目根`
    ///
    /// 用户自传的 Releases ZIP 可能是 flat layout（直接平铺）。
    ///
    /// **算法**：
    ///   - 过滤 macOS / Windows 元数据（`__MACOSX` / `.DS_Store` / `Thumbs.db`）
    ///   - 如果剩余一级条目正好 1 个 + 是目录 → 进入它（GitHub layout）
    ///   - 否则 → 用 tempRoot 自己（flat layout）
    ///   - 如果一级是空的 → 抛 `zipEmpty`
    static func findUnzippedRoot(in tempRoot: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: tempRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let realEntries = contents.filter { url in
            let name = url.lastPathComponent
            return !name.hasPrefix("__MACOSX") &&
                name != ".DS_Store" &&
                name != "Thumbs.db"
        }

        guard !realEntries.isEmpty else {
            throw RepoContextPackerError.zipEmpty
        }

        // 一级是单个目录 → 进入它
        if realEntries.count == 1,
           let isDir = try? realEntries[0].resourceValues(
            forKeys: [.isDirectoryKey]
           ).isDirectory,
           isDir == true {
            return realEntries[0]
        }

        // flat layout
        return tempRoot
    }

    // MARK: - directorySize

    /// 递归计算目录总大小（bytes）。
    ///
    /// 用 `FileManager.enumerator(at:)` 而不是 `directoryEnumerator`（前者支持 url 形式 + skip
    /// 选项更灵活）。失败时返回 0（不抛错，让 caller 走「大小未知 = 不超限」路径）。
    static func directorySize(of url: URL) -> Int {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: resourceKeys,
            options: []
        ) else {
            return 0
        }

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
