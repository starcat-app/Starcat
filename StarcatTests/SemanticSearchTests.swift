//
//  SemanticSearchTests.swift
//  StarcatTests
//
//  AI 语义搜索本地逻辑测试。
//
//  覆盖范围：
//  - Float32 embedding 与 SQLite BLOB 之间的无损编解码；
//  - cosine similarity 的排序基础。
//
//  不覆盖真实 AI 网络调用：BYOK provider 会随用户配置变化，单测只验证 Starcat 本地可控逻辑。
//

import Testing
import Foundation
@testable import Starcat

@Suite("Semantic Search")
struct SemanticSearchTests {

    @Test("RepoEmbedding: Float32 BLOB 编解码保持数值")
    func embeddingBlobRoundTrip() {
        let vector: [Float] = [0.1, -0.2, 0.3, 1.0]
        let data = RepoEmbedding.encode(vector)
        #expect(RepoEmbedding.decode(data) == vector)
    }

    @Test("cosine similarity: 同向最高，正交为 0")
    func cosineSimilarity() {
        let same = SemanticSearchService.cosineSimilarity([1, 0, 0], [1, 0, 0])
        let orthogonal = SemanticSearchService.cosineSimilarity([1, 0, 0], [0, 1, 0])
        let opposite = SemanticSearchService.cosineSimilarity([1, 0], [-1, 0])

        #expect(abs(same - 1.0) < 0.0001)
        #expect(abs(orthogonal - 0.0) < 0.0001)
        #expect(abs(opposite + 1.0) < 0.0001)
    }
}

@Suite("Repo AI Insight")
struct RepoAIInsightTests {

    @Test("AI Insight: 可从包裹在 markdown fence 中的 JSON 解码")
    func decodeFencedJSON() throws {
        let raw = """
        ```json
        {
          "oneLiner": "一个 Swift 网络库",
          "summary": "用于测试 JSON 解码。",
          "platforms": ["Swift"],
          "suitableFor": ["macOS App"],
          "strengths": ["轻量"],
          "risks": ["维护状态未知"],
          "minimalExample": null,
          "suggestedTags": [
            {"name": "Swift", "confidence": 0.9, "reason": "主要语言"}
          ],
          "model": "",
          "generatedAt": ""
        }
        ```
        """

        let insight = try RepoAIInsightService.decodeInsight(json: raw)
        #expect(insight.oneLiner == "一个 Swift 网络库")
        #expect(insight.suggestedTags.first?.name == "Swift")
    }
}
