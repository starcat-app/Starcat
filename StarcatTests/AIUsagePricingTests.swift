//
//  AIUsagePricingTests.swift
//  StarcatTests
//
//  验证 LiteLLM 模型匹配与 token 费用拆分口径。
//

import Foundation
import Testing
@testable import Starcat

@Suite("AI 用量费用估算")
struct AIUsagePricingTests {
    private let price = LiteLLMModelPrice(
        provider: "test",
        inputCostPerToken: 0.000001,
        outputCostPerToken: 0.000002,
        cacheReadInputTokenCost: 0.0000001,
        cacheCreationInputTokenCost: 0.0000005
    )

    @Test("Chat 按未缓存输入、缓存读写和输出分别计费")
    func chatCostUsesTokenBreakdown() {
        let cost = AIUsageCostCalculator.estimate(
            price: price,
            operation: .chat,
            inputTokens: 1_000,
            outputTokens: 200,
            cachedInputTokens: 300,
            cacheWriteInputTokens: 100
        )

        // 600 * 1e-6 + 300 * 1e-7 + 100 * 5e-7 + 200 * 2e-6
        #expect(cost == Decimal(string: "0.00108"))
    }

    @Test("Embedding 只计算输入且缺失 token 不伪造零费用")
    func embeddingCostRequiresInputUsage() {
        #expect(AIUsageCostCalculator.estimate(
            price: price,
            operation: .embedding,
            inputTokens: 1_000,
            outputTokens: nil,
            cachedInputTokens: nil,
            cacheWriteInputTokens: nil
        ) == Decimal(string: "0.001"))
        #expect(AIUsageCostCalculator.estimate(
            price: price,
            operation: .embedding,
            inputTokens: nil,
            outputTokens: nil,
            cachedInputTokens: nil,
            cacheWriteInputTokens: nil
        ) == nil)
    }

    @Test("Provider 前缀优先且推理强度后缀回落到基础模型")
    func matcherIsProviderAware() {
        let openAI = LiteLLMModelPrice(
            provider: "openai",
            inputCostPerToken: 1,
            outputCostPerToken: 2,
            cacheReadInputTokenCost: nil,
            cacheCreationInputTokenCost: nil
        )
        let gateway = LiteLLMModelPrice(
            provider: "gateway",
            inputCostPerToken: 3,
            outputCostPerToken: 4,
            cacheReadInputTokenCost: nil,
            cacheCreationInputTokenCost: nil
        )
        let entries = ["gpt-test": openAI, "gateway/gpt-test": gateway]

        let match = AIModelPricingCatalog.match(
            model: "GPT-Test-High",
            providerKind: "gateway",
            in: entries
        )

        #expect(match?.key == "gateway/gpt-test")
        #expect(match?.price == gateway)
    }
}
