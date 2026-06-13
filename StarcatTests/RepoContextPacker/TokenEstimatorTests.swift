//
//  TokenEstimatorTests.swift
//  StarcatTests
//
//  验证 TokenEstimator 两阶段估算（§22.8 Q7 决议）：
//    - estimate(byteCount:) Pass 2 用，公式 byte × 0.27
//    - estimate(text:) Pass 3 用，公式 char × 0.27
//    - estimateTier1Head(byteCount:) 取 min(全文估算, 80 行 × 50 字符)
//

import Testing
@testable import Starcat

@Suite("TokenEstimator")
struct TokenEstimatorTests {

    @Test("byteCount 估算公式 = byte × 0.27")
    func byteCountEstimate() {
        // 1000 bytes × 0.27 = 270 tokens
        #expect(TokenEstimator.estimate(byteCount: 1000) == 270)
        // 0 bytes → 0
        #expect(TokenEstimator.estimate(byteCount: 0) == 0)
    }

    @Test("text 估算公式 = char × 0.27")
    func textEstimate() {
        let text = String(repeating: "a", count: 1000)
        // 1000 字符 × 0.27 = 270 tokens
        #expect(TokenEstimator.estimate(text: text) == 270)
        // 空字符串 → 0
        #expect(TokenEstimator.estimate(text: "") == 0)
    }

    @Test("estimateTier1Head 卡顶 80×50 字符上限")
    func tier1HeadCap() {
        // 大文件 30KB → byte 估算 = 8100
        // 80 行 × 50 字符 = 4000 字符 → cap 估算 = 1080
        // 应返回 min(8100, 1080) = 1080
        let estimated = TokenEstimator.estimateTier1Head(byteCount: 30_000)
        #expect(estimated == 1080)
    }

    @Test("estimateTier1Head 小文件按 byte 估算")
    func tier1HeadSmallFile() {
        // 1000 bytes → byte 估算 = 270
        // 80 行 × 50 字符 = 4000 字符 → cap 估算 = 1080
        // min(270, 1080) = 270
        #expect(TokenEstimator.estimateTier1Head(byteCount: 1000) == 270)
    }

    @Test("负数 byteCount 不会产生负 token")
    func negativeNotAllowed() {
        #expect(TokenEstimator.estimate(byteCount: -1000) == 0)
    }
}
