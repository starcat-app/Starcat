// MARK: - DefaultXmlOutputBuilder
//
// Pass 3：并发读 Tier 0/1 文件内容（TaskGroup cap=8）→ 真 token 估算 → 拼装 XML。
//
// 决议来源：
//   - §22.5 Q4：Pass 3 用 `withThrowingTaskGroup` 并发读 cap=8，按 originalIndex 排序保顺序
//   - §22.7 Q6：读取前 NUL 字节探测，binary 跳过
//   - §22.8 Q7：用真 char count × 0.27 校准；超 budget × 1.2 写 warning
//   - §22.9 Q8：Tier 1 调 `TierTruncation.tier1Head(_:)`；Tier 0 已经在 TierClassifier 100KB 限过
//   - §22.10 Q9：String 拼接 + CDATA 拆段转义 + UTF-8 无 BOM + 2 空格缩进 + 5 段保留
//
// XML 模板（实施权威版，与 §22.10 严格对齐）：
//   ```xml
//   <?xml version="1.0" encoding="UTF-8"?>
//   <repository
//     schemaVersion="1"
//     tierRulesVersion="1.0"
//     tokenEstimatorVersion="char-x-0.27"
//     owner="..." repo="..." ref="..." commitSha="..."
//     generatedAt="2026-06-13T16:23:00Z"
//     tokenBudget="8000">
//     <directoryStructure><![CDATA[...]]></directoryStructure>
//     <keyFiles>
//       <file path="..." tier="0" tokens="..."><![CDATA[...]]></file>
//     </keyFiles>
//     <entryPoints>
//       <file path="..." tier="1" tokens="..." totalLines="..." truncated="true"><![CDATA[...]]></file>
//     </entryPoints>
//     <fileList>
//       <file path="..." tier="2"/>
//     </fileList>
//     <stats totalFiles="..." tier0Count="..." ... />
//   </repository>
//   ```

import Foundation

public struct DefaultXmlOutputBuilder: XmlOutputBuilding {

    public init() {}

    public func build(
        plan: AllocatedPlan,
        directoryTree: String,
        metadata: XmlMetadata
    ) async throws -> XmlBuildResult {
        try Task.checkCancellation()

        // ===== Step 1：并发读所有 Tier 0 / Tier 1 文件内容（cap=8）=====
        let contentItems = plan.items.enumerated().filter { _, item in
            item.strategy == .fullContent || item.strategy == .headTruncated
        }
        let contents = try await Self.readContentsConcurrently(
            indexedItems: contentItems,
            concurrencyCap: TierRules.contentReadConcurrencyCap
        )

        try Task.checkCancellation()

        // ===== Step 2：拼装 XML =====
        var xml = ""
        var actualTokens = 0
        var skipped: [SkippedFile] = []

        // 2.1 XML 声明 + 根元素开标签
        xml += xmlDeclaration()
        xml += rootOpenTag(metadata: metadata)

        // 2.2 directoryStructure
        xml += "  <directoryStructure><![CDATA[\n"
        xml += XMLEscape.escapeCDATA(directoryTree)
        xml += "\n  ]]></directoryStructure>\n\n"

        // 2.3 keyFiles（Tier 0）
        xml += "  <keyFiles>\n"
        for (idx, item) in plan.items.enumerated() where item.strategy == .fullContent {
            guard let contentResult = contents[idx] else { continue }
            switch contentResult {
            case .success(let text):
                let truncatedText = text  // Tier 0 不做截断（100KB 上限已在 classifier 处理）
                let tokens = TokenEstimator.estimate(text: truncatedText)
                actualTokens += tokens
                xml += renderKeyFileElement(
                    path: item.tieredFile.file.relativePath,
                    content: truncatedText,
                    tokens: tokens
                )
            case .skip(let reason):
                skipped.append(SkippedFile(
                    path: item.tieredFile.file.relativePath,
                    reason: reason,
                    tier: 0
                ))
            }
        }
        xml += "  </keyFiles>\n\n"

        // 2.4 entryPoints（Tier 1）
        xml += "  <entryPoints>\n"
        for (idx, item) in plan.items.enumerated() where item.strategy == .headTruncated {
            guard let contentResult = contents[idx] else { continue }
            switch contentResult {
            case .success(let text):
                let originalLines = countLines(text)
                let truncatedText = TierTruncation.tier1Head(text)
                let wasTruncated = truncatedText.count != text.count ||
                    truncatedText != text
                let tokens = TokenEstimator.estimate(text: truncatedText)
                actualTokens += tokens
                xml += renderEntryPointElement(
                    path: item.tieredFile.file.relativePath,
                    content: truncatedText,
                    tokens: tokens,
                    totalLines: originalLines,
                    truncated: wasTruncated
                )
            case .skip(let reason):
                skipped.append(SkippedFile(
                    path: item.tieredFile.file.relativePath,
                    reason: reason,
                    tier: 1
                ))
            }
        }
        xml += "  </entryPoints>\n\n"

        // 2.5 fileList（Tier 2 / 含被 Tier 1 降级的）
        xml += "  <fileList>\n"
        for item in plan.items where item.strategy == .pathOnly {
            let path = XMLEscape.escapeAttribute(item.tieredFile.file.relativePath)
            xml += "    <file path=\"\(path)\" tier=\"\(item.tieredFile.tier.rawValue)\"/>\n"
        }
        xml += "  </fileList>\n\n"

        // 2.6 stats
        let tier0Count = plan.items.filter { $0.tieredFile.tier == .zero }.count
        let tier1Count = plan.items.filter { $0.tieredFile.tier == .one }.count
        let tier2Count = plan.items.filter { $0.tieredFile.tier == .two }.count
        xml += renderStatsElement(
            totalFiles: plan.items.count,
            tier0Count: tier0Count,
            tier1Count: tier1Count,
            tier2Count: tier2Count,
            estimatedTokens: plan.totalEstimatedTokens,
            actualTokens: actualTokens
        )

        // 2.7 根元素闭标签
        xml += "</repository>\n"

        // ===== Step 3：警告（actualTokens > budget × 1.2）=====
        var warnings: [String] = []
        if actualTokens > Int(Double(metadata.tokenBudget) * 1.2) {
            warnings.append("actualTokensExceededBudget")
        }

        return XmlBuildResult(
            xml: xml,
            actualTokens: actualTokens,
            skippedFiles: skipped,
            warnings: warnings
        )
    }

    // MARK: - 并发读取

    /// 读取单个文件的内容结果（success 或 skip）。
    private enum ContentResult: Sendable {
        case success(String)
        case skip(reason: String)
    }

    /// 并发读 Tier 0/1 文件内容，cap = 8，按 originalIndex 排序后返回。
    ///
    /// **算法**：
    ///   1. 启动初始 min(cap, total) 个子任务
    ///   2. 每收到一个 result，立刻 spawn 下一个，维持并发度 = cap
    ///   3. 全部完成后用 dictionary 按 originalIndex 索引，caller 按原序读
    ///
    /// **每个子任务**：BinaryDetection 探测 → 失败记 SkipReason.binaryDetected →
    /// 成功则 String(contentsOf:) 读 → 失败记 SkipReason.fileReadFailed
    private static func readContentsConcurrently(
        indexedItems: [(offset: Int, element: AllocatedFile)],
        concurrencyCap: Int
    ) async throws -> [Int: ContentResult] {
        guard !indexedItems.isEmpty else { return [:] }

        return try await withThrowingTaskGroup(of: (Int, ContentResult).self) { group in
            var results: [Int: ContentResult] = [:]
            var nextIndex = 0
            let total = indexedItems.count

            // 启动初始 cap 个子任务
            for _ in 0..<min(concurrencyCap, total) {
                let idx = nextIndex
                nextIndex += 1
                let item = indexedItems[idx].element
                let originalIndex = indexedItems[idx].offset
                group.addTask {
                    return (originalIndex, await readSingleFile(item))
                }
            }

            // 收一个补一个
            while let (originalIndex, result) = try await group.next() {
                results[originalIndex] = result
                if nextIndex < total {
                    let i = nextIndex
                    nextIndex += 1
                    let item = indexedItems[i].element
                    let oi = indexedItems[i].offset
                    group.addTask {
                        return (oi, await readSingleFile(item))
                    }
                }
            }
            return results
        }
    }

    /// 读取单个文件（BinaryDetection + UTF-8 decode）。
    private static func readSingleFile(_ item: AllocatedFile) async -> ContentResult {
        let url = item.tieredFile.file.absoluteURL

        // NUL 字节探测（§22.7）
        if BinaryDetection.isLikelyBinary(at: url) {
            return .skip(reason: SkipReason.binaryDetected)
        }

        // 尝试 UTF-8 读取
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return .success(text)
        } catch {
            // UTF-8 decode 失败 → 标记编码失败（§22.7 决议 MVP 不做编码探测）
            // 但有些场景是真正的「读不开 / 权限不足」—— 这里两者合并为 encodingDetectionFailed
            // 因为对消费方来说，区分两者意义不大
            return .skip(reason: SkipReason.encodingDetectionFailed)
        }
    }

    // MARK: - XML 段拼装

    private func xmlDeclaration() -> String {
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    }

    private func rootOpenTag(metadata: XmlMetadata) -> String {
        let owner = XMLEscape.escapeAttribute(metadata.owner)
        let repo = XMLEscape.escapeAttribute(metadata.repo)
        let ref = XMLEscape.escapeAttribute(metadata.ref)
        let commitSha = XMLEscape.escapeAttribute(metadata.commitSha)
        let generatedAt = ISO8601DateFormatter.string(date: metadata.generatedAt)

        return """
        <repository
          schemaVersion="1"
          tierRulesVersion="\(TierRules.tierRulesVersion)"
          tokenEstimatorVersion="\(TierRules.tokenEstimatorVersion)"
          owner="\(owner)"
          repo="\(repo)"
          ref="\(ref)"
          commitSha="\(commitSha)"
          generatedAt="\(generatedAt)"
          tokenBudget="\(metadata.tokenBudget)">


        """
    }

    private func renderKeyFileElement(path: String, content: String, tokens: Int) -> String {
        let escapedPath = XMLEscape.escapeAttribute(path)
        let escapedContent = XMLEscape.escapeCDATA(content)
        return """
            <file path="\(escapedPath)" tier="0" tokens="\(tokens)"><![CDATA[
        \(escapedContent)
            ]]></file>

        """
    }

    private func renderEntryPointElement(
        path: String,
        content: String,
        tokens: Int,
        totalLines: Int,
        truncated: Bool
    ) -> String {
        let escapedPath = XMLEscape.escapeAttribute(path)
        let escapedContent = XMLEscape.escapeCDATA(content)
        return """
            <file path="\(escapedPath)" tier="1" tokens="\(tokens)" totalLines="\(totalLines)" truncated="\(truncated)"><![CDATA[
        \(escapedContent)
            ]]></file>

        """
    }

    private func renderStatsElement(
        totalFiles: Int,
        tier0Count: Int,
        tier1Count: Int,
        tier2Count: Int,
        estimatedTokens: Int,
        actualTokens: Int
    ) -> String {
        return """
          <stats
            totalFiles="\(totalFiles)"
            tier0Count="\(tier0Count)"
            tier1Count="\(tier1Count)"
            tier2Count="\(tier2Count)"
            estimatedTokens="\(estimatedTokens)"
            actualTokens="\(actualTokens)"/>

        """
    }

    // MARK: - 行数统计

    /// 与 TierTruncation.tier1Head() 内部 split 行为一致（统一 \r\n / \r → \n + 保留尾随空行）。
    private func countLines(_ text: String) -> Int {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

// MARK: - ISO8601DateFormatter helper

private extension ISO8601DateFormatter {
    /// 格式化 Date 为 `2026-06-13T16:23:00Z` 形式（UTC + Z 后缀）。
    static func string(date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
