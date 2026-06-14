// MARK: - RepoContextPacker（Facade）
//
// Packer pipeline 的对外入口 —— 把 ZIP 转成 context.xml + metadata.json。
//
// 决议来源：§22.5 Q4（async throws facade + 6 步编排 + Task.checkCancellation 全程插入）。
//
// 调用流程：
//   ```swift
//   let packer = RepoContextPacker()
//   let output = try await packer.pack(PackInput(
//       zipURL: ...,
//       owner: "vapor", repo: "vapor", ref: "main", commitSha: "abc123...",
//       outputBaseDir: applicationSupportURL.appendingPathComponent("analysis"),
//       tokenBudget: 8000
//   ))
//   // output.contextURL → 喂给 LLM
//   // output.metadataURL → 调试 / UI 显示
//   ```
//
// **6 步编排**：
//   1. Pass 0: SourceZipExtractor 解压 ZIP
//   2. Pass 1: FileFilter 走 ignore + 安全防护
//   3. Pass 2a: TierClassifier 分级
//   4. Pass 2b: BudgetAllocator 分配 strategy
//   5. Pass 2c: DirectoryTreeBuilder 生成目录树
//   6. Pass 3: XmlOutputBuilder 并发读 + 拼 XML
//   7. Pass 4: ContextWriter 原子写盘
//
// **取消策略**：每个 Pass 入口都 try Task.checkCancellation()，发现 task 被 cancel 立刻
// 抛 `RepoContextPackerError.cancelled`。
//
// **清理策略**：解压临时目录用 defer 兜底，**任何分支**下都执行 cleanup。

import Foundation

public struct RepoContextPacker {

    // MARK: - 依赖（默认实现，protocol 注入可换 mock）

    private let extractor: SourceZipExtracting
    private let filter: FileFiltering
    private let classifier: TierClassifying
    private let allocator: BudgetAllocating
    private let treeBuilder: DirectoryTreeBuilding
    private let xmlBuilder: XmlOutputBuilding
    private let writer: ContextWriting

    // MARK: - 初始化

    public init(
        extractor: SourceZipExtracting? = nil,
        filter: FileFiltering? = nil,
        classifier: TierClassifying? = nil,
        allocator: BudgetAllocating = DefaultBudgetAllocator(),
        treeBuilder: DirectoryTreeBuilding = DefaultDirectoryTreeBuilder(),
        xmlBuilder: XmlOutputBuilding = DefaultXmlOutputBuilder(),
        writer: ContextWriting = DefaultContextWriter()
    ) throws {
        self.extractor = extractor ?? DefaultSourceZipExtractor()
        self.filter = try filter ?? DefaultFileFilter()
        self.classifier = try classifier ?? DefaultTierClassifier()
        self.allocator = allocator
        self.treeBuilder = treeBuilder
        self.xmlBuilder = xmlBuilder
        self.writer = writer
    }

    // MARK: - pack（pipeline 入口）

    public func pack(_ input: PackInput) async throws -> PackOutput {
        let generatedAt = Date()
        // 2026-06-14 dong4j 反馈 "zip 已下载但 xml/metadata 没生成"：在 6 步 pipeline 之间
        // 加 OSLog 埋点。每个 Pass 入口写一行 debug，出口在 catch 处由调用栈外的
        // RepoAIContextProvider.formatErrorForDiagnostics 兜底 dump 完整错误链。
        // 这样 Console.app 上能一眼看到管道卡在哪一 Pass。
        let scope = "\(input.owner)/\(input.repo)@\(input.commitSha.prefix(7))"
        AppLog.ai.debug(
            """
            [Packer] start \(scope, privacy: .public) \
            zipURL=\(input.zipURL.path, privacy: .public) \
            tokenBudget=\(input.tokenBudget, privacy: .public) \
            tier1MaxLines=\(input.tier1MaxLines, privacy: .public)
            """
        )

        // === Pass 0：解压 ZIP ===
        try Task.checkCancellation()
        AppLog.ai.debug("[Packer] \(scope, privacy: .public) Pass 0 extract begin")
        let extracted = try await extractor.extract(input.zipURL)
        // 任何分支下都清理临时目录
        defer { extracted.cleanup() }
        AppLog.ai.debug(
            "[Packer] \(scope, privacy: .public) Pass 0 extract done root=\(extracted.rootURL.lastPathComponent, privacy: .public)"
        )

        // === Pass 1：过滤文件 ===
        try Task.checkCancellation()
        AppLog.ai.debug("[Packer] \(scope, privacy: .public) Pass 1 filter begin")
        let filterResult = try filter.scan(rootURL: extracted.rootURL)
        AppLog.ai.debug(
            "[Packer] \(scope, privacy: .public) Pass 1 filter done files=\(filterResult.files.count, privacy: .public) skipped=\(filterResult.skippedFiles.count, privacy: .public)"
        )

        // === Pass 2a：分级 ===
        try Task.checkCancellation()
        let classifyResult = classifier.classify(files: filterResult.files)
        AppLog.ai.debug(
            "[Packer] \(scope, privacy: .public) Pass 2a classify done tiered=\(classifyResult.tieredFiles.count, privacy: .public) skipped=\(classifyResult.skippedFiles.count, privacy: .public)"
        )

        // === Pass 2b：预算分配 ===
        try Task.checkCancellation()
        let plan = allocator.allocate(classifyResult.tieredFiles, budget: input.tokenBudget)
        AppLog.ai.debug(
            "[Packer] \(scope, privacy: .public) Pass 2b allocate done items=\(plan.items.count, privacy: .public) estTokens=\(plan.totalEstimatedTokens, privacy: .public)"
        )

        // === Pass 2c：目录树 ===
        try Task.checkCancellation()
        let directoryTree = treeBuilder.build(filterResult.files)

        // === Pass 3：XML 拼装（含并发读）===
        try Task.checkCancellation()
        AppLog.ai.debug("[Packer] \(scope, privacy: .public) Pass 3 xml build begin")
        let xmlMeta = XmlMetadata(
            owner: input.owner,
            repo: input.repo,
            ref: input.ref,
            commitSha: input.commitSha,
            generatedAt: generatedAt,
            tokenBudget: input.tokenBudget
        )
        let buildResult = try await xmlBuilder.build(
            plan: plan,
            directoryTree: directoryTree,
            metadata: xmlMeta,
            tier1MaxLines: input.tier1MaxLines
        )
        AppLog.ai.debug(
            "[Packer] \(scope, privacy: .public) Pass 3 xml build done actualTokens=\(buildResult.actualTokens, privacy: .public) skipped=\(buildResult.skippedFiles.count, privacy: .public) warnings=\(buildResult.warnings.count, privacy: .public)"
        )

        // === Pass 4：写盘 ===
        try Task.checkCancellation()
        AppLog.ai.debug("[Packer] \(scope, privacy: .public) Pass 4 write begin")
        let allSkipped = filterResult.skippedFiles
            + classifyResult.skippedFiles
            + buildResult.skippedFiles
        let tier0Count = plan.items.filter { $0.tieredFile.tier == .zero }.count
        let tier1Count = plan.items.filter { $0.tieredFile.tier == .one }.count
        let tier2Count = plan.items.filter { $0.tieredFile.tier == .two }.count

        let metadata = PackMetadata(
            schemaVersion: 1,
            tierRulesVersion: TierRules.tierRulesVersion,
            tokenEstimatorVersion: TierRules.tokenEstimatorVersion,
            owner: input.owner,
            repo: input.repo,
            ref: input.ref,
            commitSha: input.commitSha,
            generatedAt: Self.iso8601(generatedAt),
            tokenBudget: input.tokenBudget,
            stats: PackStats(
                totalFiles: plan.items.count,
                tier0Count: tier0Count,
                tier1Count: tier1Count,
                tier2Count: tier2Count,
                estimatedTokens: plan.totalEstimatedTokens,
                actualTokens: buildResult.actualTokens,
                contextXmlBytes: 0  // writer 会回填真实值
            ),
            skippedFiles: allSkipped,
            warnings: buildResult.warnings,
            // W7：写入 tier1MaxLines 让 RepoAIContextProvider 缓存命中判定能区分
            // "用户调过 Tier 1 行数后的旧 metadata"。
            tier1MaxLines: input.tier1MaxLines,
            // lastAccessedAt / generationCount 由 ContextWriter 在 W8 写盘前从
            // 旧 metadata 读 → +1 → 落库（这里给 nil 占位）。
            lastAccessedAt: nil,
            generationCount: nil
        )

        let output = try await writer.write(
            xml: buildResult.xml,
            metadata: metadata,
            outputBaseDir: input.outputBaseDir,
            owner: input.owner,
            repo: input.repo
        )
        AppLog.ai.debug(
            """
            [Packer] \(scope, privacy: .public) Pass 4 write done \
            xml=\(output.contextURL.path, privacy: .public) \
            metadata=\(output.metadataURL.path, privacy: .public) \
            xmlBytes=\(output.stats.contextXmlBytes, privacy: .public)
            """
        )

        return output
    }

    // MARK: - 工具

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
