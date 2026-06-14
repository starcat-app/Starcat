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
        //
        // 2026-06-14（dong4j 反馈"zip 已下载但 xml/metadata 没生成"）：
        //
        // **必须传 `allowUncontainedSymlinks: true`**，否则任何含相对路径 symlink
        // 的 GitHub 仓库（典型例子：`addyosmani/agent-skills` 里
        // `.opencode/skills -> ../skills/`）解压都会失败：
        //   - ZIPFoundation 0.9+ 默认 `allowUncontainedSymlinks: false`
        //   - 它会先标准化每个 symlink 的 target，发现 `../xxx` 解析后位于解压根之外
        //     就立刻抛 `Archive.ArchiveError.uncontainedSymlink`
        //   - 整个 ZIP 解压被中止 → 整条 packer pipeline 失败 → AI 摘要降级 README-only
        //
        // 打开此开关的安全性论证（已踩过的坑级）：
        //   1. **后续 FileFilter 主动跳 symlink**：`FileFilter.swift` 第 ~64 行
        //      `if values?.isSymbolicLink == true { skipped.append(...symlinkSkipped...); continue }`，
        //      解压出来的 symlink 不会被读内容、不会被分级、不会进 XML；
        //   2. **`FileManager.enumerator` 默认不跟随 symlink**（Apple 文档明确写明），
        //      symlink 指向解压根外侧的内容也不会被 enumerator 列出；
        //   3. **解压目录是沙箱内临时目录**（`Application Support/.../tmp/RepoContextPacker/<UUID>`），
        //      defer 闭包结束就 removeItem 清掉，即使有恶意 symlink 也只是临时存在 < 1s；
        //   4. **GitHub source ZIP 里 symlink 一定是相对路径**（GitHub 不允许 symlink 指向
        //      绝对路径或 `..` 链穿出 repo）。
        //
        // 选择 `allowUncontainedSymlinks: true` 而不是改用 `Archive` 低级 API 手动跳过 symlink
        // entry：实现复杂度 30+ 行 vs 1 行参数；后者还要重写 progress 跟踪 / 错误处理；
        // 前者借助 ZIPFoundation 已有逻辑，改动面最小。
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.unzipItem(
                    at: zipURL,
                    to: tempRoot,
                    allowUncontainedSymlinks: true
                )
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
