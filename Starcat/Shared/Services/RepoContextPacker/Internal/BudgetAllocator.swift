// MARK: - DefaultBudgetAllocator
//
// Pass 2 第二步：按 Tier 优先级 + Token Budget 贪心分配每个文件的 strategy。
//
// 决议来源：§22.5 Q4（同步纯算法，struct）+ §22.8 Q7（Pass 2 用 size 估算）。
//
// 算法（贪心分配，按优先级）：
//   1. 把 TieredFile 按 (tier, relativePath) 升序排序（path 字典序保证可重现输出）
//   2. **第一轮 Tier 0**：每个 Tier 0 文件给 `.fullContent`，累加 estimateTokens
//   3. **第二轮 Tier 1**：每个 Tier 1 文件给 `.headTruncated`，累加 estimateTier1Head
//      —— 如果第二轮某文件加入会让 totalEstimated > budget，则**降级为 Tier 2**（仅路径）
//   4. **第三轮 Tier 2**：每个 Tier 2 文件给 `.pathOnly`（path 字符串本身估约 5-15 tokens）
//
// **关键不变量**：
//   - 全部文件**都进 plan.items**（不会丢失任何文件，只是 strategy 不同）
//   - plan.items 按 path 字典序排序（XML 输出顺序可重现）
//   - Tier 0 即使 estimateTokens > budget 也会被 include（保证 README / LICENSE 永远全文）
//   - 同一 input 多次调用结果完全一致

import Foundation

public struct DefaultBudgetAllocator: BudgetAllocating {

    public init() {}

    public func allocate(_ tieredFiles: [TieredFile], budget: Int) -> AllocatedPlan {
        // Step 1：按 (tier, path) 排序
        let sorted = tieredFiles.sorted { lhs, rhs in
            if lhs.tier != rhs.tier {
                return lhs.tier < rhs.tier
            }
            return lhs.file.relativePath < rhs.file.relativePath
        }

        var items: [AllocatedFile] = []
        items.reserveCapacity(sorted.count)
        var totalEstimated = 0
        var tier1DowngradedCount = 0

        for tieredFile in sorted {
            switch tieredFile.tier {
            case .zero:
                // Tier 0 全文
                let tokens = TokenEstimator.estimate(byteCount: tieredFile.file.sizeBytes)
                items.append(AllocatedFile(
                    tieredFile: tieredFile,
                    strategy: .fullContent,
                    estimatedTokens: tokens
                ))
                totalEstimated += tokens

            case .one:
                // Tier 1 头 80 行（双约束估算）
                let tokens = TokenEstimator.estimateTier1Head(
                    byteCount: tieredFile.file.sizeBytes
                )
                // 检查 budget：如果加入会超 → 降级为 pathOnly（不丢文件，只是不读内容）
                if totalEstimated + tokens > budget {
                    items.append(AllocatedFile(
                        tieredFile: tieredFile,
                        strategy: .pathOnly,
                        estimatedTokens: Self.estimatePathOnlyTokens(tieredFile.file.relativePath)
                    ))
                    totalEstimated += Self.estimatePathOnlyTokens(tieredFile.file.relativePath)
                    tier1DowngradedCount += 1
                } else {
                    items.append(AllocatedFile(
                        tieredFile: tieredFile,
                        strategy: .headTruncated,
                        estimatedTokens: tokens
                    ))
                    totalEstimated += tokens
                }

            case .two:
                // Tier 2 仅路径
                let tokens = Self.estimatePathOnlyTokens(tieredFile.file.relativePath)
                items.append(AllocatedFile(
                    tieredFile: tieredFile,
                    strategy: .pathOnly,
                    estimatedTokens: tokens
                ))
                totalEstimated += tokens
            }
        }

        return AllocatedPlan(
            items: items,
            tier2TruncatedCount: tier1DowngradedCount,
            totalEstimatedTokens: totalEstimated,
            budget: budget
        )
    }

    // MARK: - estimatePathOnlyTokens

    /// 估算 pathOnly 策略的 token 占用。
    ///
    /// XML 输出形如 `<file path="src/utils/helper.ts" tier="2"/>` —— 约 path.count + 25 chars
    /// （`<file path="" tier="N"/>`），再 × 0.27 系数。
    static func estimatePathOnlyTokens(_ path: String) -> Int {
        TokenEstimator.estimate(byteCount: path.utf8.count + 25)
    }
}
