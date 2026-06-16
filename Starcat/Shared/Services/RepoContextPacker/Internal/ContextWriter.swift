// MARK: - DefaultContextWriter
//
// Pass 4：原子写盘 `context.xml` + `metadata.json`。
//
// 决议来源：§22.6 Q5（产物持久化布局）+ §22.4 Q3（致命错抛 `writeFailed`）。
//
// **2026-06-13 W8 改造**：可选注入 `RepoContextStorage`，让产物管理（自定义目录
// bookmark + 路径迁移 + generationCount 累加 + lastAccessedAt 刷新）统一由 storage
// 承担。**两条写盘路径并存**：
//   - storage 非 nil（生产路径）：走 `storage.write(xml:metadata:owner:repo:)`，
//     storage 内部维护：security scope / generationCount + 1 / lastAccessedAt = now /
//     contextXmlBytes 回填；本 writer 只负责把 stored 结果包成 PackOutput；
//   - storage 为 nil（**单测路径**保留）：直接走传统 outputBaseDir 原子写盘，generationCount /
//     lastAccessedAt 都为 nil。这样现有 ContextWriterTests 不破坏。
//
// 原子写策略（storage 为 nil 路径）：
//   1. 创建输出目录（如已存在则保留）
//   2. 写 `.tmp` 文件（不直接写目标名）
//   3. atomic rename（Data.write(.atomic)）—— 原子操作，保证消费方看到的是「完整文件」
//
// 关键不变量：
//   - 写盘失败 → 抛 `writeFailed` → caller cleanup 临时目录但不会留半成品产物
//   - metadata.json 内的 contextXmlBytes 字段是 context.xml 真实写入后的 byte count
//   - **storage 路径的 PackInput.outputBaseDir 字段被忽略**（路径由 storage 内部 root 决定）；
//     这是有意的——caller 传哪个 outputBaseDir 都不影响产物落盘位置，避免重复事实源

import Foundation

public struct DefaultContextWriter: ContextWriting {

    /// 可选产物存储。注入后写盘改走 storage.write（W8 决议）。
    /// 单测保持 nil 走传统路径。
    private let storage: RepoContextStorage?

    /// 无参 public init：保留给单测 / 外部消费者（不走 storage 路径）。
    public init() {
        self.storage = nil
    }

    /// internal init：生产路径，AppDependencies 装配时注入 storage。
    /// `RepoContextStorage` 是 internal 类型（@Observable 单例局限于 app target），
    /// 所以 init 不能 public——这条约束顺手解决了"测试入口"与"生产入口"的分离。
    init(storage: RepoContextStorage?) {
        self.storage = storage
    }

    public func write(
        xml: String,
        metadata: PackMetadata,
        outputBaseDir: URL,
        owner: String,
        repo: String
    ) async throws -> PackOutput {
        // W8 路径：storage 注入了 → 走 storage.write 统一管理产物目录。
        if let storage {
            return try await writeViaStorage(
                xml: xml,
                metadata: metadata,
                owner: owner,
                repo: repo,
                storage: storage
            )
        }

        // 兼容路径：storage 为 nil → 直接落 outputBaseDir（保留给单测用）。
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
                    userInfo: [NSLocalizedDescriptionKey: String.l10n("packer.error.xmlEncodingFailed")]
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

    // MARK: - W8 storage 路径

    /// 通过 `RepoContextStorage.write(...)` 写盘（W8 决议路径）。
    ///
    /// 关键差异（与传统路径相比）：
    ///   - 落盘位置由 storage 内部的"自定义 bookmark 或 default app support"决定，
    ///     **完全不看** `PackInput.outputBaseDir`；
    ///   - storage 内部自动从已有 metadata 提取 `generationCount` 并 +1；
    ///   - storage 内部自动把 `lastAccessedAt` 刷成 `now` ISO-8601；
    ///   - storage 内部自动回填 `metadata.stats.contextXmlBytes`。
    ///
    /// **为什么不用 `Task.detached`**：`RepoContextStorage` 是 `@Observable final class`，
    /// 不是 `Sendable`——`Task.detached` 闭包捕获会触发 Swift 严格并发警告。`RepoContextPacker.pack`
    /// 本身已经在 cooperative thread pool 上跑（async function），storage 同步 throws 接口在这里
    /// 直接 await 即可；如果担心 I/O 阻塞，用 `Task.yield()` 让出当前 cooperative thread（写盘 < 50ms
    /// 通常不需要让出）。
    private func writeViaStorage(
        xml: String,
        metadata: PackMetadata,
        owner: String,
        repo: String,
        storage: RepoContextStorage
    ) async throws -> PackOutput {
        do {
            let stored = try storage.write(
                xml: xml,
                metadata: metadata,
                owner: owner,
                repo: repo
            )
            return PackOutput(
                contextURL: stored.contextURL,
                metadataURL: stored.metadataURL,
                stats: stored.metadata.stats,
                generatedAt: stored.generatedAtDate
            )
        } catch {
            // storage 内部错误（security scope 失效 / 磁盘满 / encode 失败）
            // 统一映射成 writeFailed，让上层 RepoContextPacker error mapping 不需要
            // 增加 `RepoContextStorageError` 这条枝。
            throw RepoContextPackerError.writeFailed(
                URL(fileURLWithPath: "/storage/\(owner)/\(repo)"),
                underlying: error
            )
        }
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
