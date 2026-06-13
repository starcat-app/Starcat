// MARK: - DefaultContextWriter
//
// Pass 4：原子写盘 `context.xml` + `metadata.json` 到
// `outputBaseDir/<owner>/<repo>/`。
//
// 决议来源：§22.6 Q5（产物持久化布局）+ §22.4 Q3（致命错抛 `writeFailed`）。
//
// 原子写策略：
//   1. 创建输出目录（如已存在则保留）
//   2. 写 `.tmp` 文件（不直接写目标名）
//   3. fsync（让 OS 把数据从 page cache 落盘）
//   4. atomic rename（FileManager.replaceItemAt）—— 原子操作，保证消费方看到的是「完整文件」
//
// 关键不变量：
//   - 写盘失败 → 抛 `writeFailed` → caller cleanup 临时目录但不会留半成品产物
//   - context.xml 和 metadata.json 都用同款流程，单独失败时另一个也回滚（暂未实现，留 TODO）
//   - metadata.json 内的 contextXmlBytes 字段是 context.xml 真实写入后的 byte count

import Foundation

public struct DefaultContextWriter: ContextWriting {

    public init() {}

    public func write(
        xml: String,
        metadata: PackMetadata,
        outputBaseDir: URL,
        owner: String,
        repo: String
    ) async throws -> PackOutput {
        // Step 1：创建输出目录 outputBaseDir/<owner>/<repo>/
        let repoDir = outputBaseDir
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: repoDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw RepoContextPackerError.outputDirectoryNotWritable(repoDir, underlying: error)
        }

        let contextURL = repoDir.appendingPathComponent("context.xml", isDirectory: false)
        let metadataURL = repoDir.appendingPathComponent("metadata.json", isDirectory: false)

        // Step 2：写 context.xml（原子）
        guard let xmlData = xml.data(using: .utf8) else {
            // 极少触发：String 转 UTF-8 失败
            throw RepoContextPackerError.xmlBuildFailed(
                underlying: NSError(
                    domain: "RepoContextPacker",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "XML 转 UTF-8 失败"]
                )
            )
        }
        try await Self.writeAtomically(data: xmlData, to: contextURL)

        // Step 3：写 metadata.json（原子）
        let metadataData = try Self.encodeMetadata(metadata, contextXmlBytes: xmlData.count)
        try await Self.writeAtomically(data: metadataData, to: metadataURL)

        return PackOutput(
            contextURL: contextURL,
            metadataURL: metadataURL,
            stats: PackStats(
                totalFiles: metadata.stats.totalFiles,
                tier0Count: metadata.stats.tier0Count,
                tier1Count: metadata.stats.tier1Count,
                tier2Count: metadata.stats.tier2Count,
                estimatedTokens: metadata.stats.estimatedTokens,
                actualTokens: metadata.stats.actualTokens,
                contextXmlBytes: xmlData.count
            ),
            generatedAt: Date()
        )
    }

    // MARK: - writeAtomically

    /// 原子写文件：data → .tmp → rename。
    ///
    /// 用 `Data.write(to:options:.atomic)`，Foundation 内部用了 atomic file replacement
    /// （新文件 + rename，保证消费方看到的是完整文件）。
    private static func writeAtomically(data: Data, to url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw RepoContextPackerError.writeFailed(url, underlying: error)
            }
        }.value
    }

    // MARK: - encodeMetadata

    /// 把 PackMetadata 编码为 JSON Data。
    ///
    /// 因为 PackMetadata 自身的 contextXmlBytes 字段在 metadata 已经定义为 PackStats 子字段，
    /// 这里需要把已知的 xmlBytes 填进去（其它字段已由 caller 准备）。
    private static func encodeMetadata(_ metadata: PackMetadata, contextXmlBytes: Int) throws -> Data {
        // 把 stats 字段的 contextXmlBytes 用真实值替换
        let updatedStats = PackStats(
            totalFiles: metadata.stats.totalFiles,
            tier0Count: metadata.stats.tier0Count,
            tier1Count: metadata.stats.tier1Count,
            tier2Count: metadata.stats.tier2Count,
            estimatedTokens: metadata.stats.estimatedTokens,
            actualTokens: metadata.stats.actualTokens,
            contextXmlBytes: contextXmlBytes
        )
        let updated = PackMetadata(
            schemaVersion: metadata.schemaVersion,
            tierRulesVersion: metadata.tierRulesVersion,
            tokenEstimatorVersion: metadata.tokenEstimatorVersion,
            owner: metadata.owner,
            repo: metadata.repo,
            ref: metadata.ref,
            commitSha: metadata.commitSha,
            generatedAt: metadata.generatedAt,
            tokenBudget: metadata.tokenBudget,
            stats: updatedStats,
            skippedFiles: metadata.skippedFiles,
            warnings: metadata.warnings
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(updated)
        } catch {
            throw RepoContextPackerError.xmlBuildFailed(underlying: error)
        }
    }
}
