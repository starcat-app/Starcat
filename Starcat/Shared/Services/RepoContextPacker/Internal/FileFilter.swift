// MARK: - DefaultFileFilter
//
// Pass 1：递归 walk 解压目录 + 应用 ignore 规则 + 安全防护，输出候选文件清单。
//
// 决议来源：
//   - §22.3 Q2：用 GlobCompiler 做 ignore 匹配
//   - §22.7 Q6：扩展名 / 文件名白名单 fast-path
//   - §22.11 Q10：Zip slip 兜底 + symlink 完全跳过 + 5MB 单文件上限
//
// 关键约束（写入注释作为永久记录）：
//   1. **不读文件内容**（懒读决议）—— 只 stat metadata（size / isSymlink / isRegularFile）
//   2. **Zip slip 兜底**：每个 fileURL 的 standardizedFileURL.path 必须以 rootURL.standardizedFileURL.path + "/" 开头
//      ZIPFoundation 0.9+ 已挡，这是 defense-in-depth
//   3. **symlink 全跳过**：跟随 symlink 有沙箱外读取风险，记 skippedFiles `symlinkSkipped`
//   4. **5MB 单文件上限**：强制 skip 记 `singleFileTooLarge`（任何 tier 都不读这种大文件）
//   5. **白名单 fast-path**：扩展名 / 文件名不在白名单 → 视为非文本（不进入候选）
//
// 性能：默认 ignore 列表 ~140 条 + Tier 0/1 glob 各 ~30 条，对 5000 文件做 200 次 regex match
// 约 100ms（缓存预编译后）。

import Foundation

public struct DefaultFileFilter: FileFiltering {

    /// 预编译的 ignore regex 缓存（caller 传入避免每次扫描重编）。
    private let ignoreRegexes: [NSRegularExpression]

    public init(ignorePatterns: [String] = TierRules.defaultIgnorePatterns) throws {
        self.ignoreRegexes = try GlobCompiler.compileAll(ignorePatterns)
    }

    public func scan(rootURL: URL) throws -> FileFilterResult {
        var files: [FilteredFile] = []
        var skipped: [SkippedFile] = []

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isDirectoryKey,
            .fileSizeKey,
        ]
        let resourceKeysSet = Set(resourceKeys)

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            // 极少触发，但要给个明确错（不只是返回空）
            throw RepoContextPackerError.noFilesAfterFiltering
        }

        let normalizedRootPath = rootURL.standardizedFileURL.path

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: resourceKeysSet)

            // === Symlink 完全跳过（§22.11）===
            if values?.isSymbolicLink == true {
                let relativePath = Self.relativePath(of: fileURL, relativeTo: rootURL)
                skipped.append(SkippedFile(
                    path: relativePath,
                    reason: SkipReason.symlinkSkipped,
                    tier: nil
                ))
                // enumerator 不会自动 skip symlink 的子树，但这里 file 本身是 symlink 就跳过 +
                // 不修改 enumerator descend 状态（symlink 本身不会递归进去）
                continue
            }

            // 只处理普通文件
            guard values?.isRegularFile == true else {
                continue
            }

            // === Zip slip 兜底（§22.11）===
            let normalizedFilePath = fileURL.standardizedFileURL.path
            guard normalizedFilePath.hasPrefix(normalizedRootPath + "/") else {
                throw RepoContextPackerError.zipSlipDetected(path: fileURL.path)
            }

            // 计算相对路径（POSIX `/`）
            let relativePath = Self.relativePath(of: fileURL, relativeTo: rootURL)

            // === 应用 ignore 规则 ===
            if GlobCompiler.matchesAny(ignoreRegexes, path: relativePath) {
                continue
            }

            // === 5MB 单文件上限（§22.11）===
            let sizeBytes = values?.fileSize ?? 0
            if sizeBytes > TierRules.singleFileMaxBytes {
                skipped.append(SkippedFile(
                    path: relativePath,
                    reason: SkipReason.singleFileTooLarge,
                    tier: nil,
                    fileSize: sizeBytes
                ))
                continue
            }

            // === 文本扩展名白名单 fast-path（§22.7）===
            // 决议：不在白名单的文件视为非文本，**静默 skip**（不写 skippedFiles）。
            // 写 skippedFiles 会让 metadata 巨大（一个仓库可能几百个 binary / 未知扩展名）。
            if !Self.isLikelyTextFile(relativePath: relativePath) {
                continue
            }

            files.append(FilteredFile(
                relativePath: relativePath,
                absoluteURL: fileURL,
                sizeBytes: sizeBytes
            ))
        }

        // === 过滤后空 = 致命 ===
        guard !files.isEmpty else {
            throw RepoContextPackerError.noFilesAfterFiltering
        }

        return FileFilterResult(files: files, skippedFiles: skipped)
    }

    // MARK: - 工具方法

    /// 计算 fileURL 相对于 rootURL 的 POSIX 路径（如 `src/index.swift`）。
    ///
    /// 算法：
    ///   - 取 fileURL 的 standardizedFileURL.path（已经是 POSIX）
    ///   - strip 掉 rootURL 的 standardizedFileURL.path + "/" 前缀
    static func relativePath(of fileURL: URL, relativeTo rootURL: URL) -> String {
        let fullPath = fileURL.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path + "/"
        if fullPath.hasPrefix(rootPath) {
            return String(fullPath.dropFirst(rootPath.count))
        }
        // 兜底（不应触发，因为 Zip slip 检查已经保证 fullPath 在 rootPath 子树）
        return fileURL.lastPathComponent
    }

    /// 判定路径是否「可能是文本文件」（扩展名 / 文件名白名单 fast-path）。
    ///
    /// - 优先匹配文件名白名单（无扩展名文件如 `LICENSE` / `Makefile` / `Dockerfile`）
    /// - 再匹配扩展名白名单（如 `.swift` / `.py` / `.md`）
    /// - 都不命中 → 视为非文本（return false）
    ///
    /// **注意**：返回 true 不代表「肯定是文本」——后续 BinaryDetection.isLikelyBinary() 在
    /// Tier 0/1 读取前还要做 NUL 字节探测。本函数是 cheap fast-path（不读文件）。
    static func isLikelyTextFile(relativePath: String) -> Bool {
        // 取文件名
        let filename = (relativePath as NSString).lastPathComponent

        // 1. 文件名白名单（精确匹配，case-sensitive）
        if TierRules.textFilenames.contains(filename) {
            return true
        }

        // 2. 扩展名白名单（lowercased 比较 —— 扩展名实际仓库 case 不统一，如 `.MD` / `.Md`）
        let ext = (filename as NSString).pathExtension.lowercased()
        if !ext.isEmpty && TierRules.textExtensions.contains(ext) {
            return true
        }

        return false
    }
}
