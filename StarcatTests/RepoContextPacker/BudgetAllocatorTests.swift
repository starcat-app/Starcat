//
//  BudgetAllocatorTests.swift
//  StarcatTests
//
//  验证 DefaultBudgetAllocator 的贪心分配 + 降级逻辑（§22.5 Q4 决议）：
//    - 文件按 (tier, path) 排序
//    - Tier 0 一定 fullContent
//    - Tier 1 加入超 budget → 降级 pathOnly
//    - Tier 2 总是 pathOnly
//

import Testing
import Foundation
@testable import Starcat

@Suite("BudgetAllocator")
struct BudgetAllocatorTests {

    private func makeTieredFile(_ path: String, tier: Tier, size: Int) -> TieredFile {
        TieredFile(
            file: FilteredFile(
                relativePath: path,
                absoluteURL: URL(fileURLWithPath: "/tmp/\(path)"),
                sizeBytes: size
            ),
            tier: tier,
            matchReason: "test"
        )
    }

    @Test("Tier 0 一定 fullContent，即使超 budget")
    func tier0AlwaysFullContent() {
        let allocator = DefaultBudgetAllocator()
        let bigReadme = makeTieredFile("README.md", tier: .zero, size: 50_000)
        // budget 只有 100，但 Tier 0 还是 fullContent
        let plan = allocator.allocate([bigReadme], budget: 100)
        #expect(plan.items.count == 1)
        #expect(plan.items[0].strategy == .fullContent)
    }

    @Test("Tier 1 在 budget 内 → headTruncated")
    func tier1WithinBudget() {
        let allocator = DefaultBudgetAllocator()
        let entry = makeTieredFile("src/index.ts", tier: .one, size: 5000)
        let plan = allocator.allocate([entry], budget: 10000)
        #expect(plan.items[0].strategy == .headTruncated)
    }

    @Test("Tier 1 超 budget → 降级 pathOnly")
    func tier1OverBudgetDemoted() {
        let allocator = DefaultBudgetAllocator()
        // 先用一个大 Tier 0 占满 budget
        let bigReadme = makeTieredFile("README.md", tier: .zero, size: 100_000)
        // 8000 budget 大概对应 30000 byte 文本，Tier 0 占 27000 token 已经超
        let entry = makeTieredFile("src/index.ts", tier: .one, size: 5000)
        let plan = allocator.allocate([bigReadme, entry], budget: 8000)

        // Tier 0 还是 fullContent
        let tier0Item = plan.items.first { $0.tieredFile.tier == .zero }!
        #expect(tier0Item.strategy == .fullContent)

        // Tier 1 应该被降级为 pathOnly
        let tier1Item = plan.items.first { $0.tieredFile.tier == .one }!
        #expect(tier1Item.strategy == .pathOnly)
    }

    @Test("Tier 2 永远 pathOnly")
    func tier2AlwaysPathOnly() {
        let allocator = DefaultBudgetAllocator()
        let other = makeTieredFile("src/utils/helper.ts", tier: .two, size: 1000)
        let plan = allocator.allocate([other], budget: 8000)
        #expect(plan.items[0].strategy == .pathOnly)
    }

    @Test("items 按 (tier, path) 排序")
    func sortOrder() {
        let allocator = DefaultBudgetAllocator()
        let files: [TieredFile] = [
            makeTieredFile("src/utils/helper.ts", tier: .two, size: 500),
            makeTieredFile("src/index.ts", tier: .one, size: 1000),
            makeTieredFile("README.md", tier: .zero, size: 1000),
            makeTieredFile("LICENSE", tier: .zero, size: 1000),
        ]
        let plan = allocator.allocate(files, budget: 8000)
        // 排序：tier 0 先（LICENSE, README.md 字典序），然后 tier 1（src/index.ts），最后 tier 2
        #expect(plan.items[0].tieredFile.file.relativePath == "LICENSE")
        #expect(plan.items[1].tieredFile.file.relativePath == "README.md")
        #expect(plan.items[2].tieredFile.file.relativePath == "src/index.ts")
        #expect(plan.items[3].tieredFile.file.relativePath == "src/utils/helper.ts")
    }

    @Test("空输入 → 空 plan")
    func emptyInput() {
        let allocator = DefaultBudgetAllocator()
        let plan = allocator.allocate([], budget: 8000)
        #expect(plan.items.isEmpty)
        #expect(plan.totalEstimatedTokens == 0)
    }

    @Test("totalEstimatedTokens 累加正确")
    func tokenAccumulation() {
        let allocator = DefaultBudgetAllocator()
        let file = makeTieredFile("README.md", tier: .zero, size: 1000)
        let plan = allocator.allocate([file], budget: 8000)
        // 1000 bytes × 0.27 = 270 tokens
        #expect(plan.totalEstimatedTokens == 270)
    }
}
